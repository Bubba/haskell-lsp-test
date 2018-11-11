{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

import           Test.Hspec
import           Data.Aeson
import           Data.Default
import qualified Data.HashMap.Strict as HM
import           Data.Maybe
import qualified Data.Text as T
import           Control.Applicative.Combinators
import           Control.Concurrent
import           Control.Monad.IO.Class
import           Control.Monad
import           Control.Lens hiding (List)
import           GHC.Generics
import           Language.Haskell.LSP.Messages
import           Language.Haskell.LSP.Test
import           Language.Haskell.LSP.Test.Replay
import           Language.Haskell.LSP.Types
import           Language.Haskell.LSP.Types.Lens as LSP hiding
  (capabilities, message, rename, applyEdit)
import           Language.Haskell.LSP.Types.Capabilities as LSP
import           System.Timeout

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
{-# ANN module ("HLint: ignore Unnecessary hiding" :: String) #-}

main = hspec $ do
  describe "Session" $ do
    it "fails a test" $
      -- TODO: Catch the exception in haskell-lsp-test and provide nicer output
      let session = runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
                      openDoc "Desktop/simple.hs" "haskell"
                      skipMany loggingNotification
                      anyRequest
        in session `shouldThrow` anyException
    it "initializeResponse" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      rsp <- initializeResponse
      liftIO $ rsp ^. result `shouldNotBe` Nothing

    it "runSessionWithConfig" $
      runSession "hie --lsp" didChangeCaps "test/data/renamePass" $ return ()

    describe "withTimeout" $ do
      it "times out" $
        let sesh = runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
                    openDoc "Desktop/simple.hs" "haskell"
                    -- won't receive a request - will timeout
                    -- incoming logging requests shouldn't increase the
                    -- timeout
                    withTimeout 5 $ skipManyTill anyMessage message :: Session ApplyWorkspaceEditRequest
          -- wait just a bit longer than 5 seconds so we have time
          -- to open the document
          in timeout 6000000 sesh `shouldThrow` anySessionException

      it "doesn't time out" $
        let sesh = runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
                    openDoc "Desktop/simple.hs" "haskell"
                    withTimeout 5 $ skipManyTill anyMessage publishDiagnosticsNotification
          in void $ timeout 6000000 sesh

      it "further timeout messages are ignored" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
        doc <- openDoc "Desktop/simple.hs" "haskell"
        withTimeout 3 $ getDocumentSymbols doc
        liftIO $ threadDelay 5000000
        -- shouldn't throw an exception
        getDocumentSymbols doc
        return ()

      it "overrides global message timeout" $
        let sesh =
              runSessionWithConfig (def { messageTimeout = 5 }) "hie --lsp" fullCaps "test/data/renamePass" $ do
                doc <- openDoc "Desktop/simple.hs" "haskell"
                -- shouldn't time out in here since we are overriding it
                withTimeout 10 $ liftIO $ threadDelay 7000000
                getDocumentSymbols doc
                return True
        in sesh `shouldReturn` True

      it "unoverrides global message timeout" $
        let sesh =
              runSessionWithConfig (def { messageTimeout = 5 }) "hie --lsp" fullCaps "test/data/renamePass" $ do
                doc <- openDoc "Desktop/simple.hs" "haskell"
                -- shouldn't time out in here since we are overriding it
                withTimeout 10 $ liftIO $ threadDelay 7000000
                getDocumentSymbols doc
                -- should now timeout
                skipManyTill anyMessage message :: Session ApplyWorkspaceEditRequest
        in sesh `shouldThrow` (== Timeout)


    describe "SessionException" $ do
      it "throw on time out" $
        let sesh = runSessionWithConfig (def {messageTimeout = 10}) "hie --lsp" fullCaps "test/data/renamePass" $ do
                skipMany loggingNotification
                _ <- message :: Session ApplyWorkspaceEditRequest
                return ()
        in sesh `shouldThrow` anySessionException

      it "don't throw when no time out" $ runSessionWithConfig (def {messageTimeout = 5}) "hie --lsp" fullCaps "test/data/renamePass" $ do
        loggingNotification
        liftIO $ threadDelay 10
        _ <- openDoc "Desktop/simple.hs" "haskell"
        return ()

      describe "UnexpectedMessageException" $ do
        it "throws when there's an unexpected message" $
          let selector (UnexpectedMessage "Publish diagnostics notification" (NotLogMessage _)) = True
              selector _ = False
            in runSession "hie --lsp" fullCaps "test/data/renamePass" publishDiagnosticsNotification `shouldThrow` selector
        it "provides the correct types that were expected and received" $
          let selector (UnexpectedMessage "ResponseMessage WorkspaceEdit" (RspDocumentSymbols _)) = True
              selector _ = False
              sesh = do
                doc <- openDoc "Desktop/simple.hs" "haskell"
                sendRequest TextDocumentDocumentSymbol (DocumentSymbolParams doc)
                skipMany anyNotification
                message :: Session RenameResponse -- the wrong type
            in runSession "hie --lsp" fullCaps "test/data/renamePass" sesh
              `shouldThrow` selector

  describe "replaySession" $
    -- This is too fickle at the moment
    -- it "passes a test" $
    --   replaySession "hie --lsp" "test/data/renamePass"
    it "fails a test" $
      let selector (ReplayOutOfOrder _ _) = True
          selector _ = False
        in replaySession "hie --lsp" "test/data/renameFail" `shouldThrow` selector

  describe "manual javascript session" $
    it "passes a test" $
      runSession "javascript-typescript-stdio" fullCaps "test/data/javascriptPass" $ do
        doc <- openDoc "test.js" "javascript"

        noDiagnostics

        mfoosymbol <- getDocumentSymbols doc
        fooSymbol <- case mfoosymbol of
          Right (fooSymbol:_) -> return fooSymbol
          _ -> fail "mfoosymbol `shouldBe` Right _"

        liftIO $ do
          fooSymbol ^. name `shouldBe` "foo"
          fooSymbol ^. kind `shouldBe` SkFunction

  describe "text document VFS" $
    it "sends back didChange notifications" $
      runSession "hie --lsp" def "test/data/refactor" $ do
        doc <- openDoc "Main.hs" "haskell"

        let args = toJSON $ AOP (doc ^. uri)
                                (Position 1 14)
                                "Redundant bracket"
            reqParams = ExecuteCommandParams "applyrefact:applyOne" (Just (List [args]))
        request_ WorkspaceExecuteCommand reqParams

        editReq <- message :: Session ApplyWorkspaceEditRequest
        liftIO $ do
          let (Just cs) = editReq ^. params . edit . changes
              [(u, List es)] = HM.toList cs
          u `shouldBe` doc ^. uri
          es `shouldBe` [TextEdit (Range (Position 1 0) (Position 1 18)) "main = return 42"]

        noDiagnostics

        contents <- documentContents doc
        liftIO $ contents `shouldBe` "main :: IO Int\nmain = return 42\n"

  describe "getDocumentEdit" $
    it "automatically consumes applyedit requests" $
      runSession "hie --lsp" fullCaps "test/data/refactor" $ do
        doc <- openDoc "Main.hs" "haskell"

        let args = toJSON $ AOP (doc ^. uri)
                                (Position 1 14)
                                "Redundant bracket"
            reqParams = ExecuteCommandParams "applyrefact:applyOne" (Just (List [args]))
        request_ WorkspaceExecuteCommand reqParams
        contents <- getDocumentEdit doc
        liftIO $ contents `shouldBe` "main :: IO Int\nmain = return 42\n"
        noDiagnostics

  describe "getCodeActions" $
    it "works" $ runSession "hie" fullCaps "test/data/refactor" $ do
      doc <- openDoc "Main.hs" "haskell"
      waitForDiagnostics
      maction <- getCodeActions doc (Range (Position 1 14) (Position 1 18))
      action <- case maction of
        [CACodeAction action] -> return action
        _ -> fail "Expecting [CACodeAction action]"
      liftIO $ action ^. title `shouldBe` "Apply hint:Redundant bracket"

  describe "getAllCodeActions" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data/refactor" $ do
      doc <- openDoc "Main.hs" "haskell"
      _ <- waitForDiagnostics
      actions <- getAllCodeActions doc
      liftIO $ do
        let [CACodeAction action] = actions
        action ^. title `shouldBe` "Apply hint:Redundant bracket"
        action ^. command . _Just . command `shouldSatisfy` T.isSuffixOf ":applyrefact:applyOne"

  describe "getDocumentSymbols" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"

      skipMany loggingNotification

      noDiagnostics

      mmainsymbol <- getDocumentSymbols doc
      mainSymbol <- case mmainsymbol of
        Left (mainSymbol:_) -> return mainSymbol
        _ -> fail "expecting Left (mainSymbol:_)"

      liftIO $ do
        mainSymbol ^. name `shouldBe` "main"
        mainSymbol ^. kind `shouldBe` SkFunction
        mainSymbol ^. range `shouldBe` Range (Position 3 0) (Position 5 30)

  describe "applyEdit" $ do
    it "increments the version" $ runSession "hie --lsp" docChangesCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      moldversion <- getVersionedDoc doc
      oldVersion <- case moldversion of
        VersionedTextDocumentIdentifier _ (Just oldVersion) -> return oldVersion
        _ -> fail "Expected VersionedTextDocumentIdentifier _ (Just oldVersion)"
      let edit = TextEdit (Range (Position 1 1) (Position 1 3)) "foo"
      mnewVersion <- applyEdit doc edit
      newVersion <- case mnewVersion of
        VersionedTextDocumentIdentifier _ (Just newVersion) -> return newVersion
        _ -> fail "Expecting VersionedTextDocumentIdentifier _ (Just newVersion)"
      liftIO $ newVersion `shouldBe` oldVersion + 1
    it "changes the document contents" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      let edit = TextEdit (Range (Position 0 0) (Position 0 2)) "foo"
      applyEdit doc edit
      contents <- documentContents doc
      liftIO $ contents `shouldSatisfy` T.isPrefixOf "foodule"

  describe "getCompletions" $
    it "works" $ runSession "hie --lsp" def "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      mitem <- getCompletions doc (Position 5 5)
      item <- case mitem of
        item:_ -> return item
        _ -> fail "Expecting getCompletions doc (Position 5 5)"
      liftIO $ do
        item ^. label `shouldBe` "interactWithUser"
        item ^. kind `shouldBe` Just CiFunction
        item ^. detail `shouldBe` Just "Items -> IO ()\nMain"

  describe "getReferences" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      let pos = Position 40 3 -- interactWithUser
          uri = doc ^. LSP.uri
      refs <- getReferences doc pos True
      liftIO $ refs `shouldContain` map (Location uri) [
          mkRange 41 0 41 16
        , mkRange 75 6 75 22
        , mkRange 71 6 71 22
        ]

  describe "getDefinitions" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      let pos = Position 49 25 -- addItem
      defs <- getDefinitions doc pos
      liftIO $ defs `shouldBe` [Location (doc ^. uri) (mkRange 28 0 28 7)]

  describe "waitForDiagnosticsSource" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data" $ do
      openDoc "Error.hs" "haskell"
      mdiag <- waitForDiagnosticsSource "ghcmod"
      diag <- case mdiag of
        [diag] -> return diag
        _ -> fail "Expecting waitForDiagnosticsSource \"ghcmod\""
      liftIO $ do
        diag ^. severity `shouldBe` Just DsError
        diag ^. source `shouldBe` Just "ghcmod"

  describe "rename" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data" $ do
      doc <- openDoc "Rename.hs" "haskell"
      rename doc (Position 1 0) "bar"
      documentContents doc >>= liftIO . shouldBe "main = bar\nbar = return 42\n"

  describe "getHover" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      -- hover returns nothing until module is loaded
      skipManyTill loggingNotification $ count 2 noDiagnostics
      hover <- getHover doc (Position 45 9) -- putStrLn
      liftIO $ hover `shouldSatisfy` isJust

  describe "getHighlights" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data/renamePass" $ do
      doc <- openDoc "Desktop/simple.hs" "haskell"
      skipManyTill loggingNotification $ count 2 noDiagnostics
      highlights <- getHighlights doc (Position 27 4) -- addItem
      liftIO $ length highlights `shouldBe` 4

  describe "formatDoc" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data" $ do
      doc <- openDoc "Format.hs" "haskell"
      oldContents <- documentContents doc
      formatDoc doc (FormattingOptions 4 True)
      documentContents doc >>= liftIO . (`shouldNotBe` oldContents)

  describe "formatRange" $
    it "works" $ runSession "hie --lsp" fullCaps "test/data" $ do
      doc <- openDoc "Format.hs" "haskell"
      oldContents <- documentContents doc
      formatRange doc (FormattingOptions 4 True) (Range (Position 1 10) (Position 2 10))
      documentContents doc >>= liftIO . (`shouldNotBe` oldContents)

  describe "closeDoc" $
    it "works" $
      let sesh =
            runSession "hie --lsp" fullCaps "test/data" $ do
              doc <- openDoc "Format.hs" "haskell"
              closeDoc doc
              -- need to evaluate to throw
              documentContents doc >>= liftIO . print
      in sesh `shouldThrow` anyException

mkRange sl sc el ec = Range (Position sl sc) (Position el ec)

didChangeCaps :: ClientCapabilities
didChangeCaps = def { _workspace = Just workspaceCaps }
  where
    workspaceCaps = def { _didChangeConfiguration = Just configCaps }
    configCaps = DidChangeConfigurationClientCapabilities (Just True)

docChangesCaps :: ClientCapabilities
docChangesCaps = def { _workspace = Just workspaceCaps }
  where
    workspaceCaps = def { _workspaceEdit = Just editCaps }
    editCaps = WorkspaceEditClientCapabilities (Just True)

data ApplyOneParams = AOP
  { file      :: Uri
  , start_pos :: Position
  , hintTitle :: String
  } deriving (Generic, ToJSON)
