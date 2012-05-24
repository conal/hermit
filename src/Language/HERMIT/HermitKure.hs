{-# LANGUAGE MultiParamTypeClasses, TypeFamilies, FlexibleInstances, FlexibleContexts, TupleSections #-}

module Language.HERMIT.HermitKure
       (
         TranslateH
       , RewriteH
       , LensH
       , Core(..), CoreDef(..)
       -- | Congruence combinators
       --   IMPORTANT: the @T@ versions only succeed if ALL child 'Translate's succeed,
       --   whereas the @R@ versions succeed if ANY child 'Translate' succeeds.
       , modGutsT, modGutsR
       , consBindT, consBindR
       , nonRecT, nonRecR
       , recT, recR
       , defT, defR
       , altT, altR
       , varT
       , litT
       , appT, appR
       , lamT, lamR
       , letT, letR
       , caseT, caseR
       , castT, castR
       , tickT, tickR
       , typeT
       , coercionT
       , letNonRecT, letNonRecR
       , letRecT, letRecR
       , recDefT, recDefR
       , letRecDefT, letRecDefR
       -- Useful Translations
       , pathT
       )
where

import GhcPlugins hiding (empty)

import Language.KURE
import Language.KURE.Injection
import Language.KURE.Utilities

import Language.HERMIT.HermitEnv
import Language.HERMIT.HermitMonad

import Control.Applicative
import Control.Monad (guard)

import Data.Monoid

---------------------------------------------------------------------

type TranslateH a b = Translate HermitEnv HermitM a b
type RewriteH a = Rewrite HermitEnv HermitM a
type LensH a b = Lens HermitEnv HermitM a b

---------------------------------------------------------------------

-- | NOTE: 'Type' is not included in the generic datatype.
--   However, we could have included it and provided the facility for descending into types.
--   We have not done so because
--     (a) we do not need that functionality, and
--     (b) the types are complicated and we're not sure that we understand them.

-- | In GHC Core, recursive definitions are encoded as (Id, CoreExpr) pairs.
--   Here we use an isomorphic data type.
data CoreDef = Def Id CoreExpr

defToRecBind :: [CoreDef] -> CoreBind
defToRecBind = Rec . map (\ (Def v e) -> (v,e))

data Core = ModGutsCore  ModGuts
          | ProgramCore  CoreProgram
          | BindCore     CoreBind
          | DefCore      CoreDef
          | ExprCore     CoreExpr
          | AltCore      CoreAlt

---------------------------------------------------------------------

instance Term Core where
  type Generic Core = Core

  numChildren (ModGutsCore x) = numChildren x
  numChildren (ProgramCore x) = numChildren x
  numChildren (BindCore x)    = numChildren x
  numChildren (DefCore x)     = numChildren x
  numChildren (ExprCore x)    = numChildren x
  numChildren (AltCore x)     = numChildren x

-- Defining Walker instances for the Generic type 'Core' is almost entirely automated by KURE.
-- Unfortunately, you still need to pattern match on the 'Core' data type.

instance Walker HermitEnv HermitM Core where
  childL n = translate $ \ c core -> case core of
          ModGutsCore x -> childLgeneric n c x
          ProgramCore x -> childLgeneric n c x
          BindCore x    -> childLgeneric n c x
          DefCore x     -> childLgeneric n c x
          ExprCore x    -> childLgeneric n c x
          AltCore x     -> childLgeneric n c x

  allT t = translate $ \ c core -> case core of
          ModGutsCore x -> allTgeneric t c x
          ProgramCore x -> allTgeneric t c x
          BindCore x    -> allTgeneric t c x
          DefCore x     -> allTgeneric t c x
          ExprCore x    -> allTgeneric t c x
          AltCore x     -> allTgeneric t c x

  allR r = rewrite $ \ c core -> case core of
          ModGutsCore x -> allRgeneric r c x
          ProgramCore x -> allRgeneric r c x
          BindCore x    -> allRgeneric r c x
          DefCore x     -> allRgeneric r c x
          ExprCore x    -> allRgeneric r c x
          AltCore x     -> allRgeneric r c x

  anyR r = rewrite $ \ c core -> case core of
          ModGutsCore x -> anyRgeneric r c x
          ProgramCore x -> anyRgeneric r c x
          BindCore x    -> anyRgeneric r c x
          DefCore x     -> anyRgeneric r c x
          ExprCore x    -> anyRgeneric r c x
          AltCore x     -> anyRgeneric r c x

---------------------------------------------------------------------

instance Injection ModGuts Core where
  inject                     = ModGutsCore
  retract (ModGutsCore guts) = Just guts
  retract _                  = Nothing

instance Term ModGuts where
  type Generic ModGuts = Core

  numChildren _ = 1

instance Walker HermitEnv HermitM ModGuts where
  childL 0 = modGutsT exposeT (childL1of2 $ \ modguts bds -> modguts {mg_binds = bds})
  childL n = missingChildL n

-- slightly different to the other; passes in *all* of the original
modGutsT :: TranslateH CoreProgram a -> (ModGuts -> a -> b) -> TranslateH ModGuts b
modGutsT t f = translate $ \ c modGuts -> f modGuts <$> apply t (c @@ 0) (mg_binds modGuts)

modGutsR :: RewriteH CoreProgram -> RewriteH ModGuts
modGutsR r = modGutsT r (\ modguts bds -> modguts {mg_binds = bds})

---------------------------------------------------------------------

instance Injection CoreProgram Core where
  inject                    = ProgramCore
  retract (ProgramCore bds) = Just bds
  retract _                 = Nothing

instance Term CoreProgram where
  type Generic CoreProgram = Core

  -- we consider only the head and tail to be interesting children
  numChildren bds = min 2 (length bds)

instance Walker HermitEnv HermitM CoreProgram where
  childL 0 = consBindT exposeT idR (childL0of2 (:))
  childL 1 = consBindT idR exposeT (childL1of2 (:))
  childL n = missingChildL n

consBindT' :: TranslateH CoreBind a1 -> TranslateH [CoreBind] a2 -> (HermitM a1 -> HermitM a2 -> HermitM b) -> TranslateH [CoreBind] b
consBindT' t1 t2 f = translate $ \ c e -> case e of
        bd:bds -> f (apply t1 (c @@ 0) bd) (apply t2 (addHermitBinding bd c @@ 1) bds)
        _      -> fail "no match for consBind"

consBindT :: TranslateH CoreBind a1 -> TranslateH [CoreBind] a2 -> (a1 -> a2 -> b) -> TranslateH [CoreBind] b
consBindT t1 t2 f = consBindT' t1 t2 (liftA2 f)

consBindR :: RewriteH CoreBind -> RewriteH [CoreBind] -> RewriteH [CoreBind]
consBindR r1 r2 = consBindT' (attemptR r1) (attemptR r2) (attemptAny2 (:))

---------------------------------------------------------------------

instance Injection CoreBind Core where
  inject                  = BindCore
  retract (BindCore bnd)  = Just bnd
  retract _               = Nothing

instance Term CoreBind where
  type Generic CoreBind = Core

  numChildren (NonRec _ _) = 1
  numChildren (Rec defs)   = length defs

instance Walker HermitEnv HermitM CoreBind where
  childL n = (case n of
                 0 -> nonrec <+ rec
                 _ -> rec
             ) <+ missingChildL n
    where
      nonrec = nonRecT exposeT (childL1of2 NonRec)
      rec    = do sz <- liftT numChildren
                  guard (n >= 0 && n < sz)
                  recT (const exposeT) (childLMofN n defToRecBind)

  allT t = nonRecT (extractT t) (\ _ -> id)
        <+ recT (\ _ -> extractT t) mconcat

  anyR r = nonRecR (extractR r)
        <+ recR (\ _ -> extractR r)

  allR r = nonRecT (extractR r) NonRec
        <+ recT (\ _ -> extractR r) defToRecBind

nonRecT :: TranslateH CoreExpr a -> (Id -> a -> b) -> TranslateH CoreBind b
nonRecT t f = translate $ \ c e -> case e of
                                     NonRec v e' -> f v <$> apply t (c @@ 0) e'
                                     _           -> fail "not NonRec constructor"

nonRecR :: RewriteH CoreExpr -> RewriteH CoreBind
nonRecR r = nonRecT r NonRec

recT' :: (Int -> TranslateH CoreDef a) -> ([HermitM a] -> HermitM b) -> TranslateH CoreBind b
recT' t f = translate $ \ c e -> case e of
         Rec bds -> -- Notice how we add the scoping bindings here *before* decending into each individual definition.
                    let c' = addHermitBinding (Rec bds) c
                     in f [ apply (t n) (c' @@ n) (Def v e') -- here we convert from (Id,CoreExpr) to CoreDef
                          | ((v,e'),n) <- zip bds [0..]
                          ]
         _       -> fail "not Rec constructor"

recT :: (Int -> TranslateH CoreDef a) -> ([a] -> b) -> TranslateH CoreBind b
recT ts f = recT' ts (fmap f . sequence)

recR :: (Int -> RewriteH CoreDef) -> RewriteH CoreBind
recR rs = recT' (attemptR . rs) (attemptAnyN defToRecBind)

---------------------------------------------------------------------

instance Injection CoreDef Core where
  inject                = DefCore
  retract (DefCore def) = Just def
  retract _             = Nothing

instance Term CoreDef where
  type Generic CoreDef = Core

  numChildren _ = 1

instance Walker HermitEnv HermitM CoreDef where
  childL 0 = defT exposeT (childL1of2 Def)
  childL n = missingChildL n

defT :: TranslateH CoreExpr a -> (Id -> a -> b) -> TranslateH CoreDef b
defT t f = translate $ \ c (Def v e) -> f v <$> apply t (c @@ 0) e

defR :: RewriteH CoreExpr -> RewriteH CoreDef
defR r = defT r Def

---------------------------------------------------------------------

instance Injection CoreAlt Core where
  inject                 = AltCore
  retract (AltCore expr) = Just expr
  retract _              = Nothing

instance Term CoreAlt where
  type Generic CoreAlt = Core

  numChildren _ = 1

instance Walker HermitEnv HermitM CoreAlt where
  childL 0 = altT exposeT (childL2of3 (,,))
  childL n = missingChildL n

altT :: TranslateH CoreExpr a -> (AltCon -> [Id] -> a -> b) -> TranslateH CoreAlt b
altT t f = translate $ \ c (con,bs,e) -> f con bs <$> apply t (foldr addHermitEnvLambdaBinding c bs @@ 0) e

altR :: RewriteH CoreExpr -> RewriteH CoreAlt
altR r = altT r (,,)

---------------------------------------------------------------------

instance Injection CoreExpr Core where
  inject                  = ExprCore
  retract (ExprCore expr) = Just expr
  retract _               = Nothing

instance Term CoreExpr where
  type Generic CoreExpr = Core

  numChildren (Var _)         = 0
  numChildren (Lit _)         = 0
  numChildren (App _ _)       = 2
  numChildren (Lam _ _)       = 1
  numChildren (Let _ _)       = 2
  numChildren (Case _ _ _ es) = 1 + length es
  numChildren (Cast _ _)      = 1
  numChildren (Tick _ _)      = 1
  numChildren (Type _)        = 0
  numChildren (Coercion _)    = 0

instance Walker HermitEnv HermitM CoreExpr where

  childL n = (case n of
                 0  ->    appT  exposeT idR         (childL0of2 App)
                       <+ lamT  exposeT             (childL1of2 Lam)
                       <+ letT  exposeT idR         (childL0of2 Let)
                       <+ caseT exposeT (const idR) (childL0of4 Case)
                       <+ castT exposeT             (childL0of2 Cast)
                       <+ tickT exposeT             (childL1of2 Tick)

                 1  ->    appT idR exposeT (childL1of2 App)
                       <+ letT idR exposeT (childL1of2 Let)
                       <+ caseChooseL

                 _  ->    caseChooseL
             )
             <+ missingChildL n
     where
       -- Note we use index (n-1) because 0 refers to the expression being scrutinised.
       caseChooseL :: LensH CoreExpr Core
       caseChooseL = do sz <- liftT numChildren
                        guard (n > 0 && n < sz)
                        caseT idR (const exposeT) (\ e v t -> childLMofN (n-1) (Case e v t))

  allT t = varT (\ _ -> mempty)
        <+ litT (\ _ -> mempty)
        <+ appT (extractT t) (extractT t) mappend
        <+ lamT (extractT t) (\ _ -> id)
        <+ letT (extractT t) (extractT t) mappend
        <+ caseT (extractT t) (\ _ -> extractT t) (\ r _ _ rs -> mconcat (r:rs))
        <+ castT (extractT t) const
        <+ tickT (extractT t) (\ _ -> id)
        <+ typeT (\ _ -> mempty)
        <+ coercionT (\ _ -> mempty)
        <+ fail "allT failed for all Expr constructors"

  anyR r = appR (extractR r) (extractR r)
        <+ lamR (extractR r)
        <+ letR (extractR r) (extractR r)
        <+ caseR (extractR r) (\ _ -> extractR r)
        <+ castR (extractR r)
        <+ tickR (extractR r)
        <+ fail "anyR failed for all Expr constructors"

  allR r = varT Var
        <+ litT Lit
        <+ appT (extractR r) (extractR r) App
        <+ lamT (extractR r) Lam
        <+ letT (extractR r) (extractR r) Let
        <+ caseT (extractR r) (\ _ -> extractR r) Case
        <+ castT (extractR r) Cast
        <+ tickT (extractR r) Tick
        <+ typeT Type
        <+ coercionT Coercion
        <+ fail "allR failed for all Expr constructors"

---------------------------------------------------------------------

-- Expr
varT :: (Id -> b) -> TranslateH CoreExpr b
varT f = liftMT $ \ e -> case e of
        Var n -> pure (f n)
        _     -> fail "no match for Var"

litT :: (Literal -> b) -> TranslateH CoreExpr b
litT f = liftMT $ \ e -> case e of
        Lit i -> pure (f i)
        _     -> fail "no match for Lit"


appT' :: TranslateH CoreExpr a1 -> TranslateH CoreExpr a2 -> (HermitM a1 -> HermitM a2 -> HermitM b) -> TranslateH CoreExpr b
appT' t1 t2 f = translate $ \ c e -> case e of
         App e1 e2 -> f (apply t1 (c @@ 0) e1) (apply t2 (c @@ 1) e2)
         _         -> fail "no match for App"

appT :: TranslateH CoreExpr a1 -> TranslateH CoreExpr a2 -> (a1 -> a2 -> b) -> TranslateH CoreExpr b
appT t1 t2 = appT' t1 t2 . liftA2

appR :: RewriteH CoreExpr -> RewriteH CoreExpr -> RewriteH CoreExpr
appR r1 r2 = appT' (attemptR r1) (attemptR r2) (attemptAny2 App)


lamT :: TranslateH CoreExpr a -> (Id -> a -> b) -> TranslateH CoreExpr b
lamT t f = translate $ \ c e -> case e of
        Lam b e1 -> f b <$> apply t (addHermitEnvLambdaBinding b c @@ 0) e1
        _        -> fail "no match for Lam"

lamR :: RewriteH CoreExpr -> RewriteH CoreExpr
lamR r = lamT r Lam


letT' :: TranslateH CoreBind a1 -> TranslateH CoreExpr a2 -> (HermitM a1 -> HermitM a2 -> HermitM b) -> TranslateH CoreExpr b
letT' t1 t2 f = translate $ \ c e -> case e of
        Let bds e1 -> f (apply t1 (c @@ 0) bds) (apply t2 (addHermitBinding bds c @@ 1) e1)
                -- use *original* env, because the bindings are self-binding,
                -- if they are recursive. See allR (Rec ...) for details.
        _         -> fail "no match for Let"

letT :: TranslateH CoreBind a1 -> TranslateH CoreExpr a2 -> (a1 -> a2 -> b) -> TranslateH CoreExpr b
letT t1 t2 = letT' t1 t2 . liftA2

letR :: RewriteH CoreBind -> RewriteH CoreExpr -> RewriteH CoreExpr
letR r1 r2 = letT' (attemptR r1) (attemptR r2) (attemptAny2 Let)


caseT' :: TranslateH CoreExpr a1
      -> (Int -> TranslateH CoreAlt a2)          -- Int argument *starts* at 1.
      -> (Id -> Type -> HermitM a1 -> [HermitM a2] -> HermitM b)
      -> TranslateH CoreExpr b
caseT' t ts f = translate $ \ c e -> case e of
         Case e1 b ty alts -> f b ty (apply t (c @@ 0) e1) $ let c' = addHermitBinding (NonRec b e1) c
                                                                 in [ apply (ts n) (c' @@ n) alt
                                                                    | (alt,n) <- zip alts [1..]
                                                                    ]
         _ -> fail "no match for Case"

caseT :: TranslateH CoreExpr a1
      -> (Int -> TranslateH CoreAlt a2)          -- Int argument *starts* at 1.
      -> (a1 -> Id -> Type -> [a2] -> b)
      -> TranslateH CoreExpr b
caseT t ts f = caseT' t ts (\ b ty me malts -> f <$> me <*> pure b <*> pure ty <*> sequence malts)

caseR :: RewriteH CoreExpr
      -> (Int -> RewriteH CoreAlt)          -- Int argument *starts* at 1.
      -> RewriteH CoreExpr
caseR r rs = caseT' (attemptR r) (attemptR . rs) (\ b ty -> attemptAny1N (\ e -> Case e b ty))


castT :: TranslateH CoreExpr a -> (a -> Coercion -> b) -> TranslateH CoreExpr b
castT t f = translate $ \ c e -> case e of
        Cast e1 cast -> f <$> apply t (c @@ 0) e1 <*> pure cast
        _            -> fail "no match for Cast"

castR :: RewriteH CoreExpr -> RewriteH CoreExpr
castR r = castT r Cast


tickT :: TranslateH CoreExpr a -> (Tickish Id -> a -> b) -> TranslateH CoreExpr b
tickT t f = translate $ \ c e -> case e of
        Tick tk e1 -> f tk <$> apply t (c @@ 0) e1
        _          -> fail "no match for Tick"

tickR :: RewriteH CoreExpr -> RewriteH CoreExpr
tickR r = tickT r Tick

typeT :: (Type -> b) -> TranslateH CoreExpr b
typeT f = liftMT $ \ e -> case e of
                            Type i -> pure (f i)
                            _      -> fail "no match for Type"

coercionT :: (Coercion -> b) -> TranslateH CoreExpr b
coercionT f = liftMT $ \ e -> case e of
                                Coercion i -> pure (f i)
                                _          -> fail "no match for Coercion"

---------------------------------------------------------------------

-- Some additional congruence combinators to export.

letNonRecT :: TranslateH CoreExpr a1 -> TranslateH CoreExpr a2 -> (Id -> a1 -> a2 -> b) -> TranslateH CoreExpr b
letNonRecT t1 t2 f = letT (nonRecT t1 (,)) t2 (uncurry f)

letNonRecR :: RewriteH CoreExpr -> RewriteH CoreExpr -> RewriteH CoreExpr
letNonRecR r1 r2 = letR (nonRecR r1) r2

letRecT :: (Int -> TranslateH CoreDef a1) -> TranslateH CoreExpr a2 -> ([a1] -> a2 -> b) -> TranslateH CoreExpr b
letRecT ts t f = letT (recT ts id) t f

letRecR :: (Int -> RewriteH CoreDef) -> RewriteH CoreExpr -> RewriteH CoreExpr
letRecR rs r = letR (recR rs) r

recDefT :: (Int -> TranslateH CoreExpr a1) -> ([(Id,a1)] -> b) -> TranslateH CoreBind b
recDefT ts f = recT (\ n -> defT (ts n) (,)) f

recDefR :: (Int -> RewriteH CoreExpr) -> RewriteH CoreBind
recDefR rs = recR (\ n -> defR (rs n))

letRecDefT :: (Int -> TranslateH CoreExpr a1) -> TranslateH CoreExpr a2 -> ([(Id,a1)] -> a2 -> b) -> TranslateH CoreExpr b
letRecDefT ts t f = letRecT (\ n -> defT (ts n) (,)) t f

letRecDefR :: (Int -> RewriteH CoreExpr) -> RewriteH CoreExpr -> RewriteH CoreExpr
letRecDefR rs r = letRecR (\ n -> defR (rs n)) r

---------------------------------------------------------------------

-- Useful Translations

-- | 'pathT' finds the current path.
pathT :: TranslateH a ContextPath
pathT = fmap hermitBindingPath contextT

---------------------------------------------------------------------