-- |
-- Copyright: (C) 2013 Amgen, Inc.
--
-- This module provides datatype for representing Haskell
-- modules in Raskell.

module H.Module
  ( RModule
  , mkMod
  , prettyGhci
  , prettyModule
  , translate
  ) where

import Control.Applicative
import Control.Monad ( forM, when )
import qualified Data.Vector.Unboxed as U
import Foreign ( peekElemOff )
import H.Value
 
import Text.PrettyPrint ( Doc, ($$), (<+>) )
import qualified Text.PrettyPrint as P

import qualified Language.R.Foreign.Internal as R

-- | Generic structure of the haskell module that is created from R module.
data RModule = RModule
      { modPackage   :: Maybe String
      , modName      :: String
      , modImports   :: [String]
      , modFunctions :: [Doc]
      }

-- | Create default module.
mkMod :: Maybe String -> String -> RModule
mkMod pkg name = RModule pkg name ["H.Value"] []

-- | Pretty print module.
prettyModule :: RModule -> Doc
prettyModule rmod =
    P.text "module" <+> P.text modname                        $$
    P.nest 4 (P.text "where")                                 $$
    P.text ""                                                 $$
    P.vcat (map (\t -> P.text "import" <+> P.text t) imports) $$
    P.vcat functions
  where
    modname = modName rmod
    imports = modImports rmod
    functions = modFunctions rmod

prettyGhci :: RModule -> Doc
prettyGhci rmod =
    (if null imports
      then P.empty
      else P.text ":m +" <+> P.hcat (map P.text imports))     $$
    P.vcat functions
  where
    imports = modImports rmod
    functions = modFunctions rmod

-- | Translate R expresstion to the module
translate :: R.SEXP -> RModule -> IO RModule
translate x mod = do
    -- XXX: currently we have hardcoded ghci but it's not right
    ls <- translate2ghci <$> translate1 <$> translate0 x
    return $ mod{modFunctions = ls}

-- | Step0 translation on this step we are mapping R Structures to
-- the unityped Haskell values, without deep inspection of actions to
-- optimize/rewrite R language.
--
-- This is the only step where we will need interpreter
translate0 :: R.SEXP -> IO [RValue]
translate0 x = do
    t <- R.typeOf x
    case t of
      R.IntSXP  -> error "int"
      R.RealSXP -> error "real"
      R.ExpSXP  -> translateExp x
      _         -> error "unknown"
  where
    translateExp y = do
        l <- R.length x
        -- | TODO create hilevel wrapper
        forM [0..(l-1)] $ \i -> do
--          putStrLn "-----------------------------"
          e <- R.vectorELT x i
          translateValue e
    translateValue y = do
        t <- R.typeOf y
--        print t
        case t of
          R.NilSXP  -> return RNil
          R.IntSXP  -> error "no translation for int"
          R.RealSXP -> translateReal y
          R.ExpSXP  -> error "it's not possilbe to translate expression as value"
          R.LangSXP -> translateLang y
          R.SymSXP  -> RVar  <$> translateSym y
          R.ListSXP -> RList <$> translateList y
          _         -> error $ "unsopported type: "++ show t
    translateLang y = do
        vl <- translateSym =<< R.car y
        ls <- translateList =<< R.cdr y
        return $ RLang vl ls
    translateSym y = do
        nm  <- R.char =<< R.printName y
        vl  <- R.symValue y
        tvl <- R.typeOf vl
--        putStr "SYM: "
--        R.printValue y
--        putStr $ "\nSYM-Name: "++nm
--      putStr $ "\nSYM-Value (" ++ show tvl ++ ") "
--      when (tvl == R.BuiltinSXP) $ R.printValue vl
--      putStr "\nSYM-Internal: "
--      R.printValue =<< R.symInternal y
--      putStrLn "\nSYM-END"
        return nm         -- TODO: this is not correct (!)
    translateReal y = do
        l    <- R.length y
        cptr <- R.real y
        v <- U.generateM l (\i -> realToFrac <$> peekElemOff cptr i)
        return $ RReal v
--    translateList :: R.SEXP -> IO [RValue]
    translateList y = do
        t <- R.typeOf y
        case t of
          R.NilSXP  -> return []
          R.ListSXP -> do
            z  <- R.car y
            o  <- translateValue z
            os <- translateList =<< R.cdr y
            return $ o:os

-- | Translate a set of RValues into the Haskell code
translate1 :: [RValue] -> [RExpr]
translate1 = concatMap go
    -- XXX: we have to keep state and change it to track env, variables
    -- naming and such stuff but we don't want to do it from the start!
  where
    -- constants are not changing anything just ignoring
    -- XXX: if we can access to 'result of the previous statement' 
    -- this is no longer the case
    go z@(RReal x) = [REConst z]
    -- assignment of the value
    go (RLang  "<-" [lhs,rhs]) =
        case rhs of
          RLang "function" _ -> [REFun lhs rhs]
          _                  -> [REAssign lhs rhs]
    -- XXX: this is just wrong we want to assign temporary name to the
    -- value
    go (RLang x z) = [RECall x z]


-- | This is Ghci version of the last step of the translation
--
translate2ghci :: [RExpr] -> [Doc]
translate2ghci = concatMap go
  where
    go (REConst x)    = [value x]
    go (REAssign x y) = error "translate-ghci: Assign is not implemented yet"
    go (REFun x y)    = error "translate-ghci: Fun is not implemented yet"
    go (RECall x y)   = 
          [fun  x y]
   --       | rhs == RLang "function"  = [name lhs ++"="++ fun rhs]

name :: RValue -> Doc
name (RVar x) = P.text x
name _ = error "incorrect variable"

fun :: RFunction -> [RValue] -> Doc
fun "+" [a,b] = value a <+> P.text "+" <+> value b
fun "-" [a,b] = value a <+> P.text "-" <+> value b
fun "/" [a,b] = value a <+> P.text "/" <+> value b
fun "*" [a,b] = value a <+> P.text "*" <+> value b
fun "(" [a]   = P.parens $ value a
fun x _       = error $ "function '" ++ x ++ "' is  unsupported:"

value :: RValue -> Doc
value y@(RVar _) = name y
value (RLang x y) = fun x y
value (RReal v)
  | U.length v == 1 = P.parens $  P.text "fromRational" <+> (P.text . show $ U.head v) <+> P.text ":: RTDouble"
--value y@(RReal x) = "(mkRTDouble " ++ (show $ U.toList x) ++ ")"
value y = error $ "value: unsupported argument " ++ show y
