-- | Output the raw Expr constructors. Helpful for writing pattern matching rewrites.
module HERMIT.PrettyPrinter.AST
  ( -- * HERMIT's AST Pretty-Printer for GHC Core
    externals
  , pretty
  , ppCoreTC
  , ppModGuts
  , ppCoreProg
  , ppCoreBind
  , ppCoreExpr
  , ppCoreAlt
  , ppKindOrType
  , ppCoercion
  , ppForallQuantification
  )
where

import Control.Arrow hiding ((<+>))

import Data.Char (isSpace)
import Data.Default.Class

import HERMIT.Core
import HERMIT.External
import HERMIT.GHC hiding (($$), (<+>), (<>), ($+$), cat, nest, parens, text, empty, hsep)
import HERMIT.Kure

import HERMIT.PrettyPrinter.Common

import Text.PrettyPrint.MarkedHughesPJ as PP

---------------------------------------------------------------------------

coText :: String -> DocH
coText = coercionColor . text

tyText :: String -> DocH
tyText = typeColor . text

---------------------------------------------------------------------------

externals :: [External]
externals = [ external "ast" pretty ["AST pretty printer."] ]

pretty :: PrettyPrinter
pretty = PP { pLCoreTC = promoteT ppCoreTC -- TODO
            , pOptions = def
            , pTag = "ast"
            }

-- | Pretty print a fragment of GHC Core using HERMIT's \"AST\" pretty printer.
--   This displays the tree of constructors using nested indentation.
ppCoreTC :: PrettyH CoreTC
ppCoreTC =
          promoteExprT     ppCoreExpr
       <+ promoteProgT     ppCoreProg
       <+ promoteBindT     ppCoreBind
       <+ promoteDefT      ppCoreDef
       <+ promoteModGutsT  ppModGuts
       <+ promoteAltT      ppCoreAlt
       <+ promoteTypeT     ppKindOrType
       <+ promoteCoercionT ppCoercion

-- Use for any GHC structure, the 'showSDoc' prefix is to remind us
-- that we are eliding infomation here.
ppSDoc :: Outputable a => PrettyH a
ppSDoc =  do dynFlags   <- constT getDynFlags
             hideNotes  <- (po_notes . prettyC_options) ^<< contextT
             arr (toDoc . (if hideNotes then id else ("showSDoc: " ++)) . showPpr dynFlags)
    where toDoc s | any isSpace s = parens (text s)
                  | otherwise     = text s

ppModGuts :: PrettyH ModGuts
ppModGuts =  mg_module ^>> ppSDoc

ppCoreProg :: PrettyH CoreProg
ppCoreProg = progConsT ppCoreBind ppCoreProg ($+$) <+ progNilT empty

ppCoreExpr :: PrettyH CoreExpr
ppCoreExpr = varT (ppVar >>^ \ i -> text "Var" <+> i)
          <+ litT (ppSDoc >>^ \ x -> text "Lit" <+> x)
          <+ appT ppCoreExpr ppCoreExpr (\ a b -> text "App" $$ nest 2 (cat [parens a, parens b]))
          <+ lamT ppVar ppCoreExpr (\ v e -> text "Lam" <+> v $$ nest 2 (parens e))
          <+ letT ppCoreBind ppCoreExpr (\ b e -> text "Let" $$ nest 2 (cat [parens b, parens e]))
          <+ caseT ppCoreExpr ppVar ppKindOrType (const ppCoreAlt) (\s w ty alts ->
                    text "Case" $$ nest 2 (parens s) $$ nest 2 w $$ nest 2 (parens ty) $$ nest 2 (vlist alts))
          <+ castT ppCoreExpr ppCoercion (\ e co -> text "Cast" $$ nest 2 (cat [parens e, parens co]))
          <+ tickT ppSDoc ppCoreExpr (\ tk e  -> text "Tick" $$ nest 2 (tk <+> parens e))
          <+ typeT (ppKindOrType >>^ \ ty -> text "Type" $$ nest 2 (parens ty))
          <+ coercionT (ppCoercion >>^ \ co -> text "Coercion" $$ nest 2 (parens co))

