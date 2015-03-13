{-# LANGUAGE CPP #-}
module Main where

import Control.Monad

import HERMIT.Driver
#ifdef mingw32_HOST_OS
import HERMIT.Win32.IO (hPutStrLn)
#endif

import System.Directory
import System.Exit
import System.FilePath as F
#ifdef mingw32_HOST_OS
import System.IO (Handle, hGetContents, hClose, openFile, IOMode(WriteMode))
#else
import System.IO (Handle, hGetContents, hPutStrLn, hClose, openFile, IOMode(WriteMode))
#endif
import System.IO.Temp (withTempFile)
import System.Process hiding (runCommand)

type Test = (FilePath, FilePath, FilePath, [String])

-- subdirectory names
golden, dump :: String
golden = "golden"
dump = "dump"

tests :: [Test]
tests = [ ("concatVanishes", "Flatten.hs", "Flatten.hss", [])
        , ("concatVanishes", "QSort.hs"  , "QSort.hss"  , [])
        , ("concatVanishes", "Rev.hs"    , "Rev.hss"    , [])
        , ("evaluation"    , "Eval.hs"   , "Eval.hss"   , [])
        , ("factorial"     , "Fac.hs"    , "Fac.hss"    , [])
        -- broken due to Core Parser: , ("fib-stream"    , "Fib.hs"    , "Fib.hss"    )
        , ("fib-tuple"     , "Fib.hs"    , "Fib.hss"    , [])
        , ("flatten"       , "Flatten.hs", "Flatten.hec", ["-safe-mode"])
        -- for some reason loops in testsuite but not normally: , ("hanoi"         , "Hanoi.hs"  , "Hanoi.hss"  )
        , ("last"          , "Last.hs"   , "Last.hss"   , [])
        , ("last"          , "Last.hs"   , "NewLast.hss", [])
        -- broken due to Core Parser: , ("map"           , "Map.hs"    , "Map.hss"    )
        , ("mean"          , "Mean.hs"   , "Mean.hss"   , [])
        , ("nub"           , "Nub.hs"    , "Nub.hss"    , [])
        , ("qsort"         , "QSort.hs"  , "QSort.hss"  , [])
        , ("reverse"       , "Reverse.hs", "Reverse.hss", [])
        , ("new_reverse"   , "Reverse.hs", "Reverse.hec", ["-safe-mode"])
        ]

fixName :: FilePath -> FilePath
fixName = map (\c -> if c == '.' then '_' else c)

mkTestScript :: Handle -> FilePath -> IO ()
mkTestScript h hss = do
    hPutStrLn h
        $ unlines [ "set-auto-corelint True"
                  , "set-pp-type Show"
                  , "set-fail-hard True"
                  , "load-and-run \"" ++ hss ++ "\""
                  , "top ; prog"
                  , "display" -- all the bindings
                  , "show-lemmas"
                  , "resume" ]
    hClose h

main :: IO ()
main = do
    pwd <- getCurrentDirectory

    forM_ tests $ \ (dir, hs, hss, extraFlags) -> do
        withTempFile pwd "Test.hss" $ \ fp h -> do
            putStr $ "Running " ++ dir </> hs ++ " - "

            let fixed = fixName (concat [dir, "_", hs, "_", hss])
                gfile = pwd </> golden </> fixed <.> "ref"
                desired = pwd </> dump </> fixed <.> "dump"
                pathp = ".." </> "examples" </> dir

            b <- doesFileExist gfile
            dfile <- if not b
                     then do putStrLn $ "Reference file (" ++ gfile ++ ") does not exist. Creating!"
                             return gfile
                     else return desired

            mkTestScript h hss

            let cmd = unwords $ [ "(", "cd", pathp, ";", "ghc" , hs ] ++ ghcFlags ++
                                [ "-fplugin=HERMIT"
                                , "-fplugin-opt=HERMIT:Main:" ++ fp -- made by mkTestScript
                                , "-v0"] ++ [ "-fplugin-opt=HERMIT:Main:" ++ f | f <- extraFlags] ++ [ ")" ]
                diff = unwords [ "diff", "-b", "-U 5", gfile, dfile ]

            -- Adding a &> dfile redirect in cmd causes the call to GHC to not block
            -- until the compiler is finished (on Linux, not OSX). So we do the Haskell
            -- equivalent here by opening our own file.
            fh <- openFile dfile WriteMode
            -- putStrLn cmd
            (_,_,_,rHermit) <- createProcess $ (shell cmd) { std_out = UseHandle fh, std_err = UseHandle fh }
            exHermit <- waitForProcess rHermit
            hClose fh

            case exHermit of
                ExitFailure i -> putStrLn $ "HERMIT failed with code: " ++ show i
                ExitSuccess   -> return ()

            -- putStrLn diff
            (_,mbStdoutH,_,rDiff) <- createProcess $ (shell diff) { std_out = CreatePipe }
            exDiff <- waitForProcess rDiff
            case exDiff of
                ExitFailure i | i > 1 -> putStrLn $ "diff failed with code: " ++ show i
                _ -> maybe (putStrLn "error: no stdout!")
                           (\hDiff -> do output <- hGetContents hDiff
                                         if null output
                                         then putStrLn "passed."
                                         else do putStrLn "failed:"
                                                 putStrLn output)
                           mbStdoutH
