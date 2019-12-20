{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE FlexibleContexts #-}
-- | A testing tool for replaying captured client logs back to a server,
-- and validating that the server output matches up with another log.
module Language.Haskell.LSP.Test.Replay
  ( replaySession
  , evalSession
  )
where

import           Prelude hiding (id)
import           Control.Concurrent
import           Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8    as B
import qualified Data.Text                     as T
import           Language.Haskell.LSP.Capture
import           Language.Haskell.LSP.Messages
import           Language.Haskell.LSP.Types
import           Language.Haskell.LSP.Types.Lens as LSP hiding (error)
import           Data.Aeson
import           Data.Default
import           Data.List
import           Data.Maybe
import           Control.Lens hiding (List)
import           Control.Monad
import           System.FilePath
import           System.IO
import           Language.Haskell.LSP.Test
import           Language.Haskell.LSP.Test.Compat
import           Language.Haskell.LSP.Test.Files
import           Language.Haskell.LSP.Test.Decoding
import           Language.Haskell.LSP.Test.Messages
import           Language.Haskell.LSP.Test.Server
import           Language.Haskell.LSP.Test.Session

-- | Send the messages to the server and then wait for it to finish. Like replaySession but the
-- responses are not checked at all to test that the correct answers are sent back. This is useful
-- for stress testing and other debugging.
evalSession :: String -> FilePath -> IO ()
evalSession serverExe sessionDir = do
  let sender = mapM_ (handleClientMessage sendRequestMessage sendMessage sendNot)
      sendNot msg@(NotificationMessage _ Exit _) = sendMessage msg >> liftIO (threadDelay 10_000_000) >> error "done"
      sendNot n = sendMessage n
      listen _ rm h _ =
        forever $ getNextMessage h >>= print . decodeFromServerMsg rm
  replaySessionX listen sender (\_ -> return ()) serverExe sessionDir

type ListenServer = [FromServerMessage] -> RequestMap -> Handle -> SessionContext -> IO ()
type MessageSender = [FromClientMessage] -> Session ()
type Finaliser = ThreadId -> IO ()

-- | Generalised version of runSession which allows the specification of
-- different event sending and recieving behaviour.
replaySessionX :: ListenServer
              -> MessageSender
              -> Finaliser
              -> String -- ^ The command to run the server.
              -> FilePath -- ^ The recorded session directory.
              -> IO ()
replaySessionX listen send final serverExe sessionDir = do

  entries <- B.lines <$> B.readFile (sessionDir </> "session.log")

  -- decode session
  let unswappedEvents = map (fromJust . decode) entries

  withServer serverExe False $ \serverIn serverOut serverProc -> do

    pid <- getProcessID serverProc
    events <- swapCommands pid <$> swapFiles sessionDir unswappedEvents

    let clientEvents = filter isClientMsg events
        serverEvents = filter isServerMsg events
        clientMsgs = map (\(FromClient _ msg) -> msg) clientEvents
        serverMsgs = filter (not . shouldSkip) $ map (\(FromServer _ msg) -> msg) serverEvents
        requestMap = getRequestMap clientMsgs


    sessionThread <- liftIO $ forkIO $
      runSessionWithHandles serverIn serverOut serverProc
                            (listen serverMsgs requestMap)
                            def
                            fullCaps
                            sessionDir
                            (return ()) -- No finalizer cleanup
                            (send clientMsgs)
    final sessionThread


  where
    isClientMsg (FromClient _ _) = True
    isClientMsg _                = False

    isServerMsg (FromServer _ _) = True
    isServerMsg _                = False

-- | Replays a captured client output and
-- makes sure it matches up with an expected response.
-- The session directory should have a captured session file in it
-- named "session.log".
replaySession serverExe dir = do
  reqSema <- newEmptyMVar
  rspSema <- newEmptyMVar
  passSema <- newEmptyMVar
  mainThread <- myThreadId
  replaySessionX (listenServer reqSema rspSema passSema mainThread)
                 (sendMessages reqSema rspSema)
                 (\sessionThread -> takeMVar passSema >> killThread sessionThread)
                 serverExe
                 dir



sendMessages ::  MVar LspId -> MVar LspIdRsp -> [FromClientMessage] -> Session ()
sendMessages _ _ [] = return ()
sendMessages  reqSema rspSema  (nextMsg:remainingMsgs) =
  handleClientMessage request response notification nextMsg
 where
  -- TODO: May need to prevent premature exit notification being sent
  notification msg@(NotificationMessage _ Exit _) = do
    liftIO $ putStrLn "Will send exit notification soon"
    -- 10s delay
    liftIO $ threadDelay 10000000
    sendMessage msg

    liftIO $ error "Done"

  notification msg@(NotificationMessage _ m _) = do
    sendMessage msg

    liftIO $ putStrLn $ "Sent a notification " ++ show m

    sendMessages reqSema rspSema remainingMsgs

  request msg@(RequestMessage _ id m _) = do
    sendRequestMessage msg
    liftIO $ putStrLn $  "Sent a request id " ++ show id ++ ": " ++ show m ++ "\nWaiting for a response"

    rsp <- liftIO $ takeMVar rspSema
    when (responseId id /= rsp) $
      error $ "Expected id " ++ show id ++ ", got " ++ show rsp

    sendMessages reqSema rspSema remainingMsgs

  response msg@(ResponseMessage _ id _ _) = do
    liftIO $ putStrLn $ "Waiting for request id " ++ show id ++ " from the server"
    reqId <- liftIO $ takeMVar reqSema
    if responseId reqId /= id
      then error $ "Expected id " ++ show reqId ++ ", got " ++ show reqId
      else do
        sendResponse msg
        liftIO $ putStrLn $ "Sent response to request id " ++ show id

    sendMessages reqSema rspSema remainingMsgs

sendRequestMessage :: (ToJSON a, ToJSON b) => RequestMessage ClientMethod a b -> Session ()
sendRequestMessage req = do
  -- Update the request map
  reqMap <- requestMap <$> ask
  liftIO $ modifyMVar_ reqMap $
    \r -> return $ updateRequestMap r (req ^. LSP.id) (req ^. method)

  sendMessage req


isNotification :: FromServerMessage -> Bool
isNotification (NotPublishDiagnostics      _) = True
isNotification (NotLogMessage              _) = True
isNotification (NotShowMessage             _) = True
isNotification (NotCancelRequestFromServer _) = True
isNotification _                              = False

listenServer :: MVar LspId
             -> MVar LspIdRsp
             -> MVar ()
             -> ThreadId
             -> [FromServerMessage]
             -> RequestMap
             -> Handle
             -> SessionContext
             -> IO ()
listenServer _ _ passSema _ [] _ _ _  = putMVar passSema ()
listenServer reqSema rspSema passSema mainThreadId  expectedMsgs reqMap serverOut ctx = do

  msgBytes <- getNextMessage serverOut
  let msg = decodeFromServerMsg reqMap msgBytes

  handleServerMessage request response notification msg

  if shouldSkip msg
    then listenServer reqSema rspSema passSema mainThreadId expectedMsgs reqMap serverOut ctx
    else if inRightOrder msg expectedMsgs
      then listenServer reqSema rspSema passSema mainThreadId (delete msg expectedMsgs) reqMap serverOut ctx
      else let remainingMsgs = takeWhile (not . isNotification) expectedMsgs
                ++ [head $ dropWhile isNotification expectedMsgs]
               exc = ReplayOutOfOrder msg remainingMsgs
            in liftIO $ throwTo mainThreadId exc

  where
  response :: ResponseMessage a -> IO ()
  response res = do
    putStrLn $ "Got response for id " ++ show (res ^. id)

    putMVar rspSema (res ^. id) -- unblock the handler waiting to send a request

  request :: RequestMessage ServerMethod a b -> IO ()
  request req = do
    putStrLn
      $  "Got request for id "
      ++ show (req ^. id)
      ++ " "
      ++ show (req ^. method)

    putMVar reqSema (req ^. id) -- unblock the handler waiting for a response

  notification :: NotificationMessage ServerMethod a -> IO ()
  notification n = putStrLn $ "Got notification " ++ show (n ^. method)



-- TODO: QuickCheck tests?
-- | Checks wether or not the message appears in the right order
-- @ N1 N2 N3 REQ1 N4 N5 REQ2 RES1 @
-- given N2, notification order doesn't matter.
-- @ N1 N3 REQ1 N4 N5 REQ2 RES1 @
-- given REQ1
-- @ N1 N3 N4 N5 REQ2 RES1 @
-- given RES1
-- @ N1 N3 N4 N5 XXXX RES1 @ False!
-- Order of requests and responses matter
inRightOrder :: FromServerMessage -> [FromServerMessage] -> Bool

inRightOrder _ [] = error "Why is this empty"

inRightOrder received (expected : msgs)
  | received == expected               = True
  | isNotification expected            = inRightOrder received msgs
  | otherwise                          = False

-- | Ignore logging notifications since they vary from session to session
shouldSkip :: FromServerMessage -> Bool
shouldSkip (NotLogMessage  _) = True
shouldSkip (NotShowMessage _) = True
shouldSkip (ReqShowMessage _) = True
shouldSkip _                  = False

-- | Swaps out any commands uniqued with process IDs to match the specified process ID
swapCommands :: Int -> [Event] -> [Event]
swapCommands _ [] = []

swapCommands pid (FromClient t (ReqExecuteCommand req):xs) =  FromClient t (ReqExecuteCommand swapped):swapCommands pid xs
  where swapped = params . command .~ newCmd $ req
        newCmd = swapPid pid (req ^. params . command)

swapCommands pid (FromServer t (RspInitialize rsp):xs) = FromServer t (RspInitialize swapped):swapCommands pid xs
  where swapped = case newCommands of
          Just cmds -> result . _Just . LSP.capabilities . executeCommandProvider . _Just . commands .~ cmds $ rsp
          Nothing -> rsp
        oldCommands = rsp ^? result . _Just . LSP.capabilities . executeCommandProvider . _Just . commands
        newCommands = fmap (fmap (swapPid pid)) oldCommands

swapCommands pid (x:xs) = x:swapCommands pid xs

hasPid :: T.Text -> Bool
hasPid = (>= 2) . T.length . T.filter (':' ==)
swapPid :: Int -> T.Text -> T.Text
swapPid pid t
  | hasPid t = T.append (T.pack $ show pid) $ T.dropWhile (/= ':') t
  | otherwise = t
