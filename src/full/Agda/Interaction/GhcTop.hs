{-# LANGUAGE CPP, ScopedTypeVariables, FlexibleInstances #-}
module Agda.Interaction.GhcTop
    ( mimicGHCi
    , lispifyResponse
    ) where

import Data.Int
import Data.List
import Data.List as List
import Data.Maybe
import Control.Monad.Identity
import Control.Monad.Error
import Control.Monad.State

import System.Directory
import System.Environment
import qualified System.IO as IO
import qualified Control.Exception as E

import Agda.Utils.Pretty
import Agda.Utils.String
import Agda.Utils.FileName
import qualified Agda.Utils.IO.UTF8 as UTF8

import Agda.Syntax.Position
import Agda.Syntax.Concrete.Pretty ()

import Agda.TypeChecking.Monad as TM hiding (initState, setCommandLineOptions)

import Agda.Interaction.BasicOps
import Agda.Interaction.Response
import Agda.Interaction.InteractionTop
import Agda.Interaction.EmacsCommand hiding (putResponse)
import Agda.Interaction.Highlighting.Emacs

----------------------------------

-- | 'mimicGHCi' is a fake ghci interpreter for the Emacs frontend
--   and for interaction tests.
--
--   'mimicGHCi' reads the Emacs frontend commands from stdin,
--   interprets them and print the result into stdout.
--
--   If the first argument is 'Just f' then 'mimicGhci'
--   use 'f' as the current file, doesn't print the prompt
--   and interprets more expressions (useful in interaction tests).

mimicGHCi :: Maybe String -> IO ()
mimicGHCi maybeCurrentfile = do

    IO.hSetBuffering IO.stdout IO.NoBuffering

    putPrompt "Prelude> "
    _ <- getLine            -- ignore the ":mod +Prelude Agda.Interaction.GhciTop" command
    interact' initState
  where

    putPrompt s = case maybeCurrentfile of
        Nothing -> putStr s
        -- in interactions tests we do not print the prompt
        _   -> return ()

    interact' st = do
        putPrompt "Prelude Agda.Interaction.GhciTop> "
        b <- IO.isEOF
        if b then return () else do
            r <- getLine
            _ <- return $! length r     -- force to read the full input line
            interact' =<< case dropWhile (==' ') r of
                ""  -> return st
                ('-':'-':_) -> return st
                _ -> case runIdentity . flip runStateT r . runErrorT $ parseIO maybeCurrentfile of
                    (Right (current, highlighting, cmd), "") -> do
                        tcmAction st current highlighting cmd
                    (Left err, rem) -> do
                        error $ "error: " ++ err ++ " expected before " ++ rem
                        return st
                    (_, rem) -> do
                        error $ "not consumed: " ++ rem
                        return st

    parseIO Nothing        = parseIOTCM
    parseIO (Just current) = parseIOTCM `mplus` parseTopCommand current

    parseIOTCM = do
        exact "ioTCM "
        current <- parse
        highlighting <- parse
        cmd <- parseInteraction
        return (current, highlighting, cmd)

    parseTopCommand current = do
        exact "top_command "
        cmd <- parseInteraction
        return (current, False, cmd)
      `mplus` do
        exact "goal_command "
        i <- parse
        cmd <- parens' $ do
            t <- token
            parseGoalCommand t
        s <- parse
        return (current, False, cmd i noRange s)

    parseInteraction = parens' $ do
        t <- token
        case t of
            "toggleImplicitArgs" -> return toggleImplicitArgs
            "showImplicitArgs" -> liftM showImplicitArgs parse
            "cmd_load" -> liftM2 cmd_load (parseString maybeCurrentfile) parse
            "cmd_compile" -> liftM3 cmd_compile parse (parseString maybeCurrentfile) parse
            "cmd_metas" -> return cmd_metas
            "cmd_constraints" -> return cmd_constraints
            "cmd_show_module_contents_toplevel" -> liftM cmd_show_module_contents_toplevel parse
            "cmd_solveAll" -> return cmd_solveAll
            "cmd_write_highlighting_info" -> liftM cmd_write_highlighting_info (parseString maybeCurrentfile)
            "cmd_compute_toplevel" -> liftM2 cmd_compute_toplevel parse parse
            "cmd_infer_toplevel" -> liftM2 cmd_infer_toplevel parse parse
            "Agda.Interaction.BasicOps.cmd_infer_toplevel" -> liftM2 cmd_infer_toplevel parse parse
            _ -> do
                f <- parseGoalCommand t
                liftM3 f parse parse parse

    parseGoalCommand t = case t of
            "cmd_give" -> return cmd_give
            "cmd_refine" -> return cmd_refine
            "cmd_intro" -> liftM cmd_intro parse
            "cmd_refine_or_intro" -> liftM cmd_refine_or_intro parse
            "cmd_auto" -> return cmd_auto
            "cmd_make_case" -> return cmd_make_case
            "cmd_show_module_contents" -> return cmd_show_module_contents
            "cmd_compute" -> liftM cmd_compute parse
            "cmd_goal_type" -> liftM cmd_goal_type parse
            "Agda.Interaction.BasicOps.cmd_goal_type" -> liftM cmd_goal_type parse
            "cmd_infer" -> liftM cmd_infer parse
            "Agda.Interaction.BasicOps.cmd_infer" -> liftM cmd_infer parse
            "cmd_goal_type_context" -> liftM cmd_goal_type_context parse
            "Agda.Interaction.BasicOps.cmd_goal_type_context" -> liftM cmd_goal_type_context parse
            "cmd_goal_type_context_infer" -> liftM cmd_goal_type_context_infer parse
            "Agda.Interaction.BasicOps.cmd_goal_type_context_infer" -> liftM cmd_goal_type_context_infer parse
            "cmd_context" -> liftM cmd_context parse
            "Agda.Interaction.BasicOps.cmd_context" -> liftM cmd_context parse
            _ -> throwError "interaction command"


-- | The 'Parse' monad.
--   'StateT' state holds the remaining input.

type Parse a = ErrorT String (StateT String Identity) a

-- | Converter from the type of 'reads' to 'Parse'
--   The first paramter is part of the error message
--   in case the parse fails.

readsToParse :: String -> (String -> Maybe (a, String)) -> Parse a
readsToParse s f = do
    st <- lift get
    case f st of
        Nothing -> throwError s
        Just (a, st) -> do
            lift $ put st
            return a

-- | Read everything until a space or the end.

token :: Parse String
token = readsToParse "Token" $ Just . span (/=' ') . dropWhile (==' ')

-- | Read a non-space char

char' :: Parse Char
char' = readsToParse "Char" $ f . dropWhile (==' ')
  where
    f (c:cs) = Just (c, cs)
    f _ = Nothing

-- | Demand an exact string.

exact :: String -> Parse ()
exact s = readsToParse (show s) $ fmap (\x -> ((),x)) . stripPrefix s . dropWhile (==' ')

reads' :: Read a => String -> Parse a
reads' err = readsToParse err $ listToMaybe . reads

parens' :: Parse a -> Parse a
parens' p = do
    exact "("
    x <- p
    exact ")"
    return x
  `mplus`
    p

-- | Parse a String which may be the currentFile constant.

parseString :: Maybe String -> Parse String
parseString Nothing = parse
parseString (Just current) = parse `mplus` do
    exact "currentFile"
    return current

-- | Parse anything.

class ParseC a where
    parse :: Parse a

instance ParseC [Char] where
    parse = reads' "String"

instance ParseC Bool where
    parse = reads' "Bool"

instance ParseC Int32 where
    parse = reads' "Int32"

instance ParseC [[Char]] where
    parse = reads' "[String]"

instance ParseC InteractionId where
    parse = do
--        exact "InteractionId"
        fmap InteractionId $ reads' "Integer"

instance ParseC Backend where
    parse = do
        t <- token
        case t of
            "MAlonzo" -> return MAlonzo
            "Epic"  -> return Epic
            "JS"    -> return JS
            s   -> throwError $ "instead of " ++ s ++ ", Backend"

instance ParseC Range where
    parse = parens' (do
                exact "Range"
                fmap Range parse)
          `mplus`
            (exact "noRange" >> return noRange)

