{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module HERMIT.Shell.Proof
    ( externals
    , UserProofTechnique
    , userProofTechnique
    , withProofExternals
    , performProofShellCommand
    , interpProof
    ) where

import Control.Arrow hiding (loop, (<+>))
import Control.Monad (forM, forM_, liftM, unless)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.State (MonadState(get), modify, gets)

import Data.Dynamic
import Data.List (delete)
import qualified Data.Map as M
import Data.Monoid
import Data.String (fromString)

import HERMIT.Context
import HERMIT.Core
import HERMIT.External
import HERMIT.GHC hiding (settings, (<>), text, sep, (<+>), ($+$), nest)
import HERMIT.Kernel
import HERMIT.Kure
import HERMIT.Lemma
import HERMIT.Name
import HERMIT.Parser
import HERMIT.Syntax
import HERMIT.Utilities

import HERMIT.Dictionary.Induction
import HERMIT.Dictionary.Reasoning hiding (externals)

import HERMIT.PrettyPrinter.Common

import HERMIT.Shell.Interpreter
import HERMIT.Shell.KernelEffect
import HERMIT.Shell.ScriptToRewrite
import HERMIT.Shell.ShellEffect
import HERMIT.Shell.Types

--------------------------------------------------------------------------------------------------------

-- | Externals that get us into the prover shell.
externals :: [External]
externals = map (.+ Proof)
    [ external "prove-lemma" (CLSModify . interactiveProofIO)
        [ "Proof a lemma interactively." ]
    ]

-- | Externals that are added to the dictionary only when in interactive proof mode.
proof_externals :: [External]
proof_externals = map (.+ Proof)
    [ external "induction" (PCInduction . cmpString2Var :: String -> ProofShellCommand)
        [ "Perform induction on given universally quantified variable."
        , "Each constructor case will generate a new lemma to be proven."
        ]
    , external "prove-consequent" PCConsequent
        [ "Prove the consequent of an implication by assuming the antecedent." ]
    , external "prove-antecedent" PCAntecedent
        [ "Introduce a proven lemma corresponding to the consequent by proving the antecedent." ]
    , external "prove-conjuction" PCConjunction
        [ "Prove a conjuction by proving both sides of it." ]
    , external "inst-assumed" (\ i nm cs -> PCInstAssumed i (cmpHN2Var nm) cs)
        [ "Split an assumed lemma which is a conjuction/disjunction." ]
    , external "split-assumed" PCSplitAssumed
        [ "Split an assumed lemma which is a conjuction/disjunction." ]
    , external "dump" (\pp fp r w -> promoteT (liftPrettyH (pOptions pp) (ppQuantifiedT pp)) >>> dumpT fp pp r w :: TransformH QC ())
        [ "dump <filename> <renderer> <width>" ]
    , external "end-proof" PCEnd
        [ "check for alpha-equality, marking the lemma as proven" ]
    , external "end-case" PCEnd
        [ "check for alpha-equality, marking the proof case as proven" ]
    ]

--------------------------------------------------------------------------------------------------------

-- | Top level entry point!
interactiveProofIO :: LemmaName -> CommandLineState -> IO (Either CLException CommandLineState)
interactiveProofIO nm s = do
    (r,st) <- runCLT s $ do
                ps <- getProofStackEmpty
                let cT = case ps of
                            pt@(Unproven {}) : _ ->
                                 return (lemmaQ (ptLemma pt))
                                    >>> extractT (pathT (pathStack2Path (ptPath pt)) contextT :: TransformH QC HermitC)
                            _ -> contextT
                (c,l) <- queryInFocus (cT &&& getLemmaByNameT nm :: TransformH Core (HermitC,Lemma)) (Always $ "prove-lemma " ++ quoteShow nm)
                pushProofStack $ Unproven nm l c [] mempty False
    return $ fmap (const st) r

withProofExternals :: (MonadError CLException m, MonadState CommandLineState m) => m a -> m a
withProofExternals comp = do
    st <- get
    let es = cl_externals st
        -- commands with same same in proof_externals will override those in normal externals
        newEs = proof_externals ++ filter ((`notElem` (map externName proof_externals)) . externName) es
        reset s = s { cl_externals = es }
    modify $ \ s -> s { cl_externals = newEs }
    r <- comp `catchError` (\case CLContinue s -> continue (reset s)
                                  other        -> modify reset >> throwError other)
    modify reset
    return r

-- TODO: remove for the one in Command
runProofExprH :: (MonadCatch m, CLMonad m) => ExprH -> m ()
runProofExprH expr = prefixFailMsg ("Error in expression: " ++ unparseExprH expr ++ "\n")
                   $ interpExprH interpProof expr >>= performProofShellCommand expr

-- | Verify that the lemma has been proven. Throws an exception if it has not.
endProof :: (MonadCatch m, CLMonad m) => ExprH -> m ()
endProof expr = do
    Unproven nm (Lemma q _ _) _ _ _ temp : _ <- getProofStack
    let msg = "The two sides of " ++ quoteShow nm ++ " are not alpha-equivalent."
        t = verifyQuantifiedT >> unless temp (markLemmaProvedT nm)
    queryInFocus (return q >>> setFailMsg msg t :: TransformH Core ()) (Always $ unparseExprH expr ++ " -- proven " ++ quoteShow nm)
    _ <- popProofStack
    cl_putStrLn $ "Successfully proven: " ++ show nm

-- Note [Query]
-- We want to do our proof in the current context of the shell, whatever that is,
-- so we run them using queryInFocus below. This has the benefit that proof commands
-- can generate additional lemmas, and add to the version history.
performProofShellCommand :: (MonadCatch m, CLMonad m)
                         => ExprH -> ProofShellCommand -> m ()
performProofShellCommand expr = go
    where str = unparseExprH expr
          go (PCRewrite rr) = do
                -- careful to only modify the lemma in the resulting AST
                Unproven nm (Lemma q p u) c ls pth t : todos <- getProofStack
                q' <- queryInFocus (return q >>> extractR (pathR (pathStack2Path pth) rr >>> (promoteT lintQuantifiedT >> idR)) :: TransformH Core Quantified) (Always str)
                let todo = Unproven nm (Lemma q' p u) c ls pth t
                modify $ \ st -> st { cl_proofstack = M.insert (cl_cursor st) (todo:todos) (cl_proofstack st) }
          go (PCTransform t) = do
                (_, Lemma q _ _, _, _, p) <- currentLemma
                cl_putStrLn =<< queryInFocus (return q >>> extractT (pathT (pathStack2Path p) t) :: TransformH Core String) (Changed str)
          go (PCUnit t) = do
                (_, Lemma q _ _, _, _, p) <- currentLemma
                queryInFocus (return q >>> extractT (pathT (pathStack2Path p) t) :: TransformH Core ()) (Changed str)
          go (PCInduction idPred) = performInduction (Always str) idPred
          go PCConsequent         = proveConsequent str
          go PCAntecedent         = proveAntecedent str
          go PCConjunction        = proveConjuction str
          go (PCInstAssumed i v cs) = instAssumed i v cs str
          go (PCSplitAssumed i)   = splitAssumed i str
          go (PCShell effect)     = performShellEffect effect
          go (PCKernel effect)    = performKernelEffect expr effect
          go (PCScript effect)    = performScriptEffect runProofExprH effect
          go (PCQuery query)      = performQuery query expr
          go (PCUser prf)         = do
                let UserProofTechnique t = prf -- may add more constructors later
                -- note: we assume that if 't' completes without failing,
                -- the lemma is proved, we don't actually check
                Unproven nm (Lemma q _ _) _ _ _ temp : _ <- getProofStack
                queryInFocus (return q >>> (extractT t >> unless temp (markLemmaProvedT nm)) :: TransformH Core ()) (Changed str)
                _ <- popProofStack
                cl_putStrLn $ "Successfully proven: " ++ show nm
          go PCEnd                = endProof expr
          go (PCPath tr) = do
                Unproven nm (Lemma q p u) c ls pth@(base,rel) t : todos <- getProofStack
                rel' <- queryInFocus (return q >>> extractT (pathT (pathStack2Path pth) tr) :: TransformH Core LocalPathH) (Always str)
                -- TODO: test if valid path
                let todo = Unproven nm (Lemma q p u) c ls (base, rel <> rel') t
                modify $ \ st -> st { cl_proofstack = M.insert (cl_cursor st) (todo:todos) (cl_proofstack st) }
          go (PCUnsupported s)    = cl_putStrLn (s ++ " command unsupported in proof mode.")

proveConsequent :: (MonadCatch m, CLMonad m) => String -> m ()
proveConsequent expr = do
    Unproven nm (Lemma (Quantified bs cl) p u) c ls _ t : _ <- getProofStack
    (q,ls') <- case cl of
                Impl ante (Quantified cBs ccl) ->
                    let n = nm <> "-antecedent"
                        l = Lemma ante True False
                    in return (Quantified (bs++cBs) ccl, (n,l):ls)
                _ -> fail "not an implication."
    let nm' = nm <> "-consequent"
    (k,ast) <- gets (cl_kernel &&& cl_cursor)
    addAST =<< tellK k expr ast
    _ <- popProofStack
    pushProofStack $ Proven nm t -- proving the consequent proves the lemma
    pushProofStack $ Unproven nm' (Lemma q p u) c ls' mempty True

proveAntecedent :: (MonadCatch m, CLMonad m) => String -> m ()
proveAntecedent expr = do
    Unproven nm (Lemma (Quantified bs cl) p u) c ls _ _ : _ <- getProofStack
    case cl of
        Impl (Quantified aBs acl) (Quantified cBs ccl) -> do
            let cnm = nm <> "-consequent"
                cq = Quantified (bs++cBs) ccl
                anm = nm <> "-antecedent"
                alem = Lemma (Quantified (bs++aBs) acl) False u
            (k,ast) <- gets (cl_kernel &&& cl_cursor)
            addAST =<< tellK k expr ast
            _ <- popProofStack
            pushProofStack $ IntroLemma cnm cq p -- proving the antecedent introduces the consequent as a lemma
            pushProofStack $ Unproven anm alem c ls mempty True
        _ -> fail "not an implication."

proveConjuction :: (MonadCatch m, CLMonad m) => String -> m ()
proveConjuction expr = do
    Unproven nm (Lemma (Quantified bs cl) p u) c ls _ t : _ <- getProofStack
    case cl of
        Conj (Quantified lbs lcl) (Quantified rbs rcl) -> do
            (k,ast) <- gets (cl_kernel &&& cl_cursor)
            addAST =<< tellK k expr ast
            _ <- popProofStack
            pushProofStack $ Proven nm t
            pushProofStack $ Unproven (nm <> "-r") (Lemma (Quantified (bs++rbs) rcl) p u) c ls mempty True
            pushProofStack $ Unproven (nm <> "-l") (Lemma (Quantified (bs++lbs) lcl) p u) c ls mempty True
        _ -> fail "not a conjuction."

splitAssumed :: (MonadCatch m, CLMonad m) => Int -> String -> m ()
splitAssumed i expr = do
    Unproven nm lem c ls ps t : _ <- getProofStack
    (b, (n, Lemma q p u):a) <- getIth i ls
    qs <- splitQuantified q
    let nls = [ (n <> fromString (show j), Lemma q' p u) | (j::Int,q') <- zip [0..] qs ]
    (k,ast) <- gets (cl_kernel &&& cl_cursor)
    addAST =<< tellK k expr ast
    _ <- popProofStack
    pushProofStack $ Unproven nm lem c (b ++ nls ++ a) ps t

instAssumed :: (MonadCatch m, CLMonad m) => Int -> (Var -> Bool) -> CoreString -> String -> m ()
instAssumed i pr cs expr = do
    Unproven nm lem c ls ps t : _ <- getProofStack
    (b, orig@(n, Lemma q p u):a) <- getIth i ls
    let tr :: TransformH QC Quantified
        tr = return q >>> instantiateQuantifiedVarR pr cs
    q' <- queryInFocus (return (lemmaQ lem) >>> extractT (pathT (pathStack2Path ps) tr) :: TransformH Core Quantified) Never
    (k,ast) <- gets (cl_kernel &&& cl_cursor)
    addAST =<< tellK k expr ast
    _ <- popProofStack
    pushProofStack $ Unproven nm lem c (b ++ (n <> "'", Lemma q' p u):orig:a) ps t

getIth :: MonadCatch m => Int -> [a] -> m ([a],[a])
getIth _ [] = fail "getIth: out of range"
getIth n (x:xs) = go n x xs []
    where go 0 y ys zs = return (reverse zs, y:ys)
          go _ _ [] _  = fail "getIth: out of range"
          go i z (y:ys) zs = go (i-1) y ys (z:zs)

-- | Always returns non-empty list, or fails.
splitQuantified :: MonadCatch m => Quantified -> m [Quantified]
splitQuantified (Quantified bs cl) = do
    case cl of
        Conj (Quantified lbs lcl) (Quantified rbs rcl) ->
            return [Quantified (bs++lbs) lcl, Quantified (bs++rbs) rcl]
        Disj (Quantified lbs lcl) (Quantified rbs rcl) ->
            return [Quantified (bs++lbs) lcl, Quantified (bs++rbs) rcl]
        Impl (Quantified lbs lcl) (Quantified rbs rcl) ->
            return [Quantified (bs++lbs) lcl, Quantified (bs++rbs) rcl]
        _ -> fail "equalities cannot be split!"

performInduction :: (MonadCatch m, CLMonad m)
                 => CommitMsg -> (Id -> Bool) -> m ()
performInduction cm idPred = do
    (nm, Lemma q@(Quantified bs (Equiv lhs rhs)) _ _, _, ls, _) <- currentLemma
    i <- setFailMsg "specified identifier is not universally quantified in this equality lemma." $
         soleElement (filter idPred bs)

    -- Why do a query? We want to do our proof in the current context of the shell, whatever that is.
    cases <- queryInFocus (inductionCaseSplit bs i lhs rhs :: TransformH Core [(Maybe DataCon, [Var], CoreExpr, CoreExpr)])
                          cm

    -- replace the current lemma with the three subcases
    -- proving them will prove this case automatically
    pt@(Unproven {}) <- popProofStack
    pushProofStack $ Proven nm $ ptTemp pt
    forM_ (reverse cases) $ \ (mdc,vs,lhsE,rhsE) -> do

        let vs_matching_i_type = filter (typeAlphaEq (varType i) . varType) vs
            caseName = maybe "undefined" unqualifiedName mdc

        -- Generate list of specialized induction hypotheses for the recursive cases.
        qs <- forM vs_matching_i_type $ \ i' -> do
                liftM discardUniVars $ instQuantified (==i) (Var i') q
                -- TODO rethink the discardUniVars

        let nms = [ fromString ("ind-hyp-" ++ show n) | n :: Int <- [0..] ]
            hypLemmas = zip nms $ zipWith3 Lemma qs (repeat True) (repeat False)
            lemmaName = fromString $ show nm ++ "-induction-on-" ++ unqualifiedName i ++ "-case-" ++ caseName
            caseLemma = Lemma (mkQuantified (delete i bs ++ vs) lhsE rhsE) False False

        pushProofStack $ Unproven lemmaName caseLemma (ptContext pt) (hypLemmas ++ ls) mempty True

data ProofShellCommand
    = PCRewrite (RewriteH QC)
    | PCTransform (TransformH QC String)
    | PCUnit (TransformH QC ())
    | PCInduction (Id -> Bool)
    | PCConsequent
    | PCAntecedent
    | PCConjunction
    | PCSplitAssumed Int
    | PCInstAssumed Int (Var -> Bool) CoreString
    | PCShell ShellEffect
    | PCKernel KernelEffect
    | PCScript ScriptEffect
    | PCQuery QueryFun
    | PCUser UserProofTechnique
    | PCEnd
    | PCPath (TransformH QC LocalPathH)
    | PCUnsupported String
    deriving Typeable

-- keep abstract to avoid breaking things if we modify this later
newtype UserProofTechnique = UserProofTechnique (TransformH QC ())
    deriving Typeable

userProofTechnique :: TransformH QC () -> UserProofTechnique
userProofTechnique = UserProofTechnique

instance Extern ProofShellCommand where
    type Box ProofShellCommand = ProofShellCommand
    box i = i
    unbox i = i

instance Extern UserProofTechnique where
    type Box UserProofTechnique = UserProofTechnique
    box i = i
    unbox i = i

interpProof :: Monad m => [Interp m ProofShellCommand]
interpProof =
  [ interp $ \ (RewriteCoreBox rr)            -> PCRewrite $ core2qcR rr
  , interp $ \ (RewriteCoreTCBox rr)          -> PCRewrite $ core2qcR $ extractR rr
  , interp $ \ (BiRewriteCoreBox br)          -> PCRewrite $ core2qcR $ forwardT br <+ backwardT br
  , interp $ \ (effect :: ShellEffect)        -> PCShell effect
  , interp $ \ (effect :: KernelEffect)       -> PCKernel effect
  , interp $ \ (effect :: ScriptEffect)       -> PCScript effect
  , interp $ \ (StringBox str)                -> PCQuery (message str)
  , interp $ \ (query :: QueryFun)            -> PCQuery query
  , interp $ \ (RewriteQCBox r)               -> PCRewrite r
  , interp $ \ (TransformQCStringBox t)       -> PCTransform t
  , interp $ \ (TransformQCUnitBox t)         -> PCUnit t
  , interp $ \ (t :: UserProofTechnique)      -> PCUser t
  , interp $ \ (cmd :: ProofShellCommand)     -> cmd
  , interp $ \ (CrumbBox cr)                  -> PCPath (return $ mempty @@ cr)
  , interp $ \ (PathBox p)                    -> PCPath (return p)
  , interp $ \ (TransformCorePathBox tt)      -> PCPath (promoteT (extractT tt :: TransformH CoreExpr LocalPathH))
  , interp $ \ (TransformCoreTCPathBox tt)    -> PCPath (promoteT (extractT tt :: TransformH CoreExpr LocalPathH))
  , interp $ \ (TransformCoreDocHBox t)       -> PCQuery (QueryDocH t)
  , interp $ \ (TransformCoreTCDocHBox t)     -> PCQuery (QueryDocH t)
  , interp $ \ (PrettyHCoreBox t)             -> PCQuery (QueryPrettyH t)
  , interp $ \ (PrettyHCoreTCBox t)           -> PCQuery (QueryPrettyH t)
  , interp $ \ (TransformCoreStringBox tt)    -> PCQuery (QueryString tt)
  , interp $ \ (TransformCoreTCStringBox tt)  -> PCQuery (QueryString tt)
  , interp $ \ (TransformCoreCheckBox tt)     -> PCQuery (CorrectnessCriteria tt)
  , interp $ \ (TransformCoreTCCheckBox tt)   -> PCQuery (CorrectnessCriteria tt)
  -- , interp $ \ (_effect :: KernelEffect)      -> PCUnsupported "KernelEffect"
  ]

