module Core.Specialize( SpecializeEnv
                      , specenvNew
                      , specenvEmpty
                      , specenvExtend, specenvExtends
                      , specenvLookup
                      , ppSpecializeEnv

                      , extractSpecializeDefs 
                      ) where

import Data.Maybe (mapMaybe)

import Lib.PPrint
import Common.Name
import Common.NameMap (NameMap)
import qualified Common.NameMap  as M
import Common.NameSet (NameSet)
import qualified Common.NameSet as S
import Core.Core
import Core.Pretty ()
import Type.Pretty
import Lib.Trace

data SpecializeDefs = SpecializeDefs
  { targetFunc :: Name
  , argsToSpecialize :: [Bool]
  } deriving (Show)

specialize :: Env -> Int -> SpecializeEnv -> DefGroups -> (DefGroups, Int)
specialize = undefined

extractSpecializeDefs :: DefGroups -> SpecializeEnv
extractSpecializeDefs = 
    specenvNew
  . filter (not . null . argsToSpecialize)
  . map getInline
  . flattenDefGroups
  . filter isRecursiveDefGroup

  where
    isRecursiveDefGroup (DefRec [def]) = True
    isRecursiveDefGroup _ = False

getInline :: Def -> SpecializeDefs
getInline def =
    SpecializeDefs (defName def)
  $ toBools
  $ map snd
  $ M.toList
  $ M.filterWithKey (\name _ -> name `S.member` calledInThisDef def) (passedRecursivelyToThisDef def)

type DistinctSorted a = a

-- list passed in should be sorted and not contain duplicates
-- >>> toBools [1, 3, 4, 7]
-- [False, True, False, True, True, False, False, True]
toBools :: DistinctSorted [Int] -> [Bool]
toBools =
    concatMap (\x -> replicate x False <> [True])
  -- after appending a 'True' the rest of the counts are one off
  . (\(x:xs) -> x : map pred xs)
  . diffs
  where
    diffs xs | xs <- 0:xs = zipWith (-) (tail xs) xs

calledInThisDef :: Def -> S.NameSet
calledInThisDef def = foldMapExpr go $ defExpr def
  where 
    go (Var (TName name _) _) = S.singleton name
    go _ = mempty
    -- go (App (Var (TName name _) _) xs)             = S.singleton name
    -- go (App (TypeApp (Var (TName name _) _) _) xs) = S.singleton name
    -- go _ = S.empty

-- return list of (paramName, paramIndex) that get called recursively to the same function in the same order
passedRecursivelyToThisDef :: Def -> NameMap Int
passedRecursivelyToThisDef def 
  -- TODO: FunDef type to avoid this check?
  = case defExpr def of
      Lam params effect body 
        -> foldMapExpr (callsWith params) $ defExpr def
      TypeLam _ (Lam params effect body) 
        -> foldMapExpr (callsWith params) $ defExpr def
      _ -> mempty
  where
    dname = defName def

    callsWith params (App (Var (TName name _) _) args)
      | name == dname  = check args params
    callsWith params (App (TypeApp (Var (TName name _) _) _) args)
      | name == dname  = check args params
    callsWith params _ = mempty

    check args params =
      M.fromList $ flip mapMaybe (zip3 [0..] args params) $ \(i, arg, param) ->
        case arg of
          Var tname _ | tname == param -> Just (getName tname, i)
          _ -> Nothing


{--------------------------------------------------------------------------
  
--------------------------------------------------------------------------}

-- | Environment mapping names to specialize definitions
newtype SpecializeEnv   = SpecializeEnv (M.NameMap SpecializeDefs)

-- | The intial SpecializeEnv
specenvEmpty :: SpecializeEnv
specenvEmpty
  = SpecializeEnv M.empty

specenvNew :: [SpecializeDefs] -> SpecializeEnv
specenvNew xs
  = specenvExtends xs specenvEmpty

specenvExtends :: [SpecializeDefs] -> SpecializeEnv -> SpecializeEnv
specenvExtends xs specenv
  = foldr specenvExtend specenv xs

specenvExtend :: SpecializeDefs -> SpecializeEnv -> SpecializeEnv
specenvExtend idef (SpecializeEnv specenv)
  = SpecializeEnv (M.insert (targetFunc idef) idef specenv)

specenvLookup :: Name -> SpecializeEnv -> Maybe SpecializeDefs
specenvLookup name (SpecializeEnv specenv)
  = M.lookup name specenv


instance Show SpecializeEnv where
 show = show . pretty

instance Pretty SpecializeEnv where
 pretty g
   = ppSpecializeEnv defaultEnv g


ppSpecializeEnv :: Env -> SpecializeEnv -> Doc
ppSpecializeEnv env (SpecializeEnv specenv)
   = vcat [fill maxwidth (ppName env name) <+> list (map pretty (argsToSpecialize sdef))
          | (name,sdef) <- M.toList specenv]
   where
     maxwidth      = 12