{-# LANGUAGE OverloadedStrings #-}
import Data.Aeson
import Data.Default
import Data.List (isSuffixOf)
import qualified Data.HashMap.Strict as HM
import Language.Haskell.LSP.Core
import Language.Haskell.LSP.Control
import Language.Haskell.LSP.Messages
import Language.Haskell.LSP.Types
import Control.Concurrent
import Control.Monad
import System.Directory
import System.FilePath

main = do
  lfvar <- newEmptyMVar
  let initCbs = InitializeCallbacks
        { onInitialConfiguration = const $ Right ()
        , onConfigurationChange = const $ Right ()
        , onStartup = \lf -> do
            putMVar lfvar lf

            return Nothing
        }
      options = def
        { executeCommandCommands = Just ["doAnEdit"]
        }
  run initCbs (handlers lfvar) options Nothing

handlers :: MVar (LspFuncs ()) -> Handlers
handlers lfvar = def
  { initializedHandler = pure $ \_ -> send $ NotLogMessage $ fmServerLogMessageNotification MtLog "initialized"
  , hoverHandler = pure $ \req -> send $
      RspHover $ makeResponseMessage req (Just (Hover (HoverContents (MarkupContent MkPlainText "hello")) Nothing))
  , documentSymbolHandler = pure $ \req -> send $
      RspDocumentSymbols $ makeResponseMessage req $ DSDocumentSymbols $
        List [ DocumentSymbol "foo"
                              Nothing
                              SkObject
                              Nothing
                              (mkRange 0 0 3 6)
                              (mkRange 0 0 3 6)
                              Nothing
             ]
  , didOpenTextDocumentNotificationHandler = pure $ \noti -> do
      let NotificationMessage _ _ (DidOpenTextDocumentParams doc) = noti
          TextDocumentItem uri _ _ _ = doc
          Just fp = uriToFilePath uri
          diag = Diagnostic (mkRange 0 0 0 1)
                            (Just DsWarning)
                            (Just (NumberValue 42))
                            (Just "dummy-server")
                            "Here's a warning"
                            Nothing
                            Nothing
      when (".hs" `isSuffixOf` fp) $ void $ forkIO $ do
        threadDelay (2 * 10^6)
        send $ NotPublishDiagnostics $
          fmServerPublishDiagnosticsNotification $ PublishDiagnosticsParams uri $ List [diag]

      -- also act as a registerer for workspace/didChangeWatchedFiles
      when (".register" `isSuffixOf` fp) $ do
        reqId <- readMVar lfvar >>= getNextReqId
        send $ ReqRegisterCapability $ fmServerRegisterCapabilityRequest reqId $
          RegistrationParams $ List $
            [ Registration "0" WorkspaceDidChangeWatchedFiles $ Just $ toJSON $
                DidChangeWatchedFilesRegistrationOptions $ List
                [ FileSystemWatcher "*.watch" (Just (WatchKind True True True)) ]
            ]
      when (".register.abs" `isSuffixOf` fp) $ do
        curDir <- getCurrentDirectory
        reqId <- readMVar lfvar >>= getNextReqId
        send $ ReqRegisterCapability $ fmServerRegisterCapabilityRequest reqId $
          RegistrationParams $ List $
            [ Registration "1" WorkspaceDidChangeWatchedFiles $ Just $ toJSON $
                DidChangeWatchedFilesRegistrationOptions $ List
                [ FileSystemWatcher (curDir </> "*.watch") (Just (WatchKind True True True)) ]
            ]
      when (".register.tmp" `isSuffixOf` fp) $ do
        tmpDir <- getTemporaryDirectory
        reqId <- readMVar lfvar >>= getNextReqId
        send $ ReqRegisterCapability $ fmServerRegisterCapabilityRequest reqId $
          RegistrationParams $ List $
            [ Registration "2" WorkspaceDidChangeWatchedFiles $ Just $ toJSON $
                DidChangeWatchedFilesRegistrationOptions $ List
                [ FileSystemWatcher (tmpDir </> "*.watch") (Just (WatchKind True True True)) ]
            ]

      -- also act as an unregisterer for workspace/didChangeWatchedFiles
      when (".unregister" `isSuffixOf` fp) $ do
        reqId <- readMVar lfvar >>= getNextReqId
        send $ ReqUnregisterCapability $ fmServerUnregisterCapabilityRequest reqId $
          UnregistrationParams $ List [ Unregistration "0" "workspace/didChangeWatchedFiles" ]
      when (".unregister.abs" `isSuffixOf` fp) $ do
        reqId <- readMVar lfvar >>= getNextReqId
        send $ ReqUnregisterCapability $ fmServerUnregisterCapabilityRequest reqId $
          UnregistrationParams $ List [ Unregistration "1" "workspace/didChangeWatchedFiles" ]
      when (".unregister.tmp" `isSuffixOf` fp) $ do
        reqId <- readMVar lfvar >>= getNextReqId
        send $ ReqUnregisterCapability $ fmServerUnregisterCapabilityRequest reqId $
          UnregistrationParams $ List [ Unregistration "2" "workspace/didChangeWatchedFiles" ]
  , executeCommandHandler = pure $ \req -> do
      send $ RspExecuteCommand $ makeResponseMessage req Null
      reqId <- readMVar lfvar >>= getNextReqId
      let RequestMessage _ _ _ (ExecuteCommandParams "doAnEdit" (Just (List [val])) _) = req
          Success docUri = fromJSON val
          edit = List [TextEdit (mkRange 0 0 0 5) "howdy"]
      send $ ReqApplyWorkspaceEdit $ fmServerApplyWorkspaceEditRequest reqId $
        ApplyWorkspaceEditParams $ WorkspaceEdit (Just (HM.singleton docUri edit))
                                                 Nothing
  , codeActionHandler = pure $ \req -> do
      let RequestMessage _ _ _ params = req
          CodeActionParams _ _ cactx _ = params
          CodeActionContext diags _ = cactx
          caresults = fmap diag2caresult diags
          diag2caresult d = CACodeAction $
            CodeAction "Delete this"
                       Nothing
                       (Just (List [d]))
                       Nothing
                      (Just (Command "" "deleteThis" Nothing))
      send $ RspCodeAction $ makeResponseMessage req caresults
  , didChangeWatchedFilesNotificationHandler = pure $ \_ ->
      send $ NotLogMessage $ fmServerLogMessageNotification MtLog "got workspace/didChangeWatchedFiles"
  }
  where send msg = readMVar lfvar >>= \lf -> (sendFunc lf) msg

mkRange sl sc el ec = Range (Position sl sc) (Position el ec)
