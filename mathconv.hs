{-# LANGUAGE DeriveDataTypeable, ExtendedDefaultRules, FlexibleContexts   #-}
{-# LANGUAGE LambdaCase, MultiParamTypeClasses, NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings, PatternGuards, StandaloneDeriving         #-}
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-type-defaults -fno-warn-unused-do-bind #-}
module MathConv where
import           Control.Applicative
import           Control.Arrow                   (left)
import           Control.Effect
import           Control.Lens                    hiding (op, rewrite)
import           Control.Monad.Identity
import           Data.Data
import           Data.Default
import           Data.Maybe                      (fromMaybe)
import           Data.Maybe                      (listToMaybe)
import qualified Data.Set                        as S
import qualified Data.Text                       as T
import           Filesystem.Path.CurrentOS       hiding (concat, null, (<.>),
                                                  (</>))
import qualified MyTeXMathConv                   as MyT
import           Prelude                         hiding (FilePath)
import           Shelly                          hiding (get)
import           Text.LaTeX.Base                 hiding ((&))
import           Text.LaTeX.Base.Class
import           Text.LaTeX.Base.Parser
import           Text.LaTeX.Base.Syntax
import           Text.Pandoc                     hiding (MathType)
import           Text.Pandoc.Shared
import qualified Text.Parsec                     as P
import           Text.TeXMath.Readers.TeX.Macros

deriving instance Typeable Measure
deriving instance Data Measure
deriving instance Typeable TeXArg
deriving instance Data TeXArg
deriving instance Typeable MathType
deriving instance Data MathType
deriving instance Data LaTeX
instance Plated LaTeX

default (String)

myReaderOpts :: ReaderOptions
myReaderOpts = def { readerExtensions = S.insert Ext_raw_tex pandocExtensions
                   , readerParseRaw = True
                   }

parseTeX :: String -> Either String LaTeX
parseTeX = left show . P.parse latexParser "" . T.pack

texToMarkdown :: FilePath -> String -> IO Pandoc
texToMarkdown fp src = do
  macros <- fst . parseMacroDefinitions <$> readFile "/Users/hiromi/Library/texmf/tex/platex/mystyle.sty"
  let latexTree = view _Right $ parseTeX $ applyMacros macros $ src
      rewritten = T.unpack $ render $ preprTeX latexTree
      base = dropExtension fp
      pandoc = rewriteEnv $ readLaTeX myReaderOpts rewritten
      (pandoc',tikzs) = procTikz base pandoc
      tlibs = queryWith (\a -> case a of { c@(TeXComm "usetikzlibrary" _) -> [c] ; _ -> []} )
              latexTree
  unless (null tikzs) $ shelly $ silently $ do
    master <- canonic base
    mkdir_p master
    withTmpDir $ \tmp -> do
      cd tmp
      writefile "image.tex" $ render $ buildTikzer tlibs tikzs
      cmd "xelatex" "-shell-escape" "image.tex"
      pngs <- findWhen (return . hasExt "png") "."
      mapM_ (flip cp master) pngs
  return pandoc'

preprTeX :: LaTeX -> LaTeX
preprTeX = bottomUp rewrite . bottomUp alterEnv
  where
    expands = ["Set", "Braket"]
    alterEnv (TeXEnv env args body)
      | Just env' <- lookup env envAliases = TeXEnv env' args body
    alterEnv e = e
    rewrite (TeXComm comm [FixArg src]) | comm `elem` expands =
      case breakTeXOn "|" src of
        Just (lhs, rhs) -> TeXComm comm [FixArg lhs, FixArg rhs]
        Nothing -> TeXComm (T.unpack $ T.toLower $ T.pack comm) [FixArg src]
    rewrite t = t

splitTeXOn :: Text -> LaTeX -> [LaTeX]
splitTeXOn delim t =
  case breakTeXOn delim t  of
    Nothing -> [tex]
    Just (a, b) -> a : splitTeXOn delim b

breakTeXOn :: T.Text -> LaTeX -> Maybe (LaTeX, LaTeX)
breakTeXOn _ TeXEmpty = Nothing
breakTeXOn s (TeXRaw t) =
  case T.breakOn s t of
    (_, "") -> Nothing
    answer -> answer & _2 %~ T.drop 1
                     & both %~ TeXRaw
                     & Just
breakTeXOn s (TeXSeq l r) =
      do (l0, l1) <- breakTeXOn s l
         return (l0, TeXSeq l1 r)
  <|> do (r0, r1) <- breakTeXOn s r
         return (TeXSeq l r0, r1)
breakTeXOn _ _ = Nothing

envs :: [String]
envs = [ "prop", "proof", "theorem", "lemma", "axiom", "remark","exercise"
       , "definition", "question", "answer", "problem", "corollary"
       ]

envAliases :: [(String, String)]
envAliases = [("enumerate*", "enumerate!")
             ,("itemize*", "itemize")
             ]

commandDic :: [(String, Either ([Inline] -> Inline) String)]
commandDic = [("underline", Right "u"), ("bf", Left Strong)]

rewriteInlineCmd :: [Inline] -> [Inline]
rewriteInlineCmd = concatMap step
  where
    step (RawInline "latex" src)
        | Right t <- parseTeX src = rewrite t
    step i = [i]
    rewrite (TeXSeq l r) = rewrite l ++ rewrite r
    rewrite c@(TeXComm cm [FixArg arg]) =
      case lookup cm commandDic of
        Just (Right t) -> [ RawInline "html" $ "<" ++ t ++ ">"
                            , RawInline "latex" $ T.unpack $ render arg
                            , RawInline "html" $ "</" ++ t ++ ">"
                            ]
        Just (Left inl) -> [inl [RawInline "latex" $ T.unpack $ render arg]]
        _ -> [RawInline "latex" $ T.unpack $render c]
    rewrite c = [RawInline "latex" $ T.unpack $ render c]

rewriteEnv :: Pandoc -> Pandoc
rewriteEnv (Pandoc meta bs) = Pandoc meta $ bottomUp rewriteInlineCmd $ rewriteBeginEnv bs

rewriteBeginEnv :: [Block] -> [Block]
rewriteBeginEnv = concatMap step
  where
    step (RawBlock "latex" src)
      | Right (TeXEnv "enumerate!" args body) <- parseTeX src
      = [procEnumerate args body]
      | Right (TeXEnv env args body) <- parseTeX src
      , env `elem` envs =
          let divStart
                  | null args = concat ["<div class=\"", env, "\">"]
                  | otherwise = concat ["<div class=\"", env, "\" name=\""
                                       , procMathInline $
                                         unwords $ map (init . tail . T.unpack . render) args, "\">"
                                       ]
              Pandoc _ myBody = rewriteEnv $ readLaTeX myReaderOpts $ T.unpack $ render body
          in RawBlock "html" divStart : myBody ++ [RawBlock "html" "</div>"]
    step b = [b]

procEnumerate :: [TeXArg] -> LaTeX -> Block
procEnumerate args body =
  let Pandoc _ [OrderedList _ blcs] = rewriteEnv $ readLaTeX myReaderOpts $
                                      T.unpack $ render $ TeXEnv "enumerate" [] body
  in OrderedList (parseEnumOpts args) blcs

parseEnumOpts :: [TeXArg] -> ListAttributes
parseEnumOpts args =
  let opts = [ (render key, render val)
             | OptArg lat <- args
             , opt <- splitTeXOn "," lat
             , Just (key, val) <- [breakTeXOn "=" opt]
             ]
      styleDic = [("arabic", Decimal)
                 ,("Alph", UpperAlpha)
                 ,("alph", LowerAlpha)
                 ,("Roman", UpperRoman)
                 ,("roman", LowerRoman)
                 ]
      labF = fromMaybe "" $ lookup "label" opts
      start = maybe 1 (read . T.unpack) $ lookup "start" opts
      style = fromMaybe Decimal $ listToMaybe
              [ sty | (com, sty) <- styleDic, ("\\"<>com) `T.isInfixOf` labF]
      oparens = T.count "(" labF
      cparens = T.count ")" labF
      delim
        | max oparens cparens >= 2 = TwoParens
        | max oparens cparens == 1 = OneParen
        | "." `T.isInfixOf` labF   = Period
        | otherwise = DefaultDelim
  in (start, style, delim)


buildTikzer :: [LaTeX] -> [LaTeX] -> LaTeX
buildTikzer tikzLibs tkzs = snd $ runIdentity $ runLaTeXT $ do
  documentclass ["tikz", "preview", "convert={density=175,outname=image}", "12pt"] "standalone"
  usepackage [] "zxjatype"
  usepackage ["hiragino"] "zxjafont"
  usepackage [] "amsmath"
  usepackage [] "amssymb"
  usepackage [] "pgfplots"
  comm1 "usetikzlibrary" "matrix,arrows"
  mapM_ fromLaTeX tikzLibs
  comm1 "tikzset" $ do
    "node distance=2cm, auto, >=latex,"
    "description/.style="
    braces "fill=white,inner sep=1.5pt,auto=false"
  comm1 "pgfplotsset" $ do
    "tick label style="
    braces "font=\\tiny"
    ",compat=1.8,width=6cm"
  document $ mapM_ textell tkzs

fresh = get <* modify succ

procTikz :: FilePath -> Pandoc -> (Pandoc, [LaTeX])
procTikz fp pan = runEffect $ runWriter $ evalState (0 :: Int) (bottomUpM step pan)
  where
    step (RawBlock "latex" src)
      | Right ts <- parseTeX src = do
        liftM Plain $ forM [ t | t@(TeXEnv "tikzpicture" _ _) <- universe ts] $ \t -> do
          tell [t]
          n <- fresh
          return $ Image [Str $ "Figure-" ++ show (n+1 :: Int)]
                         (encodeString $ ("/" :: String) </> fp </> ("image-"++show n++".png"),"")
    step a = return a

procMathInline :: String -> String
procMathInline = stringify . bottomUp go . readLaTeX def
  where
    go :: Inline -> Inline
    go = bottomUp $ \a -> case a of
      Math _ math ->  Str $ stringify $ MyT.readTeXMath  math
      t -> t
