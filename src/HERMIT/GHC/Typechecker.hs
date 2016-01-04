{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}

module HERMIT.GHC.Typechecker
    (
      initTcFromModGuts
    , mk_type_env
    , tcLookupGlobal
    ) where

import Annotations (emptyAnnEnv)
import HsSyn
import RdrName
import TcRnMonad
import CoreSyn
import ErrUtils
import VarEnv
import Name
import NameEnv
import NameSet
import SrcLoc
import HscTypes
import Outputable
import Data.IORef ( newIORef, readIORef )

import TcEnv ( tcLookupGlobal )
#if __GLASGOW_HASKELL__ < 710
import TcType   ( noUntouchables )
#else
import DynFlags ( getSigOf )
import Module   ( mkModuleSet, moduleName )
import TcType   ( topTcLevel )
#endif

import FastString
import Bag

import qualified Data.Set as Set
import qualified Data.Map as Map

import Prelude hiding (mod)
import VarSet (emptyVarSet)

-- Note: the contents of this module should eventually be folded into GHC proper.

-- | Re-Setup the typechecking environment from a ModGuts
initTcFromModGuts
    :: HscEnv
    -> ModGuts
    -> HscSource
    -> Bool          -- True <=> retain renamed syntax trees
    -> TcM r
    -> IO (Messages, Maybe r) -- Nothing => error thrown by the thing inside
                              -- (error messages should have been printed already)
