{-# LANGUAGE TypeFamilies, FlexibleInstances #-}

module Language.HERMIT.Inline where

import GhcPlugins
import qualified Data.Map as Map

import Language.HERMIT.Types
import Language.HERMIT.HermitEnv as Env

-- The implementation of inline, an important transformation.
-- This *only* works on a Var of the given name. It can trivially
-- be prompted to more general cases.

inline :: Id -> Rewrite CoreExpr
inline n = rewrite $ \ c e -> case e of
        Var n0 | n == n0 -> -- A candiate for inlining
                case Env.lookupHermitBinding n0 c of
                  Nothing -> fail $ "inline failed, can not find " ++ show n0 ++ "  in Env"
                  Just (LAM {})
                          -> fail $ "inline failed, found lambda-bound value or type"
                  Just (BIND depth _ e)
                        -- need to check for clashes, based on the depth
                        -- for now, just accept, and proceeded
                          -> return e
        _ -> fail $ "inline of " ++ show n ++ " failed"