instance ParseC Interval where
    parse = parens' $ do
        exact "Interval"
        liftM2 Interval parse parse

instance ParseC a => ParseC (Maybe a) where
    parse = parens' $ do
        t <- token
        case t of
            "Just" -> fmap Just parse
            "Nothing" -> return Nothing
            _   -> throwError "Just or Nothing"

instance ParseC AbsolutePath where
    parse = parens' $ do
        exact "mkAbsolute"
        fmap mkAbsolute parse

instance ParseC Position where
    parse = parens' $ do
        exact "Pn"
        liftM4 Pn parse parse parse parse

instance ParseC [Interval] where
    parse = parseList parse

parseList :: Parse a -> Parse [a]
parseList p = do
    exact "["
    x <- p
    fmap (x:) end
  where
    end = do
        c <- char'
        case c of
            ',' -> do
                x <- p
                fmap (x:) end
            ']' -> return []
            _   -> throwError "end of list"

instance ParseC Rewrite where
    parse = reads' "Rewrite"


-- | 'tcmAction' is wrap around 'ioTCMState'
--   which redirects the responses to stdout

tcmAction
    :: InteractionState
    -> FilePath
    -> Bool
    -> Interaction
    -> IO InteractionState
tcmAction state filepath highlighting action =
    ioTCMState filepath highlighting action (setCallback state)
  where
    setCallback = modTCState $
        \st -> st { stInteractionOutputCallback = putStrLn . show <=< lispifyResponse }
    modTCState f st = st { theTCState = f $ theTCState st }


