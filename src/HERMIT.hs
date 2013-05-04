module HERMIT (plugin) where

import GhcPlugins

import qualified Language.HERMIT.Shell.Command as Dispatch
import Language.HERMIT.Plugin
import System.Console.Haskeline (defaultBehavior)

plugin :: Plugin
plugin = hermitPlugin interactive

interactive :: HermitPass
interactive opts modGuts = Dispatch.commandLine opts defaultBehavior modGuts
