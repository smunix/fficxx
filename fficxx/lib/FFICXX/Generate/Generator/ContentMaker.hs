{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-----------------------------------------------------------------------------
-- |
-- Module      : FFICXX.Generate.Generator.ContentMaker
-- Copyright   : (c) 2011-2016 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module FFICXX.Generate.Generator.ContentMaker where 

import           Control.Applicative
import           Control.Lens                           (set,at)
import           Control.Monad.Trans.Reader
import           Data.Function                          (on)
import qualified Data.Map                          as M
import           Data.List 
import           Data.List.Split                        (splitOn) 
import           Data.Maybe
import           Data.Text                              (Text)
import qualified Data.Text                         as T
import qualified Data.Text.Lazy                    as TL
import           Data.Text.Template                     hiding (render)
import           Language.Haskell.Exts.Syntax           (Module(..),Decl(..))
import           Language.Haskell.Exts.Pretty           (prettyPrint)
import           System.FilePath
-- 
import           FFICXX.Generate.Code.Cpp
import           FFICXX.Generate.Code.HsFFI 
import           FFICXX.Generate.Code.HsFrontEnd
import           FFICXX.Generate.Type.Annotate
import           FFICXX.Generate.Type.Class
import           FFICXX.Generate.Type.PackageInterface  ( TypeMacro(..), HeaderName(..)
                                                        , PackageInterface, PackageName(..)
                                                        , ClassName(..)
                                                        )
import           FFICXX.Generate.Util
import           FFICXX.Generate.Util.HaskellSrcExts
--

srcDir :: FilePath -> FilePath
srcDir installbasedir = installbasedir </> "src" 

csrcDir :: FilePath -> FilePath
csrcDir installbasedir = installbasedir </> "csrc" 

-- existentialHsFileName :: String 
-- existentialHsFileName = "Existential.hs"

---- common function for daughter


-- | 
mkGlobal :: [Class] -> ClassGlobal
mkGlobal = ClassGlobal <$> mkDaughterSelfMap <*> mkDaughterMap 


-- | 
mkDaughterDef :: ((String,[Class]) -> String) 
              -> DaughterMap 
              -> String 
mkDaughterDef f m =   
    let lst = M.toList m 
        f' (x,xs) =  f (x,filter (not.isAbstractClass) xs) 
    in (concatMap f' lst)

-- | 
mkParentDef :: ((Class,Class)->String) -> Class -> String
mkParentDef f cls = g (class_allparents cls,cls)
  where g (ps,c) = concatMap (\p -> f (p,c)) ps

-- | 
mkProtectedFunctionList :: Class -> String 
mkProtectedFunctionList c = 
    (unlines 
     . map (\x->"#define IS_" ++ class_name c ++ "_" ++ x ++ "_PROTECTED ()") 
     . unProtected . class_protected) c 

-- |
mkTypeDeclHeader :: TypeMacro -- ^ typemacro 
                 -> [Class]
                 -> String 
mkTypeDeclHeader (TypMcro typemacro) classes =
  let typeDeclBodyStr   = genAllCppHeaderTmplType classes 
  in subst
       "#ifdef __cplusplus\n\
       \extern \"C\" { \n\
       \#endif\n\
       \\n\
       \#ifndef $typemacro\n\
       \#define $typemacro\n\
       \\n\
       \$typeDeclBody\n\
       \\n\
       \#endif // $typemacro\n\
       \\n\
       \#ifdef __cplusplus\n\
       \}\n\
       \#endif\n" 
       (context [ ("typeDeclBody", typeDeclBodyStr ) 
                , ("typemacro"   , typemacro       ) ])



declarationTemplate :: Text
declarationTemplate = 
  "#ifdef __cplusplus\n\
  \extern \"C\" { \n\
  \#endif\n\
  \\n\
  \#ifndef $typemacro\n\
  \#define $typemacro\n\
  \\n\
  \#include \"${cprefix}Type.h\"\
  \\n\
  \$declarationheader\n\
  \\n\
  \$declarationbody\n\
  \\n\
  \#endif // $typemacro\n\
  \\n\
  \#ifdef __cplusplus\n\
  \}\n\
  \#endif\n"

-- | 
mkDeclHeader :: TypeMacro  -- ^ typemacro prefix 
             -> String     -- ^ C prefix 
             -> ClassImportHeader 
             -> String 
mkDeclHeader (TypMcro typemacroprefix) cprefix header =
  let classes = [cihClass header]
      aclass = cihClass header
      typemacrostr = typemacroprefix ++ class_name aclass ++ "__" 
      declHeaderStr = intercalateWith connRet (\x->"#include \""++x++"\"") $
                        map unHdrName (cihIncludedHPkgHeadersInH header)
      declDefStr    = genAllCppHeaderTmplVirtual classes 
                      `connRet2`
                      genAllCppHeaderTmplNonVirtual classes 
                      `connRet2`   
                      genAllCppDefTmplVirtual classes
                      `connRet2`
                      genAllCppDefTmplNonVirtual classes
      classDeclsStr = if (fst.hsClassName) aclass /= "Deletable"
                        then mkParentDef genCppHeaderInstVirtual aclass 
                             `connRet2`
                             genCppHeaderInstVirtual (aclass, aclass)
                             `connRet2` 
                             genAllCppHeaderInstNonVirtual classes
                        else "" 
      declBodyStr   = declDefStr 
                      `connRet2` 
                      classDeclsStr 
  in subst declarationTemplate
       (context [ ("typemacro"        , typemacrostr  )
                , ("cprefix"          , cprefix       )
                , ("declarationheader", declHeaderStr ) 
                , ("declarationbody"  , declBodyStr   ) ])


definitionTemplate :: Text
definitionTemplate =
  "#include <MacroPatternMatch.h>\n\
  \$header\n\
  \\n\
  \using namespace std;\n\
  \$namespace\n\
  \\n\
  \template<class ToType, class FromType>\n\
  \const ToType* to_const(const FromType* x) {\n\
  \  return reinterpret_cast<const ToType*>(x);\n\
  \}\n\
  \\n\
  \template<class ToType, class FromType>\n\
  \ToType* to_nonconst(FromType* x) {\n\
  \  return reinterpret_cast<ToType*>(x);\n\
  \}\n\
  \\n\
  \template<class ToType, class FromType>\n\
  \const ToType& to_constref(const FromType& x) {\n\
  \  return reinterpret_cast<const ToType&>(x);\n\
  \}\n\
  \\n\
  \template<class ToType, class FromType>\n\
  \ToType& to_nonconstref(FromType& x) {\n\
  \  return reinterpret_cast<ToType&>(x);\n\
  \}\n\
  \\n\
  \#define CHECKPROTECT(x,y) IS_PAREN(IS_ ## x ## _ ## y ## _PROTECTED)\n\
  \\n\
  \#define TYPECASTMETHOD(cname,mname,oname) \\\n\
  \  IIF( CHECKPROTECT(cname,mname) ) ( \\\n\
  \  (to_nonconst<oname,cname ## _t>), \\\n\
  \  (to_nonconst<cname,cname ## _t>) )\n\
  \\n\
  \$cppbody\n"


-- | 
mkDefMain :: ClassImportHeader 
          -> String 
mkDefMain header =
  let classes = [cihClass header]
      headerStr = genAllCppHeaderInclude header ++ "\n#include \"" ++ (unHdrName (cihSelfHeader header)) ++ "\"" 
      namespaceStr = (concatMap (\x->"using namespace " ++ unNamespace x ++ ";\n") . cihNamespace) header
      aclass = cihClass header
      cppBody = mkProtectedFunctionList (cihClass header) 
                `connRet`
                mkParentDef genCppDefInstVirtual (cihClass header)
                `connRet` 
                if isAbstractClass aclass 
                  then "" 
                  else genCppDefInstVirtual (aclass, aclass)
                `connRet`
                genAllCppDefInstNonVirtual classes
  in subst definitionTemplate (context ([ ("header"   , headerStr    )
                                        , ("namespace", namespaceStr )
                                        , ("cppbody"  , cppBody      ) ])) 

-- | 
mkTopLevelFunctionHeader :: TypeMacro  -- ^ typemacro prefix 
                         -> String     -- ^ C prefix 
                         -> TopLevelImportHeader
                         -> String 
mkTopLevelFunctionHeader (TypMcro typemacroprefix) cprefix tih =
  let typemacrostr = typemacroprefix ++ "TOPLEVEL" ++ "__" 
      declHeaderStr = intercalateWith connRet (\x->"#include \""++x++"\"")
                      . map (unHdrName . cihSelfHeader) . tihClassDep $ tih
      declBodyStr    = intercalateWith connRet genTopLevelFuncCppHeader (tihFuncs tih)
  in subst declarationTemplate (context [ ("typemacro"        , typemacrostr  )
                                        , ("cprefix"          , cprefix       )
                                        , ("declarationheader", declHeaderStr )
                                        , ("declarationbody"  , declBodyStr   ) ])

-- | 
mkTopLevelFunctionCppDef :: String     -- ^ C prefix 
                         -> TopLevelImportHeader
                         -> String 
mkTopLevelFunctionCppDef cprefix tih =
  let cihs = tihClassDep tih
      declHeaderStr = "#include \"" ++ tihHeaderFileName tih <.> "h" ++ "\""
                      `connRet2`
                      (intercalate "\n" (nub (map genAllCppHeaderInclude cihs)))
                      `connRet2`
                      ((intercalateWith connRet (\x->"#include \""++x++"\"") . map (unHdrName . cihSelfHeader)) cihs)
      allns = nubBy ((==) `on` unNamespace) (tihClassDep tih >>= cihNamespace)
      namespaceStr = do ns <- allns 
                        ("using namespace " ++ unNamespace ns ++ ";\n")
      declBodyStr    = intercalateWith connRet genTopLevelFuncCppDefinition (tihFuncs tih)

  in subst definitionTemplate (context [ ("header"   , declHeaderStr)
                                       , ("namespace", namespaceStr )
                                       , ("cppbody"  , declBodyStr  ) ])

-- | 
mkFFIHsc :: ClassModule -> Module
mkFFIHsc m = mkModule (mname <.> "FFI") [lang ["ForeignFunctionInterface"]] ffiImports hscBody 
  where mname = cmModule m
        headers = cmCIH m
        ffiImports = [ mkImport "Foreign.C", mkImport "Foreign.Ptr", mkImport (mname <.> "RawType") ]
                     ++ genImportInFFI m
        hscBody = concatMap genHsFFI headers


-- |                      
mkRawTypeHs :: ClassModule -> Module
mkRawTypeHs m = mkModule (cmModule m <.> "RawType")
                  [lang [ "ForeignFunctionInterface", "TypeFamilies", "MultiParamTypeClasses"
                        , "FlexibleInstances", "TypeSynonymInstances"
                        , "EmptyDataDecls", "ExistentialQuantification", "ScopedTypeVariables" ]]
                  rawtypeImports rawtypeBody
  where rawtypeImports = [ mkImport "Foreign.ForeignPtr", mkImport "FFICXX.Runtime.Cast" ] 
        rawtypeBody = concatMap hsClassRawType . filter (not.isAbstractClass) . cmClass $ m

-- | 
mkInterfaceHs :: AnnotateMap -> ClassModule -> Module   
mkInterfaceHs amap m = mkModule (cmModule m <.> "Interface")
                         [lang [ "ForeignFunctionInterface", "TypeFamilies", "MultiParamTypeClasses"
                               , "FlexibleInstances", "TypeSynonymInstances"
                               , "EmptyDataDecls", "ExistentialQuantification", "ScopedTypeVariables" ]]
                         ifaceImports ifaceBody
  where classes = cmClass m
        ifaceImports =
          [ mkImport "Data.Word"
          , mkImport "Foreign.C"
          , mkImport "Foreign.Ptr"
          , mkImport "Foreign.ForeignPtr"
          , mkImport "FFICXX.Runtime.Cast" ]
          ++ genImportInInterface m
        ifaceBody = 
          runReader (mapM genHsFrontDecl classes) amap 
          ++ (map hsClassExistType .  filter (not.isAbstractClass)) classes
          ++ (concatMap genHsFrontUpcastClass . filter (not.isAbstractClass)) classes
          ++ (concatMap genHsFrontDowncastClass . filter (not.isAbstractClass)) classes

-- | 
mkCastHs :: ClassModule -> Module
mkCastHs m = mkModule (cmModule m <.> "Cast")
               [ lang [ "FlexibleInstances", "FlexibleContexts", "TypeFamilies"
                      , "MultiParamTypeClasses", "OverlappingInstances", "IncoherentInstances" ] ]
               castImports castBody
  where classes = cmClass m
        castImports = [ mkImport "Foreign.Ptr"
                      , mkImportExp "Foreign.ForeignPtr" [ "castForeignPtr", "newForeignPtr_" ]
                      , mkImport "Foreign.ForeignPtr.Unsafe"
                      , mkImport "FFICXX.Runtime.Cast"
                      , mkImport "System.IO.Unsafe" ]
                      ++ genImportInCast m
        castBody = mapMaybe genHsFrontInstCastable classes
                   ++ mapMaybe genHsFrontInstCastableSelf classes

-- | 
mkImplementationHs :: AnnotateMap -> ClassModule -> Module
mkImplementationHs amap m = mkModule (cmModule m <.> "Implementation")
                              [ lang [ "ForeignFunctionInterface", "TypeFamilies", "MultiParamTypeClasses"
                                     , "FlexibleInstances", "TypeSynonymInstances", "EmptyDataDecls"
                                     , "OverlappingInstances", "IncoherentInstances"
                                     ] ]
                              implImports implBody
  where classes = cmClass m
        implImports = [ mkImport "FFICXX.Runtime.Cast"
                      , mkImport "Data.Word"
                      , mkImport "Foreign.C"
                      , mkImport "Foreign.Ptr"
                      , mkImport "Foreign.ForeignPtr"
                      , mkImport "System.IO.Unsafe" ]
                      ++ genImportInImplementation m
        f :: Class -> [Decl]
        f y = concatMap (flip genHsFrontInst y) (y:class_allparents y)
        g :: Class -> [Decl]
        g y = map (flip genHsFrontInstExistVirtual y) (y:class_allparents y )

        implBody = concatMap f classes ++ concatMap g (filter (not.isAbstractClass) classes)
                   ++ runReader (concat <$> mapM genHsFrontInstNew classes) amap
                   ++ concatMap genHsFrontInstNonVirtual classes
                   ++ concatMap genHsFrontInstStatic classes
                   ++ map genHsFrontInstExistCommon (filter (not.isAbstractClass) classes)



{- 
-- | 
mkExistentialEach :: STGroup String 
                  -> Class 
                  -> [Class] 
                  -> String 
mkExistentialEach templates mother daughters =   
  let makeOneDaughterGADTBody daughter = render hsExistentialGADTBodyTmpl 
                                                [ ( "mother", (fst.hsClassName) mother ) 
                                                , ( "daughter",(fst.hsClassName) daughter ) ] 
      makeOneDaughterCastBody daughter = render hsExistentialCastBodyTmpl
                                                [ ( "mother", (fst.hsClassName) mother ) 
                                                , ( "daughter", (fst.hsClassName) daughter) ] 
      gadtBody = intercalate "\n" (map makeOneDaughterGADTBody daughters)
      castBody = intercalate "\n" (map makeOneDaughterCastBody daughters)
      str = renderTemplateGroup 
              templates 
              [ ( "mother" , (fst.hsClassName) mother ) 
              , ( "GADTbody" , gadtBody ) 
              , ( "castbody" , castBody ) ]
              "ExistentialEach.hs" 
  in  str

-- | 
mkExistentialHs :: STGroup String 
                -> ClassGlobal 
                -> ClassModule 
                -> String
mkExistentialHs templates cglobal m = 
  let classes = filter (not.isAbstractClass) (cmClass m)
      dsmap = cgDaughterSelfMap cglobal
      makeOneMother :: Class -> String 
      makeOneMother mother = 
        let daughters = case M.lookup (getClassModuleBase mother) dsmap of 
                             Nothing -> error "error in mkExistential"
                             Just lst -> filter (not.isAbstractClass) lst
            str = mkExistentialEach templates mother daughters
        in  str 
      existEachBody = intercalateWith connRet makeOneMother classes
      existHeaderStr = "module " ++ cmModule m <.> "Existential where"
      existImportStr = genImportInExistential dsmap m
      hsfilestr = renderTemplateGroup 
                    templates 
                    [ ("existHeader", existHeaderStr)
                    , ("existImport", existImportStr)
                    , ("modname", cmModule m)
                    , ( "existEachBody" , existEachBody) ]
                  "Existential.hs" 
  in  hsfilestr
-}

-- | 
mkInterfaceHSBOOT :: String -> Module
mkInterfaceHSBOOT mname = mkModule (mname <.> "Interface") [] [] hsbootBody
  where cname = last (splitOn "." mname)
        hsbootBody = [ mkClass [] ('I':cname) [mkTBind "a"] [] ]

-- | 
mkModuleHs :: ClassModule -> Module
mkModuleHs m = mkModuleE (cmModule m) [] (concatMap genExport (cmClass m)) (genImportInModule (cmClass m)) []

-- | 
mkPkgHs :: String -> [ClassModule] -> TopLevelImportHeader -> String 
mkPkgHs modname mods tih = 
    let tfns = tihFuncs tih 
        exportListStr = intercalateWith (conn "\n, ") ((\x->"module " ++ x).cmModule) mods 
                        ++ if null tfns 
                           then "" 
                           else "\n, " ++ intercalateWith (conn "\n, ") hsFrontNameForTopLevelFunction tfns 
        importListStr = intercalateWith connRet ((\x->"import " ++ x).cmModule) mods
                        ++ if null tfns 
                           then "" 
                           else "" `connRet2` "import Foreign.C" `connRet` "import Foreign.Ptr"
                                `connRet` "import FFICXX.Runtime.Cast" 
                                `connRet`
                                intercalateWith connRet 
                                  ((\x->"import " ++ modname ++ "." ++ x ++ ".RawType")
                                   .fst.hsClassName.cihClass) (tihClassDep tih)
        topLevelDefStr = intercalate "\n" (map (prettyPrint . genTopLevelFuncFFI tih) tfns)
                         `connRet2`
                         intercalate "\n\n" (map (intercalateWith connRet prettyPrint) (map genTopLevelFuncDef tfns))
    in subst
         "module $summarymod (\n\
         \  $exportList\n\
         \) where\n\
         \\n\
         \$importList\n\
         \$topLevelDef\n"
         (context [ ("summarymod" , modname       )
                  , ("exportList" , exportListStr ) 
                  , ("importList" , importListStr ) 
                  , ("topLevelDef", topLevelDefStr) ])


  
-- |
mkPackageInterface :: PackageInterface 
                   -> PackageName 
                   -> [ClassImportHeader] 
                   -> PackageInterface
mkPackageInterface pinfc pkgname = foldr f pinfc 
  where f cih repo = 
          let name = (class_name . cihClass) cih 
              header = cihSelfHeader cih 
          in set (at (pkgname,ClsName name)) (Just header) repo