initTcFromModGuts hsc_env guts hsc_src keep_rn_syntax do_this
 = do { let { type_env = mk_type_env guts } ;
        errs_var     <- newIORef (emptyBag, emptyBag) ;
        tvs_var      <- newIORef emptyVarSet ;
        keep_var     <- newIORef emptyNameSet ;
        used_rdr_var <- newIORef Set.empty ;
        th_var       <- newIORef False ;
        th_splice_var<- newIORef False ;
#if __GLASGOW_HASKELL__ <= 710 
        infer_var    <- newIORef True ;
#else
        infer_var    <- newIORef (True, emptyBag) ;
#endif
        lie_var      <- newIORef emptyWC ;
        dfun_n_var   <- newIORef (mk_dfun_n guts) ;
        type_env_var <- newIORef type_env ;

        dependent_files_var <- newIORef [] ;
#if __GLASGOW_HASKELL__ >= 710
        static_wc_var       <- newIORef emptyWC ;
#endif

        th_topdecls_var      <- newIORef [] ;
        th_topnames_var      <- newIORef emptyNameSet ;
        th_modfinalizers_var <- newIORef [] ;
        th_state_var         <- newIORef Map.empty ;

        let {
             dflags = hsc_dflags hsc_env ;
             mod = mg_module guts ;

             maybe_rn_syntax :: forall a. a -> Maybe a ;
             maybe_rn_syntax empty_val
                | keep_rn_syntax = Just empty_val
                | otherwise      = Nothing ;

             gbl_env = TcGblEnv {
                -- these first four are CPP'd in GHC itself, but we include them here
                tcg_th_topdecls      = th_topdecls_var,
                tcg_th_topnames      = th_topnames_var,
                tcg_th_modfinalizers = th_modfinalizers_var,
                tcg_th_state         = th_state_var,

                -- queried during tcrnif
                tcg_mod            = mod,
                tcg_src            = hsc_src,
#if __GLASGOW_HASKELL__ >= 710
                tcg_sig_of         = getSigOf dflags (moduleName mod),
                tcg_impl_rdr_env   = Nothing,
#endif
                tcg_rdr_env        = mg_rdr_env guts,
                tcg_default        = Nothing,
                tcg_fix_env        = mg_fix_env guts,
                tcg_field_env      = mk_field_env guts,
                tcg_type_env       = type_env,
                tcg_type_env_var   = type_env_var,
                tcg_inst_env       = mg_inst_env guts,
                tcg_fam_inst_env   = mg_fam_inst_env guts,
                tcg_ann_env        = emptyAnnEnv,
#if __GLASGOW_HASKELL__ <= 710 
                tcg_visible_orphan_mods = mkModuleSet [mod],
#endif
                tcg_dfun_n         = dfun_n_var,

                -- accumulated, not queried, during tcrnif
                tcg_dependent_files = dependent_files_var,
#if __GLASGOW_HASKELL__ >= 710
                tcg_tc_plugins     = [],
                tcg_static_wc      = static_wc_var,
#endif
                tcg_exports        = [],
                tcg_warns          = NoWarnings,
                tcg_anns           = [],
                tcg_tcs            = [],
                tcg_insts          = [],
                tcg_fam_insts      = [],
                tcg_rules          = [],
                tcg_th_used        = th_var,
                tcg_imports        = emptyImportAvails,
                tcg_dus            = emptyDUs,
                tcg_ev_binds       = emptyBag,
                tcg_fords          = [],
                tcg_vects          = [],
                tcg_patsyns        = [],
                tcg_doc_hdr        = Nothing,
                tcg_hpc            = False,
                tcg_main           = Nothing,
                tcg_safeInfer      = infer_var,
                tcg_binds          = emptyLHsBinds,
                tcg_sigs           = emptyNameSet,
                tcg_imp_specs      = [],
                tcg_rn_decls       = maybe_rn_syntax emptyRnGroup,
                tcg_used_rdrnames  = used_rdr_var,
                tcg_rn_imports     = [],
                tcg_rn_exports     = maybe_rn_syntax [],
                tcg_keep           = keep_var,
#if __GLASGOW_HASKELL__ > 710 
                tcg_self_boot  = NoSelfBoot, -- Assume there are no hsboot files
#endif
                tcg_th_splice_used = th_splice_var
             } ;
             lcl_env = TcLclEnv {
                tcl_errs       = errs_var,
#if __GLASGOW_HASKELL__ >= 710 && __GLASGOW_HASKELL_PATCHLEVEL1__ >= 2
                tcl_loc        = realSrcLocSpan $ mkRealSrcLoc (fsLit "Top level") 1 1,
#else
                tcl_loc        = mkGeneralSrcSpan (fsLit "Top level"),
#endif
                tcl_ctxt       = [],
                tcl_rdr        = emptyLocalRdrEnv,
                tcl_th_ctxt    = topStage,
                tcl_th_bndrs   = emptyNameEnv,
                tcl_arrow_ctxt = NoArrowCtxt,
                tcl_env        = emptyNameEnv,
                tcl_bndrs      = [],
                tcl_tidy       = emptyTidyEnv,
                tcl_tyvars     = tvs_var,
                tcl_lie        = lie_var,
#if __GLASGOW_HASKELL__ < 710
                tcl_untch      = noUntouchables
#else
                tcl_tclvl      = topTcLevel
#endif
             } ;
        } ;

        -- OK, here's the business end!
        maybe_res <- initTcRnIf 'a' hsc_env gbl_env lcl_env $
                     do { r <- tryM do_this
                        ; case r of
                          Right res -> return (Just res)
                          Left _    -> return Nothing } ;

        -- Check for unsolved constraints
        lie <- readIORef lie_var ;
        if isEmptyWC lie
           then return ()
#if __GLASGOW_HASKELL__ < 710
           else pprPanic "initTc: unsolved constraints"
                         (pprWantedsWithLocs lie) ;
#else
           else pprPanic "initTc: unsolved constraints" (ppr lie) ;
#endif

        -- Collect any error messages
        msgs <- readIORef errs_var ;

        let { final_res | errorsFound dflags msgs = Nothing
                        | otherwise               = maybe_res } ;

        return (msgs, final_res)
    }

mk_type_env :: ModGuts -> TypeEnv
-- copied from GHC.compileCore
mk_type_env guts = typeEnvFromEntities (bindersOfBinds (mg_binds guts))
                                           (mg_tcs guts)
                                           (mg_fam_insts guts)
mk_field_env :: ModGuts -> RecFieldEnv
-- TODO
mk_field_env _ = RecFields emptyNameEnv emptyNameSet

mk_dfun_n :: ModGuts -> OccSet
-- TODO
mk_dfun_n _ = emptyOccSet
