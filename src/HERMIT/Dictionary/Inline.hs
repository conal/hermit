{-# LANGUAGE CPP, TupleSections, FlexibleContexts, ScopedTypeVariables #-}
module HERMIT.Dictionary.Inline
    ( -- * Inlining
      externals
    , InlineConfig(..)
    , CaseBinderInlineOption(..)
    , getUnfoldingT
    , getUnfoldingsT
    , ensureBoundT
    , inlineR
    , inlineNameR
    , inlineNamesR
    , inlineMatchingPredR
    , inlineCaseScrutineeR
    , inlineCaseAlternativeR
    , configurableInlineR
    , inlineTargetsT
    ) where

import Control.Arrow
import Control.Monad

import HERMIT.Context
import HERMIT.Core
import HERMIT.External
import HERMIT.GHC
import HERMIT.Kure
import HERMIT.Name

import HERMIT.Dictionary.Common

------------------------------------------------------------------------

-- | 'External's for inlining variables.
externals :: [External]
externals =
    [ external "inline" (promoteExprR inlineR :: RewriteH LCore)
        [ "(Var v) ==> <defn of v>" ].+ Eval .+ Deep
    , external "inline" (promoteExprR . inlineMatchingPredR . mkOccPred :: OccurrenceName -> RewriteH LCore)
        [ "Given a specific v, (Var v) ==> <defn of v>" ] .+ Eval .+ Deep
    , external "inline" (promoteExprR . inlineNamesR :: [String] -> RewriteH LCore)
        [ "If the current variable matches any of the given names, then inline it." ] .+ Eval .+ Deep
    , external "inline-case-scrutinee" (promoteExprR inlineCaseScrutineeR :: RewriteH LCore)
        [ "if v is a case binder, replace (Var v) with the bound case scrutinee." ] .+ Eval .+ Deep
    , external "inline-case-alternative" (promoteExprR inlineCaseAlternativeR :: RewriteH LCore)
        [ "if v is a case binder, replace (Var v) with the bound case-alternative pattern." ] .+ Eval .+ Deep
    ]

------------------------------------------------------------------------

-- extend these data types as needed if other inlining behaviour becomes desireable
data CaseBinderInlineOption = Scrutinee | Alternative deriving (Eq, Show)
data InlineConfig           = CaseBinderOnly CaseBinderInlineOption | AllBinders deriving (Eq, Show)

-- | If the current variable matches the given name, then inline it.
inlineNameR :: ( ExtendPath c Crumb, ReadPath c Crumb, AddBindings c
               , ReadBindings c, HasEmptyContext c, MonadCatch m )
            => String -> Rewrite c m CoreExpr
inlineNameR nm = inlineMatchingPredR (cmpString2Var nm)

-- | If the current variable matches any of the given names, then inline it.
inlineNamesR :: ( ExtendPath c Crumb, ReadPath c Crumb, AddBindings c
                , ReadBindings c, HasEmptyContext c, MonadCatch m )
             => [String] -> Rewrite c m CoreExpr
inlineNamesR []  = fail "inline-names failed: no names given."
inlineNamesR nms = inlineMatchingPredR (\ v -> any (flip cmpString2Var v) nms)

-- | If the current variable satisifies the predicate, then inline it.
inlineMatchingPredR :: ( ExtendPath c Crumb, ReadPath c Crumb, AddBindings c
                       , ReadBindings c, HasEmptyContext c, MonadCatch m )
                    => (Id -> Bool) -> Rewrite c m CoreExpr
inlineMatchingPredR idPred = configurableInlineR AllBinders (arr $ idPred)

-- | Inline the current variable.
inlineR :: (AddBindings c, ExtendPath c Crumb, HasEmptyContext c,
            ReadBindings c, ReadPath c Crumb, MonadCatch m )
        => Rewrite c m CoreExpr
inlineR = configurableInlineR AllBinders (return True)

-- | Inline the current identifier if it is a case binder, using the scrutinee rather than the case-alternative pattern.
inlineCaseScrutineeR :: ( ExtendPath c Crumb, ReadPath c Crumb, AddBindings c
                        , ReadBindings c, HasEmptyContext c, MonadCatch m )
                     => Rewrite c m CoreExpr
inlineCaseScrutineeR = configurableInlineR (CaseBinderOnly Scrutinee) (return True)

-- | Inline the current identifier if is a case binder, using the case-alternative pattern rather than the scrutinee.
inlineCaseAlternativeR :: ( ExtendPath c Crumb, ReadPath c Crumb, AddBindings c
                          , ReadBindings c, HasEmptyContext c, MonadCatch m )
                       => Rewrite c m CoreExpr
inlineCaseAlternativeR = configurableInlineR (CaseBinderOnly Alternative) (return True)

-- | The implementation of inline, an important transformation.
-- This *only* works if the current expression has the form @Var v@ (it does not traverse the expression).
-- It can trivially be prompted to more general cases using traversal strategies.
configurableInlineR :: ( AddBindings c, ExtendPath c Crumb, HasEmptyContext c, ReadBindings c
                       , ReadPath c Crumb, MonadCatch m )
                    => InlineConfig
                    -> (Transform c m Id Bool) -- ^ Only inline identifiers that satisfy this predicate.
                    -> Rewrite c m CoreExpr
configurableInlineR config p =
   prefixFailMsg "Inline failed: " $
   do b <- varT p
      guardMsg b "identifier does not satisfy predicate."
      (e,uncaptured) <- varT (getUnfoldingT config)
      return e >>> ensureBoundT -- fails if not all bound
      setFailMsg "values in inlined expression have been rebound."
        (return e >>> accepterR (ensureDepthT uncaptured))

-- | Check that all free variables in an expression are bound.
-- Fails, listing unbound variables if not.
ensureBoundT :: (Monad m, ReadBindings c) => Transform c m CoreExpr ()
ensureBoundT = do
    unbound <- transform $ \ c -> return . filterVarSet (not . inScope c) . localFreeVarsExpr
    guardMsg (isEmptyVarSet unbound) $ "the following variables are unbound: " ++ showVarSet unbound

-- NOTE: When inlining, we have to take care to avoid variable capture.
--       Our approach is to track the binding depth of the inlined identifier.
--       After inlining, we then resolve all names in the inlined expression, and require that they were all bound prior to (i.e. lower numbered depth) the binding we inlined.
--       The precise depth check varies between binding sites as follows (where d is the depth of the inlined binder):
--
--         Binding Site          Safe to Inline
--         global-id             (<= 0)
--         NONREC                (< d)
--         REC                   (<= d)
--         MUTUALREC             (<= d+1)
--         CASEBINDER-scrutinee  (< d)
--         CASEBINDER-alt        (<= d+1)
--         SELFREC-def           NA
--         LAM                   NA
--         CASEALT               NA


-- | Ensure all the free variables in an expression were bound above a given depth.
-- Assumes minimum depth is 0.
ensureDepthT :: forall c m. (ExtendPath c Crumb, ReadPath c Crumb, AddBindings c, ReadBindings c, HasEmptyContext c, MonadCatch m) => (BindingDepth -> Bool) -> Transform c m CoreExpr Bool
ensureDepthT uncaptured =
  do frees <- arr localFreeVarsExpr
     let collectDepthsT :: Transform c m Core [BindingDepth]
         collectDepthsT = collectT $ promoteExprT $ varT (acceptR (`elemVarSet` frees) >>> readerT varBindingDepthT)
     all uncaptured `liftM` extractT collectDepthsT

-- | Return the unfolding of an identifier, and a predicate over the binding depths of all variables within that unfolding to determine if they have been captured in their new location.
getUnfoldingT :: (ReadBindings c, MonadCatch m)
              => InlineConfig
              -> Transform c m Id (CoreExpr, BindingDepth -> Bool)
getUnfoldingT config = do
    r <- getUnfoldingsT config
    case r of
        [] -> fail "no unfolding for variable."
        (u:_) -> return u

getUnfoldingsT :: (ReadBindings c, MonadCatch m)
               => InlineConfig
               -> Transform c m Id [(CoreExpr, BindingDepth -> Bool)]
getUnfoldingsT config = transform $ \ c i ->
    case lookupHermitBinding i c of
      Nothing -> do requireAllBinders config
                    let uncaptured = (<= 0) -- i.e. is global
                    -- This check is necessary because idInfo panics on TyVars. Type variables should
                    -- ALWAYS be in the context (so we should never be in this branch), but at least this
                    -- will give a reasonable error message if something goes wrong, instead of a GHC panic.
                    guardMsg (isId i) "type variable is not in Env (this should not happen)."
                    case unfoldingInfo (idInfo i) of
                      CoreUnfolding { uf_tmpl = uft } -> single (uft, uncaptured)
                      dunf@(DFunUnfolding {})         -> single . (,uncaptured) =<< dFunExpr dunf
                      _                               -> fail $ "cannot find unfolding in Env or IdInfo."
      Just b -> let depth = hbDepth b
                in case hbSite b of
                          CASEBINDER s alt -> let tys             = tyConAppArgs (idType i)
                                                  altExprDepthM   = single . (, (<= depth+1)) =<< alt2Exp tys alt
                                                  scrutExprDepthM = single (s, (< depth))
                                               in case config of
                                                    CaseBinderOnly Scrutinee   -> scrutExprDepthM
                                                    CaseBinderOnly Alternative -> altExprDepthM
                                                    AllBinders                 -> do
                                                        au <- altExprDepthM <+ return []
                                                        su <- scrutExprDepthM
                                                        return $ au ++ su

                          NONREC e         -> do requireAllBinders config
                                                 single (e, (< depth))

                          REC e            -> do requireAllBinders config
                                                 single (e, (<= depth))

                          MUTUALREC e      -> do requireAllBinders config
                                                 single (e, (<= depth+1))

                          TOPLEVEL e       -> do requireAllBinders config
                                                 single (e, (<= depth)) -- Depth should always be 0 for top-level bindings.
                                                                        -- Any inlined variables should only refer to top-level bindings or global things, else they've been captured.

                          _                -> fail "variable is not bound to an expression."
  where
    single = return . (:[])
    requireAllBinders :: Monad m => InlineConfig -> m ()
    requireAllBinders AllBinders         = return ()
    requireAllBinders (CaseBinderOnly _) = fail "not a case binder."

-- | Convert lhs of case alternative to a constructor application expression,
--   failing in the case of the DEFAULT alternative.
--   Accepts a list of types to apply to the constructor before the value args.
--
-- > data T a b = C a b Int
--
-- Pseudocode:
--
-- > alt2Exp (...) [a,b] (C, [x,y,z]) ==> C a b (x::a) (y::b) (z::Int)
--
alt2Exp :: Monad m => [Type] -> (AltCon,[Var]) -> m CoreExpr
alt2Exp _   (DEFAULT   , _ ) = fail "DEFAULT alternative cannot be converted to an expression."
alt2Exp _   (LitAlt l  , _ ) = return $ Lit l
alt2Exp tys (DataAlt dc, vs) = return $ mkDataConApp tys dc vs

-- | Get list of possible inline targets. Used by shell for completion.
inlineTargetsT :: ( ExtendPath c Crumb, ReadPath c Crumb, AddBindings c
                  , HasEmptyContext c, LemmaContext c, ReadBindings c, MonadCatch m )
               => Transform c m LCore [String]
inlineTargetsT = collectT $ promoteT $ whenM (testM inlineR) (varT $ arr unqualifiedName)

-- | Build a CoreExpr for a DFunUnfolding
dFunExpr :: Monad m => Unfolding -> m CoreExpr
dFunExpr dunf@(DFunUnfolding {}) = return $ mkCoreLams (df_bndrs dunf) $ mkCoreConApps (df_con dunf) (df_args dunf)
dFunExpr _ = fail "dFunExpr: not a DFunUnfolding"

------------------------------------------------------------------------