-- | Convert Response to an elisp value for the interactive emacs frontend.

lispifyResponse :: Response -> IO (Lisp String)
lispifyResponse (Resp_HighlightingInfo info) = return $ lispifyHighlightingInfo info
lispifyResponse (Resp_DisplayInfo info) = return $ case info of
    Info_CompilationOk -> f "The module was successfully compiled." "*Compilation result*"
    Info_Constraints s -> f s "*Constraints*"
    Info_AllGoals s -> f s "*All Goals*"
    Info_Auto s -> f s "*Auto*"
    Info_Error s -> f s "*Error*"

    Info_NormalForm s -> f (render s) "*Normal Form*"   -- show?
    Info_InferredType s -> f (render s) "*Inferred Type*"
    Info_CurrentGoal s -> f (render s) "*Current Goal*"
    Info_GoalType s -> f (render s) "*Goal type etc.*"
    Info_ModuleContents s -> f (render s) "*Module contents*"
    Info_Context s -> f (render s) "*Context*"
    Info_Intro s -> f (render s) "*Intro*"
  where f content bufname = display_info' False bufname content
lispifyResponse Resp_ClearRunningInfo = return $ clearRunningInfo
lispifyResponse (Resp_RunningInfo s) = return $ displayRunningInfo $ s ++ "\n"
lispifyResponse (Resp_Status s)
    = return $ L [ A "agda2-status-action"
                 , A (quote $ List.intercalate "," $ catMaybes [checked, showImpl])
                 ]
  where
    boolToMaybe b x = if b then Just x else Nothing

    checked  = boolToMaybe (sChecked               s) "Checked"
    showImpl = boolToMaybe (sShowImplicitArguments s) "ShowImplicit"

lispifyResponse (Resp_UpdateHighlighting info) = do
    dir <- getTemporaryDirectory
    f   <- E.bracket (IO.openTempFile dir "agda2-mode")
                   (IO.hClose . snd) $ \ (f, h) -> do
           UTF8.hPutStr h $ showHighlightingInfo info
           return f
    return $ L [ A "agda2-highlight-load-and-delete-action", A (quote f) ]
lispifyResponse (Resp_JumpToError f p)
    = return $ L [ A "agda2-goto", Q $ L [A (quote f), A ".", A (show p)] ]
lispifyResponse (Resp_InteractionPoints is) = return $
            Cons (Cons (A "last") (A "1"))
                 (L [ A "agda2-goals-action"
                    , Q $ L $ List.map showNumIId is
                    ])
lispifyResponse (Resp_GiveAction ii s)
    = return $ L [A "agda2-give-action", showNumIId ii, A s']
  where
    s' = case s of
        Give_String str -> quote str
        Give_Paren      -> "'paren"
        Give_NoParen    -> "'no-paren"
lispifyResponse (Resp_MakeCaseAction cs) = return $
     Cons (Cons (A "last") (A "2"))
          (L [ A "agda2-make-case-action",
               Q $ L $ List.map (A . quote) cs
             ])
lispifyResponse (Resp_MakeCase cmd pcs) = return $
      Cons (Cons (A "last") (A "2"))
           (L [ A cmd
              , Q $ L $ List.map (A . quote) pcs
              ])
lispifyResponse (Resp_SolveAll ps) = return $
    Cons (Cons (A "last") (A "2"))
         (L [ A "agda2-solveAll-action"
            , Q . L $ concatMap prn ps
            ])
  where
    prn (ii,e)= [showNumIId ii, A $ quote $ show e]

-- | Show an iteraction point identifier as an elisp expression.

showNumIId :: InteractionId -> Lisp String
showNumIId = A . tail . show
