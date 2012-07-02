{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, GADTs, KindSignatures, TypeFamilies, DeriveDataTypeable #-}

module Language.HERMIT.Shell.Command where

import qualified GhcPlugins as GHC

import Control.Applicative
import Control.Arrow hiding (loop)
import Control.Concurrent
import Control.Exception.Base hiding (catch)
import Control.Monad.State
import Control.Monad.Error

import Data.Char
import Data.Monoid
import Data.List (intercalate, isPrefixOf, nub)
import Data.Default (def)
import Data.Dynamic
import qualified Data.Map as M
import Data.Maybe

import Language.HERMIT.Dictionary
import Language.HERMIT.Expr
import Language.HERMIT.External
import Language.HERMIT.Interp
import Language.HERMIT.Kernel.Scoped
import Language.HERMIT.Kure
import Language.HERMIT.PrettyPrinter
import Language.HERMIT.Primitive.Consider
import Language.HERMIT.Primitive.Inline

import Prelude hiding (catch)

import System.Console.ANSI
import System.IO

import qualified Text.PrettyPrint.MarkedHughesPJ as PP

import System.Console.Haskeline hiding (catch)

-- There are 3 types of commands, AST effect-ful, Shell effect-ful, and Queries.

data ShellCommand :: * where
   AstEffect     :: AstEffect                -> ShellCommand
   ShellEffect   :: ShellEffect              -> ShellCommand
   QueryFun      :: QueryFun                 -> ShellCommand
   MetaCommand   :: MetaCommand              -> ShellCommand

data AstEffect
   -- | This applys a rewrite (giving a whole new lower-level AST)
   = Apply      (RewriteH Core)
   -- | This changes the current location using a computed path
   | Pathfinder (TranslateH Core Path)
   -- | This changes the currect location using directions
   | Direction  Direction
   -- | This changes the current location using a give path
   | PushFocus Path

   | BeginScope
   | EndScope
   deriving Typeable

instance Extern AstEffect where
    type Box AstEffect = AstEffect
    box i = i
    unbox i = i

data ShellEffect :: * where
   SessionStateEffect    :: (CommandLineState -> SessionState -> IO SessionState) -> ShellEffect
   deriving Typeable

data QueryFun :: * where
   QueryT         :: TranslateH Core String   -> QueryFun  -- strange stuff

   -- These two be can generalized into
   --  (CommandLineState -> IO String)
   Status        ::                             QueryFun
   Message       :: String                   -> QueryFun
   Inquiry        ::(CommandLineState -> SessionState -> IO String) -> QueryFun
   deriving Typeable

instance Extern QueryFun where
    type Box QueryFun = QueryFun
    box i = i
    unbox i = i

data MetaCommand
   = Resume
   | Abort
   | Dump String String String Int
   | LoadFile String  -- load a file on top of the current node
   deriving Typeable

instance Extern MetaCommand where
    type Box MetaCommand = MetaCommand
    box i = i
    unbox i = i

data Direction = L | R | U | D | T
        deriving Show


-- TODO: Use another word, Navigation is a more general concept
-- Perhaps VersionNavigation
data Navigation = Back                  -- back (up) the derivation tree
                | Step                  -- down one step; assumes only one choice
                | Goto Int              -- goto a specific node, if possible
                | GotoTag String        -- goto a specific named tag
        deriving Show

data ShellCommandBox = ShellCommandBox ShellCommand deriving Typeable

instance Extern ShellEffect where
    type Box ShellEffect = ShellEffect
    box i = i
    unbox i = i

instance Extern ShellCommand where
    type Box ShellCommand = ShellCommandBox
    box i = ShellCommandBox i
    unbox (ShellCommandBox i) = i

interpShellCommand :: [Interp ShellCommand]
interpShellCommand =
                [ Interp $ \ (ShellCommandBox cmd)       -> cmd
                , Interp $ \ (IntBox i)                  -> AstEffect $ PushFocus [i]
                , Interp $ \ (RewriteCoreBox rr)         -> AstEffect $ Apply rr
                , Interp $ \ (TranslateCorePathBox tt)   -> AstEffect $ Pathfinder tt
                , Interp $ \ (StringBox str)             -> QueryFun $ Message str
                , Interp $ \ (TranslateCoreStringBox tt) -> QueryFun $ QueryT tt
                , Interp $ \ (effect :: AstEffect)       -> AstEffect $ effect
                , Interp $ \ (effect :: ShellEffect)     -> ShellEffect $ effect
                , Interp $ \ (query :: QueryFun)        -> QueryFun $ query
                , Interp $ \ (meta :: MetaCommand)     -> MetaCommand $ meta
                ]
-- TODO: move this into the shell, it is completely specific to the way
-- the shell works. What about list, for example?

--interpKernelCommand :: [Interp KernelCommand]
--interpKernelCommand =
--             [ Interp $ \ (KernelCommandBox cmd)      -> cmd
--             ]

shell_externals :: [External]
shell_externals = map (.+ Shell) $
   [
     external "resume"          Resume    -- HERMIT Kernel Exit
       [ "stops HERMIT; resumes compile" ]
   , external "quit"           Abort     -- UNIX Exit
       [ "hard UNIX-style exit; does not return to GHC; does not save" ]
   , external "status"          Status
       [ "redisplays current state" ]
   , external "left"            (Direction L)
       [ "move to the next child"]
   , external "right"           (Direction R)
       [ "move to the previous child"]
   , external "up"              (Direction U)
       [ "move to the parent"]
   , external "down"            (Direction D)
       [ "move to the first child"]
   , external ":navigate"        (SessionStateEffect $ \ _ st -> return $ st { cl_nav = True })
       [ "switch to navigate mode" ]
   , external ":command-line"    (SessionStateEffect $ \ _ st -> return $ st { cl_nav = False })
       [ "switch to command line mode" ]
   , external "top"            (Direction T)
       [ "move to root of tree" ]
   , external ":back"            (SessionStateEffect $ navigation Back)
       [ "go back in the derivation" ]                                          .+ VersionControl
   , external "log"             (Inquiry $ showDerivationTree)
       [ "go back in the derivation" ]                                          .+ VersionControl
   , external ":step"            (SessionStateEffect $ navigation Step)
       [ "step forward in the derivation" ]                                     .+ VersionControl
   , external ":goto"            (SessionStateEffect . navigation . Goto)
       [ "goto a specific step in the derivation" ]                             .+ VersionControl
   , external ":goto"            (SessionStateEffect . navigation . GotoTag)
       [ "goto a named step in the derivation" ]
   , external "setpp"           (\ pp -> SessionStateEffect $ \ _ st -> do
       case M.lookup pp pp_dictionary of
         Nothing -> do
            liftIO $ putStrLn $ "List of Pretty Printers: " ++ intercalate ", " (M.keys pp_dictionary)
            return st
         Just _ -> return $ st { cl_pretty = pp })
       [ "set the pretty printer"
       , "use 'setpp ls' to list available pretty printers" ]
   , external "set-renderer"    changeRenderer
       [ "set the output renderer mode"]
   , external "set-renderer"    showRenderers
       [ "set the output renderer mode"]
   , external "dump"    Dump
       [ "dump <filename> <pretty-printer> <renderer> <width>"]
   , external "set-width"   (\ n -> SessionStateEffect $ \ _ st -> return $ st { cl_width = n })
       ["set the width of the screen"]
   , external "set-pp-expr-type"
                (\ str -> SessionStateEffect $ \ _ st -> case reads str :: [(ShowOption,String)] of
                                                 [(opt,"")] -> return $ st { cl_pretty_opts =
                                                                                 (cl_pretty_opts st) { po_exprTypes = opt }
                                                                           }
                                                 _ -> return $ st)
       ["set how to show expression-level types (Show|Abstact|Omit)"]
   , external "{"   BeginScope
       ["push current lens onto a stack"]       -- tag as internal
   , external "}"   EndScope
       ["pop a lens off a stack"]               -- tag as internal
   , external "load"  LoadFile
       ["load <filename> : load a file of commands into the current derivation"]
   ]

showRenderers :: QueryFun
showRenderers = Message $ "set-renderer " ++ show (map fst finalRenders)

changeRenderer :: String -> ShellEffect
changeRenderer renderer = SessionStateEffect $ \ _ st ->
        case lookup renderer finalRenders of
          Nothing -> return st          -- should fail with message
          Just r  -> return $ st { cl_render = r }

----------------------------------------------------------------------------------

catch :: IO a -> (String -> IO a) -> IO a
catch = catchJust (\ (err :: IOException) -> return (show err))

pretty :: CommandLineState -> PrettyH Core
pretty st = case M.lookup (cl_pretty (cl_session st)) pp_dictionary of
                Just pp -> pp (cl_pretty_opts (cl_session st))
                Nothing -> pure (PP.text $ "<<no pretty printer for " ++ cl_pretty (cl_session st) ++ ">>")

showFocus :: (MonadIO m) => CLM m ()
showFocus = do
    st <- get
    liftIO ((do
        doc <- queryS (cl_kernel st) (cl_cursor (cl_session st)) (pretty st)
        cl_render (cl_session st) stdout (cl_pretty_opts (cl_session st)) doc)
          `catch` \ msg -> putStrLn $ "Error thrown: " ++ msg)

-------------------------------------------------------------------------------

-- TODO: change ScopedKernel to use this interface instead of Path?
newtype ScopePath = ScopePath [Int]

emptyScopePath :: ScopePath
emptyScopePath = ScopePath []

concatScopePaths :: [ScopePath] -> ScopePath
concatScopePaths = ScopePath . foldr (\ (ScopePath ns) ms -> ns ++ ms) []

scopePath2Path :: ScopePath -> Path
scopePath2Path (ScopePath p) = reverse p

path2ScopePath :: Path -> ScopePath
path2ScopePath p = ScopePath (reverse p)

moveLocally :: Direction -> ScopePath -> ScopePath
moveLocally D (ScopePath ns)             = ScopePath (0:ns)
moveLocally U (ScopePath (_:ns))         = ScopePath ns
moveLocally L (ScopePath (n:ns)) | n > 0 = ScopePath ((n-1):ns)
moveLocally R (ScopePath (n:ns))         = ScopePath ((n+1):ns)
moveLocally T _                          = ScopePath []
moveLocally _ p                          = p

-------------------------------------------------------------------------------

type CLM m a = ErrorT String (StateT CommandLineState m) a

data CommandLineState = CommandLineState
        { cl_graph       :: [(SAST,ExprH,SAST)]
        , cl_tags        :: [(String,SAST)]
        -- these two should be in a reader
        , cl_dict        :: M.Map String [Dynamic]
        , cl_kernel       :: ScopedKernel
        -- and the session state (perhaps in a seperate state?)
        , cl_session      :: SessionState
        }

newSAST :: ExprH -> SAST -> CommandLineState -> CommandLineState
newSAST expr sast st = st { cl_session = (cl_session st) { cl_cursor = sast }
                          , cl_graph = (cl_cursor (cl_session st), expr, sast) : cl_graph st
                          }

-- Session-local issues; things that are never saved.
data SessionState = SessionState
        { cl_cursor      :: SAST              -- ^ the current AST
        , cl_pretty      :: String           -- ^ which pretty printer to use
        , cl_pretty_opts :: PrettyOptions -- ^ The options for the pretty printer
        , cl_render      :: Handle -> PrettyOptions -> DocH -> IO ()   -- ^ the way of outputing to the screen
        , cl_width       :: Int                 -- ^ how wide is the screen?
        , cl_nav         :: Bool        -- ^ keyboard input the the nav panel
        , cl_loading     :: Bool        -- ^ if loading a file, show commands as they run. TODO: generalize
        }


-------------------------------------------------------------------------------

data CompletionType = ConsiderC -- complete with possible arguments to consider
                    | InlineC   -- complete with names that can be inlined
                    | CommandC  -- complete using dictionary commands (default)
                    | AmbiguousC [CompletionType]  -- completionType function needs to be more specific
    deriving (Show)

-- todo: reverse rPrev and parse it, to better figure out what possiblities are in context?
--       for instance, completing "any-bu (inline " should be different than completing just "inline "
--       this would also allow typed completion?
completionType :: String -> CompletionType
completionType = go . dropWhile isSpace
    where go rPrev = case [ ty | (nm, ty) <- opts, reverse nm `isPrefixOf` rPrev ] of
                        []  -> CommandC
                        [t] -> t
                        ts  -> AmbiguousC ts
          opts = [ ("inline"  , InlineC  )
                 , ("consider", ConsiderC)
                 , ("rhs-of"  , ConsiderC)
                 ]

completionQuery :: CommandLineState -> CompletionType -> IO (TranslateH Core [String])
completionQuery _ ConsiderC = return $ considerTargets >>> arr ((++ (map fst considerables)) . map ('\'':))
completionQuery _ InlineC   = return $ inlineTargets   >>> arr (map ('\'':))
completionQuery s CommandC  = return $ pure (M.keys (cl_dict s))
-- Need to modify opts in completionType function. No key can be a suffix of another key.
completionQuery _ (AmbiguousC ts) = do
    putStrLn "\nCannot tab complete: ambiguous completion type."
    putStrLn $ "Possibilities: " ++ (intercalate ", " $ map show ts)
    return (pure [])

shellComplete :: MVar CommandLineState -> String -> String -> IO [Completion]
shellComplete mvar rPrev so_far = do
    st <- readMVar mvar
    targetQuery <- completionQuery st (completionType rPrev)
    liftM (map simpleCompletion . nub . filter (so_far `isPrefixOf`))
        $ queryS (cl_kernel st) (cl_cursor (cl_session st)) targetQuery

commandLine :: [String] -> Behavior -> GHC.ModGuts -> GHC.CoreM GHC.ModGuts
commandLine filesToLoad behavior modGuts = do
    GHC.liftIO $ print ("files",filesToLoad)

    GHC.liftIO $ print (length (GHC.mg_rules modGuts))
    let dict = dictionary $ all_externals shell_externals modGuts
    let ws_complete = " ()"

    let startup =
            sequence_ [ performMetaCommand $ case fileName of
                         "abort"  -> Abort
                         "resume" -> Resume
                         _        -> LoadFile fileName
                      | fileName <- reverse filesToLoad
                      , not (null fileName)
                      ] `ourCatch` \ msg -> do putStrLn $ "Booting Failure: " ++ msg

    flip scopedKernel modGuts $ \ skernel sast -> do

        let sessionState = SessionState sast "clean" def unicodeConsole 80 False False
            shellState = CommandLineState [] [] dict skernel sessionState

        completionMVar <- newMVar shellState

        _ <- runInputTBehavior behavior
                (setComplete (completeWordWithPrev Nothing ws_complete (shellComplete completionMVar)) defaultSettings)
                (evalStateT (runErrorT (startup >> showFocus >> loop completionMVar)) shellState)

        return ()

loop :: (MonadIO m, m ~ InputT IO) => MVar CommandLineState -> CLM m ()
loop completionMVar = loop'
  where loop' = do
            st <- get
            -- so the completion can get the current state
            liftIO $ modifyMVar_ completionMVar (const (return st))
            -- liftIO $ print (cl_pretty st, cl_cursor (cl_session st))
            let SAST n = cl_cursor (cl_session st)
            maybeLine <- if cl_nav (cl_session st)
                         then liftIO $ getNavCmd
                         else lift $ lift $ getInputLine $ "hermit<" ++ show n ++ "> "

            case maybeLine of
                Nothing             -> performMetaCommand Resume
                Just ('-':'-':_msg) -> loop'
                Just line           ->
                    if all isSpace line
                    then loop'
                    else (case parseStmtsH line of
                                Left  msg   -> throwError ("parse failure: " ++ msg)
                                Right stmts -> evalStmts stmts) `ourCatch` (\ msg ->
                                        do putStrLn $ "Failure: " ++ msg
                          ) >> loop'

ourCatch :: (m ~ IO, MonadIO n) => CLM m () -> (String -> IO ()) -> CLM n ()
ourCatch m failure = do
                st <- get
                (res,st') <- liftIO $ runStateT (runErrorT m) st
                put st'
                case res of
                  Left msg -> liftIO $ failure msg
                  Right () -> return ()



evalStmts :: (MonadIO m) => [StmtH ExprH] -> CLM m ()
evalStmts = mapM_ evalExpr . scopes
    where scopes :: [StmtH ExprH] -> [ExprH]
          scopes [] = []
          scopes (ExprH e:ss) = e : scopes ss
          scopes (ScopeH s:ss) = (CmdName "{" : scopes s) ++ [CmdName "}"] ++ scopes ss


evalExpr :: (MonadIO m) => ExprH -> CLM m ()
evalExpr expr = do
    dict <- gets cl_dict
    case interpExprH
                dict
                interpShellCommand
                expr of
            Left msg  -> throwError $ msg
            Right cmd -> do
                condM (gets (cl_loading . cl_session))
                      (liftIO (putStrLn $ "doing : " ++ show expr))
                      (return ())
                case cmd of
                  AstEffect effect   -> performAstEffect effect expr
                  ShellEffect effect -> performShellEffect effect
                  QueryFun query     -> performQuery query
                  MetaCommand meta   -> performMetaCommand meta

-------------------------------------------------------------------------------

-- TODO: This can be refactored. We always showFocus. Also, Perhaps return a modifier, not ()

performAstEffect :: (MonadIO m) => AstEffect -> ExprH -> CLM m ()
performAstEffect (Apply rr) expr = do
    st <- get
    -- something changed (you've applied)
    eiast <- liftIO $ (do ast' <- applyS (cl_kernel st) (cl_cursor (cl_session st)) rr
                          return $ Right ast')
                            `catch` \ msg -> return $ Left $ "Error thrown: " ++ msg
    either (throwError) (\ast' -> do put $ newSAST expr ast' st
                                     showFocus
                                     return ()) eiast
performAstEffect (Pathfinder t) expr = do
    st <- get
    -- An extension to the Path
    -- TODO: thread this putStr into the throwError
    ast <- liftIO $ do
        p <- queryS (cl_kernel st) (cl_cursor (cl_session st)) t `catch` (\ msg -> (putStrLn $ "Error thrown: " ++ msg) >> return [])
        modPathS (cl_kernel st) (cl_cursor (cl_session st)) (++ p)
    put $ newSAST expr ast st
    showFocus
performAstEffect (Direction dir) expr = do
    st <- get
    ast <- liftIO $ do
        child_count <- queryS (cl_kernel st) (cl_cursor (cl_session st)) numChildrenT
        print (child_count, dir)
        modPathS (cl_kernel st) (cl_cursor (cl_session st)) (scopePath2Path . moveLocally dir . path2ScopePath)
    put $ newSAST expr ast st
    -- something changed, to print
    showFocus
--performAstEffect (ShellState' f) = get >>= liftIO . f >>= put >> showFocus
performAstEffect (PushFocus ls) expr = do
    st <- get
    ast <- liftIO $ modPathS (cl_kernel st) (cl_cursor (cl_session st)) (++ ls)
    put $ newSAST expr ast st
    showFocus
performAstEffect BeginScope expr = do
        st <- get
        ast <- liftIO $ beginScopeS (cl_kernel st) (cl_cursor (cl_session st))
        put $ newSAST expr ast st
        showFocus
performAstEffect EndScope expr = do
        st <- get
        ast <- liftIO $ endScopeS (cl_kernel st) (cl_cursor (cl_session st))
        put $ newSAST expr ast st
        showFocus


-------------------------------------------------------------------------------

performShellEffect :: (MonadIO m) => ShellEffect -> CLM m ()
performShellEffect (SessionStateEffect f) = do
        st <- get
        opt <- liftIO (fmap Right (f st (cl_session st)) `catch` \ str -> return (Left str))
        case opt of
          Right s_st' -> do put (st { cl_session = s_st' })
                            showFocus
          Left err -> throwError err

-------------------------------------------------------------------------------

performQuery :: (MonadIO m) => QueryFun -> CLM m ()
performQuery (QueryT q) = do
    st <- get
    -- something changed, to print
    liftIO ((queryS (cl_kernel st) (cl_cursor (cl_session st)) q >>= putStrLn)
              `catch` \ msg -> putStrLn $ "Error thrown: " ++ msg)
performQuery Status = do
    st <- get
    liftIO $ do
        ps <- pathS (cl_kernel st) (cl_cursor (cl_session st))
        putStrLn $ "Paths: " ++ show ps
        print $ ("Graph",cl_graph st)
        print $ ("This",cl_cursor (cl_session st))
performQuery (Inquiry f) = do
    st <- get
    liftIO $ do
        msg <- f st (cl_session st)
        putStrLn $ msg
performQuery (Message msg) = liftIO (putStrLn msg)

-------------------------------------------------------------------------------

performMetaCommand :: (MonadIO m) => MetaCommand -> CLM m ()
performMetaCommand Abort  = gets cl_kernel >>= (liftIO . abortS)
performMetaCommand Resume = get >>= \st -> liftIO $ resumeS (cl_kernel st) (cl_cursor (cl_session st))
performMetaCommand (Dump fileName _pp renderer _) = do
    st <- get
    case (M.lookup (cl_pretty (cl_session st)) pp_dictionary,lookup renderer finalRenders) of
        (Just pp, Just r) -> liftIO $ do
            doc <- queryS (cl_kernel st) (cl_cursor (cl_session st)) (pp (cl_pretty_opts (cl_session st)))
            h <- openFile fileName WriteMode
            r h (cl_pretty_opts (cl_session st)) doc
            hClose h
        _ -> throwError "dump: bad pretty-printer or renderer option"
performMetaCommand (LoadFile fileName) = do
        liftIO $ putStrLn $ "[including " ++ fileName ++ "]"
        res <- liftIO $ try (readFile fileName)
        case res of
          Right str -> case parseStmtsH (normalize str) of
                        Left  msg  -> throwError ("parse failure: " ++ msg)
                        Right stmts -> do
                            modify $ \st -> st { cl_session = (cl_session st) { cl_loading = True } }
                            evalStmts stmts
                            modify $ \st -> st { cl_session = (cl_session st) { cl_loading = False } }
          Left (err :: IOException) -> throwError ("IO error: " ++ show err)
  where
   normalize = unlines
             . map (++ ";")     -- HACK!
             . map (rmComment)
             . lines
   rmComment []     = []
   rmComment xs     | "--" `isPrefixOf` xs = [] -- we need a real parser and lexer here!
   rmComment (x:xs) = x : rmComment xs




-------------------------------------------------------------------------------

newtype UnicodeTerminal = UnicodeTerminal (Handle -> Maybe Path -> IO ())

instance RenderSpecial UnicodeTerminal where
        renderSpecial sym = UnicodeTerminal $ \ h _ -> hPutStr h [ch]
                where (Unicode ch) = renderSpecial sym

instance Monoid UnicodeTerminal where
        mempty = UnicodeTerminal $ \ _ _ -> return ()
        mappend (UnicodeTerminal f1) (UnicodeTerminal f2) = UnicodeTerminal $ \ h p -> f1 h p >> f2 h p

finalRenders :: [(String,Handle -> PrettyOptions -> DocH -> IO ())]
finalRenders =
        [ ("unicode-terminal", unicodeConsole)
        ] ++ coreRenders

unicodeConsole :: Handle -> PrettyOptions -> DocH -> IO ()
unicodeConsole h w doc = do
    let (UnicodeTerminal prty) = renderCode w doc
    prty h Nothing


instance RenderCode UnicodeTerminal where
        rPutStr txt  = UnicodeTerminal $ \ h _ -> hPutStr h txt

        rDoHighlight _ [] = UnicodeTerminal $ \ h _ -> do
                hSetSGR h [Reset]
        rDoHighlight _ (Color col:_) = UnicodeTerminal $ \ h _ -> do
                hSetSGR h [ Reset ]
                hSetSGR h $ case col of
                        KeywordColor -> [ SetConsoleIntensity BoldIntensity
                                        , SetColor Foreground Dull Blue
                                        ]
                        SyntaxColor  -> [ SetColor Foreground Dull Red ]
                        VarColor     -> []   -- as is
                        TypeColor    -> [ SetColor Foreground Dull Green ]
                        LitColor     -> [ SetColor Foreground Dull Cyan ]
        rDoHighlight o (_:rest) = rDoHighlight o rest
        rEnd = UnicodeTerminal $ \ h _ -> hPutStrLn h ""

--------------------------------------------------------

navigation :: Navigation -> CommandLineState -> SessionState -> IO SessionState
navigation whereTo st sess_st = do
    case whereTo of
      Goto n -> do
           all_nds <- listS (cl_kernel st)
           if (SAST n) `elem` all_nds
              then do
                 return $ sess_st { cl_cursor = SAST n }
              else do
                 fail $ "Can not find AST #" ++ show n
      GotoTag tag -> do
           case lookup tag (cl_tags st) of
              Just sast -> return $ sess_st { cl_cursor = sast }
              _ -> fail $ "Can not find tag " ++ show tag
      Step -> do
           let ns = [ edge | edge@(s,_,_) <- cl_graph st, s == cl_cursor (cl_session st) ]
           case ns of
             [] -> do
                 fail $ "Can not step forward (no more steps)"
             [(_,_,d) ] -> do
                     -- TODO: give message
                  return $ sess_st { cl_cursor = d }
             _ -> do
                 fail "Can not step forward (multiple choices)"
      Back -> do
           let ns = [ edge | edge@(_,_,d) <- cl_graph st, d == cl_cursor (cl_session st) ]
           case ns of
             [] -> do
                  fail $ "Can not step backwards (no more steps)"
             [(s,cmd,_) ] -> do
                  -- TODO: give message about undoing
                  return $ sess_st { cl_cursor = s }
             _ -> do
                 fail $ "Can not step backwards (multiple choices, impossible!)"

--------------------------------------------------------

getNavCmd :: IO (Maybe String)
getNavCmd = do
        b_in <- hGetBuffering stdin
        hSetBuffering stdin NoBuffering
        b_out <- hGetBuffering stdin
        hSetBuffering stdout NoBuffering
        ec_in <- hGetEcho stdin
        hSetEcho stdin False
        putStr ("(navigation mode; use arrow keys, escape to quit, '?' for help)")
        r <- readCh []
        putStr ("\n")
        hSetBuffering stdin b_in
        hSetBuffering stdout b_out
        hSetEcho stdin ec_in
        return r
  where
   readCh xs = do
        x <- getChar
        let str = xs ++ [x]
        (case lookup str cmds of
          Just f -> f
          Nothing -> reset) str

   reset _ = do
        putStr "\BEL"
        readCh []

   res str _ = return (Just str)

   cmds = [ ("\ESC" , \ str -> condM (hReady stdin)
                                     (readCh str)
                                     (return (Just ":command-line")))
          , ("\ESC[" , readCh)
          , ("\ESC[A", res "up")
          , ("\ESC[B", res "down")
          , ("\ESC[C", res "right")
          , ("\ESC[D", res "left")
          , ("?",      res ":nav-commands")
          , ("f",      res ":step")
          ] ++
          [ (show n, res (show n)) | n <- [0..9] :: [Int] ]


showDerivationTree :: CommandLineState -> SessionState -> IO String
showDerivationTree st ss = return $ unlines $ showRefactorTrail graph 0 me
  where
          graph = [ (a,[show b],c) | (SAST a,b,SAST c) <- cl_graph st ]
          SAST me = cl_cursor ss

showRefactorTrail :: (Eq a, Show a) => [(a,[String],a)] -> a -> a -> [String]
showRefactorTrail db a me =
        case [ (b,c) | (a0,b,c) <- db, a == a0 ] of
           [] -> [show' 3 a ++ " " ++ dot]
           ((b,c):bs) ->
                      [show' 3 a ++ " " ++ dot ++ if (not (null bs)) then "->" else ""] ++
                      ["    " ++ "| " ++ txt | txt <- b ] ++
                      showRefactorTrail db c me ++
                      if null bs
                      then []
                      else [[]] ++
                          showRefactorTrail [ (a',b',c') | (a',b',c') <- db
                                                          , not (a == a' && c == c')
                                                          ]  a me

  where
          dot = if a == me then "*" else "o"
          show' n a = take (n - length (show a)) (repeat ' ') ++ show a



