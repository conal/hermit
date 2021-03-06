module Main where

import Criterion.Main
import HList
import Data.Function (fix)

{-# INLINE repR #-}
repR :: ([a] -> [a]) -> ([a] -> H a)
repR f = repH . f

{-# INLINE absR #-}
absR :: ([a] -> H a) -> ([a] -> [a])
absR g = absH . g

{-# RULES "ww" forall body. fix body = absR (fix (repR . body . absR)) #-}
-- {-# RULES "inline-fix" forall f . fix f = let w = f w in w #-}

-- rev :: [a] -> [a]
rev []     = []
rev (x:xs) = rev xs ++ [x]

main = defaultMain
       [ bench (show n) $ whnf (\n -> sum $ rev [1..n]) n
       | n <- take 8 $ [50,100..]
       ]
