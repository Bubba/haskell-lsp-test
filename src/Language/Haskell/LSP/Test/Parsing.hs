{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
module Language.Haskell.LSP.Test.Parsing where

import Control.Applicative
import Control.Concurrent
import Control.Lens
import Control.Monad.IO.Class
import Control.Monad
import Data.Aeson
import Data.Aeson.Encode.Pretty
import qualified Data.ByteString.Lazy.Char8 as B
import Data.Conduit.Parser
import Data.Maybe
import qualified Data.Text as T
import Data.Typeable
import Language.Haskell.LSP.Messages
import Language.Haskell.LSP.Types as LSP hiding (error)
import Language.Haskell.LSP.Test.Messages
import Language.Haskell.LSP.Test.Session
import System.Console.ANSI

satisfy :: MonadIO m => (FromServerMessage -> Bool) -> SessionT m FromServerMessage
satisfy pred = do
  
  skipTimeout <- overridingTimeout <$> get
  timeoutId <- curTimeoutId <$> get
  unless skipTimeout $ do
    chan <- asks messageChan
    timeout <- asks (messageTimeout . config)
    void $ liftIO $ forkIO $ do
      threadDelay (timeout * 1000000)
      writeChan chan (TimeoutMessage timeoutId)

  x <- await

  unless skipTimeout $
    modify $ \s -> s { curTimeoutId = timeoutId + 1 }

  modify $ \s -> s { lastReceivedMessage = Just x }

  if pred x
    then do
      shouldLog <- asks $ logMessages . config
      liftIO $ when shouldLog $ do
        setSGR [SetColor Foreground Dull Magenta]
        putStrLn $ "<-- " ++ B.unpack (encodeMsgPretty x)
        setSGR [Reset]
      return x
    else empty

-- | Matches a message of type 'a'.
message :: forall a m. (Typeable a, FromJSON a, MonadIO m) => SessionT m a
message =
  let parser = decode . encodeMsg :: FromServerMessage -> Maybe a
  in named (T.pack $ show $ head $ snd $ splitTyConApp $ last $ typeRepArgs $ typeOf parser) $
    castMsg <$> satisfy (isJust . parser)

-- | Matches if the message is a notification.
anyNotification :: MonadIO m => SessionT m FromServerMessage
anyNotification = named "Any notification" $ satisfy isServerNotification

-- | Matches if the message is a request.
anyRequest :: MonadIO m => SessionT m FromServerMessage
anyRequest = named "Any request" $ satisfy isServerRequest

-- | Matches if the message is a response.
anyResponse :: MonadIO m => SessionT m FromServerMessage
anyResponse = named "Any response" $ satisfy isServerResponse

responseForId :: forall a m. (FromJSON a, MonadIO m) => LspId -> SessionT m (ResponseMessage a)
responseForId lid = named (T.pack $ "Response for id: " ++ show lid) $ do
  let parser = decode . encodeMsg :: FromServerMessage -> Maybe (ResponseMessage a)
  x <- satisfy (maybe False (\z -> z ^. LSP.id == responseId lid) . parser)
  return $ castMsg x

anyMessage :: MonadIO m => SessionT m FromServerMessage
anyMessage = satisfy (const True)

-- | A stupid method for getting out the inner message.
castMsg :: FromJSON a => FromServerMessage -> a
castMsg = fromMaybe (error "Failed casting a message") . decode . encodeMsg

-- | A version of encode that encodes FromServerMessages as if they
-- weren't wrapped.
encodeMsg :: FromServerMessage -> B.ByteString
encodeMsg = encode . genericToJSON (defaultOptions { sumEncoding = UntaggedValue })

encodeMsgPretty :: FromServerMessage -> B.ByteString
encodeMsgPretty = encodePretty . genericToJSON (defaultOptions { sumEncoding = UntaggedValue })

-- | Matches if the message is a log message notification or a show message notification/request.
loggingNotification :: MonadIO m => SessionT m FromServerMessage
loggingNotification = named "Logging notification" $ satisfy shouldSkip
  where
    shouldSkip (NotLogMessage _) = True
    shouldSkip (NotShowMessage _) = True
    shouldSkip (ReqShowMessage _) = True
    shouldSkip _ = False

publishDiagnosticsNotification :: MonadIO m => SessionT m PublishDiagnosticsNotification
publishDiagnosticsNotification = named "Publish diagnostics notification" $ do
  NotPublishDiagnostics diags <- satisfy test
  return diags
  where test (NotPublishDiagnostics _) = True
        test _ = False