ppCoreBind :: PrettyH CoreBind
ppCoreBind = nonRecT ppVar ppCoreExpr (\ v e -> text "NonRec" <+> v $$ nest 2 (parens e))
          <+ recT (const ppCoreDef) (\ bnds -> text "Rec" $$ nest 2 (vlist bnds))

ppCoreAlt :: PrettyH CoreAlt
ppCoreAlt = altT ppSDoc (\ _ -> ppVar) ppCoreExpr $ \ con vs e -> text "Alt" <+> con <+> hlist vs $$ nest 2 (parens e)

ppCoreDef :: PrettyH CoreDef
ppCoreDef = defT ppVar ppCoreExpr (\ i e -> text "Def" <+> i $$ nest 2 (parens e))

ppKindOrType :: PrettyH Type
ppKindOrType =
          tyVarT (ppVar >>^ \ v -> tyText "TyVarTy" <+> v)
       <+ litTyT (ppSDoc >>^ \ l -> tyText "LitTy" <+> l)
       <+ appTyT ppKindOrType ppKindOrType (\ ty1 ty2 -> tyText "AppTy" $$ nest 2 (cat [parens ty1, parens ty2]))
       <+ funTyT ppKindOrType ppKindOrType (\ ty1 ty2 -> tyText "FunTy" $$ nest 2 (cat [parens ty1, parens ty2]))
       <+ forAllTyT ppVar ppKindOrType (\ v ty -> tyText "ForAllTy" <+> v $$ nest 2 (parens ty))
       <+ tyConAppT ppSDoc (const ppKindOrType) (\ con tys -> tyText "TyConApp" <+> con $$ nest 2 (vlist $ map parens tys))

ppCoercion :: PrettyH Coercion
ppCoercion =  coVarCoT (ppVar >>^ \ v -> coText "CoVarCo" <+> v)
           <+ symCoT (ppCoercion >>^ \ co -> coText "SymCo" $$ nest 2 (parens co))
           <+ appCoT ppCoercion ppCoercion (\ co1 co2 -> coText "AppCo" $$ nest 2 (cat [parens co1, parens co2]))
           <+ forAllCoT ppVar ppCoercion (\ v co -> coText "ForAllCo" <+> v $$ nest 2 (parens co))
           <+ transCoT ppCoercion ppCoercion (\ co1 co2 -> coText "TransCo" $$ nest 2 (cat [parens co1, parens co2]))
           <+ nthCoT (arr $ coText . show) ppCoercion (\ n co -> coText "NthCo" <+> n $$ parens co)
           <+ instCoT ppCoercion ppKindOrType (\ co ty -> coText "InstCo" $$ nest 2 (cat [parens co, parens ty]))
-- TODO: Figure out how to properly pp new branched Axioms and Left/Right Coercions
           <+ reflT ppKindOrType (\ r ty -> coText "Refl" <+> coText (showRole r) $$ nest 2 (parens ty))
           <+ axiomInstCoT ppSDoc ppSDoc (const ppCoercion) (\ ax idx coes -> coText "AxiomInstCo" <+> ax <+> idx $$ nest 2 (vlist $ map parens coes))
           <+ lrCoT ppSDoc ppCoercion (\ lr co -> coText "LRCo" <+> lr $$ nest 2 (parens co))
           <+ tyConAppCoT ppSDoc (const ppCoercion) (\ r con coes -> coText "TyConAppCo" <+> coText (showRole r) <+> con $$ nest 2 (vlist $ map parens coes))
           -- TODO: add UnivCo and SubCo

ppVar :: PrettyH Var
ppVar = readerT $ \ v -> ppSDoc >>^ modCol v
  where
    modCol v | isTyVar v  = typeColor
             | isCoVar v  = coercionColor
             | otherwise  = idColor

-- A bit hacky, currently only used to pretty-print Lemmas.
ppForallQuantification :: PrettyH [Var]
ppForallQuantification =
  do vs <- mapT ppVar
     if null vs
     then return empty
     else return $ keywordText "forall" <+> hsep vs <> keywordText "."

keywordText :: String -> DocH
keywordText = keywordColor . text

---------------------------------------------------------------------------
