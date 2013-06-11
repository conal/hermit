{-# LANGUAGE BangPatterns, RankNTypes #-}
{-# OPTIONS_GHC -funbox-strict-fields #-}
{-# OPTIONS_GHC -fspec-constr #-}
{-# OPTIONS_GHC -fdicts-cheap #-}

{- OPTIONS_GHC -optlo-globalopt #-}
{- OPTIONS_GHC -optlo-loop-unswitch #-}
{- OPTIONS_GHC -optlo-mem2reg #-}
{- OPTIONS_GHC -optlo-prune-eh #-}

{-# OPTIONS_GHC -optlo-O3 -optlc-O3 #-} -- this is fast...

module Main where

import Data.Vector as V
import GHC.Enum as E
import Data.Vector.Fusion.Stream as VS
import Data.Vector.Fusion.Stream.Monadic as M
import Data.Vector.Fusion.Stream.Size as VS

import Criterion.Main as C

import HERMIT.Optimization.StreamFusion.Vector

c :: Monad m => (a -> m (M.Stream m b)) -> M.Stream m a -> M.Stream m b
c = M.concatMapM

f :: Monad m => (a -> m s) -> (s -> m (M.Step s b)) -> Size -> M.Stream m a -> M.Stream m b
f = M.flatten

r :: Monad m => a -> m a
r = return

concatTestV :: Int -> Int
concatTestV z = V.sum $ V.concatMap (\(!x) -> V.enumFromN 1 x) $ V.enumFromN 1 z
{-# NOINLINE concatTestV #-}

concatTestS :: Int -> Int
concatTestS z = VS.foldl' (+) 0 $ VS.concatMap (\(!x) -> VS.enumFromStepN 1 1 x) $ VS.enumFromStepN 1 1 z
{-# NOINLINE concatTestS #-}

-- | And again, this time we flatten the resulting stream. If this is fast
-- (enough), we can start the fusion process on ADP.
--
-- NOTE This does actually reduce to the desired tight loop.

flattenTest :: Int -> Int
flattenTest !z = VS.foldl' (+) 0 $ VS.flatten mk step Unknown $ VS.enumFromStepN 1 1 z
  where
    mk !x = (1,x)
    {-# INLINE mk #-}
    step (!i,!max)
      | i<=max = VS.Yield i (i+1,max)
      | otherwise = VS.Done
    {-# INLINE step #-}
{-# NOINLINE flattenTest #-}

main = do
  print $ concatTestV 1000
  print $ concatTestS 1000
  print $ flattenTest 1000
  defaultMain
    [ bgroup "concat tests / 100"
      [ bench "concatTestV" $ whnf concatTestV 100
      , bench "concatTestS" $ whnf concatTestS 100
      , bench "flattenTest" $ whnf flattenTest 100
      ]
    , bgroup "concat tests / 1000"
      [ bench "concatTestV" $ whnf concatTestV 1000
      , bench "concatTestS" $ whnf concatTestS 1000
      , bench "flattenTest" $ whnf flattenTest 1000
      ]
    ]

