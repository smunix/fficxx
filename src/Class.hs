module Class where

import Data.Char

import Text.StringTemplate hiding (render)
import Text.StringTemplate.Helpers

import qualified Data.Map as M

import CType
import Util
import Function
import Templates

data Class = Class { 
    class_name :: String, 
    class_parents :: [Class],
    class_funcs :: [Function]
  } 

instance Show Class where
  show x = show (class_name x)

instance Eq Class where
  (==) x y = class_name x == class_name y

instance Ord Class where
  compare x y = compare (class_name x) (class_name y)

type DaughterMap = M.Map Class [Class] 

mkDaughterMap :: [Class] -> DaughterMap 
mkDaughterMap = foldl mkDaughterMapWorker M.empty  
  where mkDaughterMapWorker m c = let ps = class_parents c 
                                  in  foldl (addmeToYourDaughterList c) m ps 
        addmeToYourDaughterList c m p = let f Nothing = Just [c]
                                            f (Just cs)  = Just (c:cs)    
                                        in  M.alter f p m
       
ctypeToHsType :: Class -> Types -> String
ctypeToHsType c Void = "()" 
ctypeToHsType c SelfType = class_name c
ctypeToHsType c (CT CTString _) = "String"
ctypeToHsType c (CT CTInt _) = "Int" 
ctypeToHsType c (CT CTDouble _) = "Double"
ctypeToHsType c (CT CTBool _ ) = "Int"
ctypeToHsType c (CT CTDoubleStar _) = "[Double]"
ctypeToHsType c (CPT (CPTClass name) _) = name

-- 
typeclassName :: Class -> String
typeclassName c = 'I' : class_name c


hsClassName :: Class 
               -> (String, String)  -- ^ High-level, 'Raw'-level
hsClassName c = 
  let cname = class_name c
  in (cname, "Raw" ++ cname) 


hsFuncTyp :: Class -> Function -> String
hsFuncTyp c f = let args = func_args f 
                    ret  = func_ret  f 
                in  self ++ " -> " ++ concatMap ((++ " -> ") . hsargtype . fst) args ++ hsrettype ret 
                    
  where (hcname,rcname) = hsClassName c
        self = "(Ptr " ++ rcname ++ ")" 

        hsargtype (CT ctype _) = hsCTypeName ctype
        hsargtype (CPT x _) = hsCppTypeName x 
        hsargtype SelfType = self 
        
        hsrettype Void = "IO ()"
        hsrettype SelfType = "IO " ++ self
        hsrettype (CT ctype _) = "IO " ++ hsCTypeName ctype
        hsrettype (CPT x _ ) = "IO " ++ hsCppTypeName x 
        
hsFuncTypNoSelf :: Class -> Function -> String
hsFuncTypNoSelf c f = let args = func_args f 
                          ret  = func_ret  f 
                      in  intercalateWith connArrow id $ map (hsargtype . fst) args ++ [hsrettype ret]  
                          
  where (hcname,rcname) = hsClassName c
        self = "(Ptr " ++ rcname ++ ")" 

        hsargtype (CT ctype _) = hsCTypeName ctype
        hsargtype (CPT x _) = hsCppTypeName x 
        hsargtype SelfType = self 
        
        hsrettype Void = "IO ()"
        hsrettype SelfType = "IO " ++ self
        hsrettype (CT ctype _) = "IO " ++ hsCTypeName ctype
        hsrettype (CPT x _ ) = "IO " ++ hsCppTypeName x 


hscFuncName :: Class -> Function -> String         
hscFuncName c f = "c_" ++ toLowers (class_name c) ++ "_" ++ toLowers (func_name f)
        
hsFuncName :: Function -> String 
hsFuncName f = let (x:xs) = func_name f 
               in (toLower x) : xs
                  
hsFuncXformer :: Function -> String 
hsFuncXformer func = let len = length (func_args func) 
                     in "xform" ++ show len
                        
hsFuncXformerNew :: Function -> String 
hsFuncXformerNew func = let len = length (func_args func) 
                        in "xform" ++ show (len - 1)

                        
                        
