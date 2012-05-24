{-# LANGUAGE KindSignatures, GADTs #-}

module Language.HERMIT.Interp
        ( Interp(..)
        , interpExprH
        ) where

import Data.Dynamic
import Control.Monad (liftM2)
import Language.HERMIT.External
import Language.HERMIT.HermitKure
import Language.HERMIT.HermitExpr
import Data.List
import Data.Char
import qualified Language.Haskell.TH as TH

import qualified Data.Map as M

interpExprH :: M.Map String [Dynamic] -> [Interp a] -> ExprH -> Either String a
interpExprH env interps expr =
          either Left (\ dyns -> runInterp dyns (map (fmap Right) interps) (Left $ "no type match"))
        $ interpExpr env expr

runInterp :: [Dynamic] -> [Interp b] -> b -> b
runInterp dyns interps bad = head $
             [f a
             | Interp f <- interps
             , Just a <- map fromDynamic dyns
             ] ++ [ bad ]

data Interp :: * -> * where
   Interp :: Typeable a => (a -> b) -> Interp b

instance Functor Interp where
   fmap f (Interp g) = Interp (f . g)


interpExpr :: M.Map String [Dynamic] -> ExprH -> Either String [Dynamic]
interpExpr = interpExpr' False

interpExpr' :: Bool -> M.Map String [Dynamic] -> ExprH -> Either String [Dynamic]
interpExpr' _ env (SrcName str) = return [ toDyn $ NameBox $ TH.mkName str ]
interpExpr' rhs env (CmdName str)
  | all isDigit str                     = return [ toDyn $ IntBox $ read str ]
  | Just dyn <- M.lookup str env        = if rhs
                                          then return (toDyn (StringBox str) : dyn)
                                          else return dyn
  -- not a command, try as a string arg... worst case: dynApply fails with "bad type of expression"
  -- best case: 'help ls' works instead of 'help "ls"'. this is likewise done in then clause above
  | rhs                                 = return [toDyn $ StringBox str]
  | otherwise                           = Left $ "Unrecognised command: " ++ show str
interpExpr' rhs env (StrName str)           = if rhs
                                          then return [ toDyn $ StringBox str ]
                                          else return []
interpExpr' _ env (AppH e1 e2)              = dynAppMsg (interpExpr' False env e1) (interpExpr' True env e2)

dynAppMsg :: Either String [Dynamic] -> Either String [Dynamic] -> Either String [Dynamic]
dynAppMsg f x = liftM2 dynApply' f x >>= return
   where
           dynApply' :: [Dynamic] -> [Dynamic] -> [Dynamic]
           dynApply' fs xs = [ r | f <- fs, x <- xs, Just r <- return (dynApply f x)]

