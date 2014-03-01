module Lib.Makefile.Parser
  ( makefile, parseMakefile
  ) where

import Control.Applicative (Applicative(..), (<$>), (<$), (<|>))
import Control.Monad
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State (StateT, evalStateT)
import Data.Char (isAlpha, isAlphaNum)
import Data.List (partition)
import Data.Map (Map)
import Data.Maybe (fromMaybe, listToMaybe)
import Lib.Makefile.Types (Target(..), Makefile(..))
import Lib.Parsec (parseFromFile, showErr, showPos)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hPutStrLn, stderr)
import Text.Parsec ((<?>))
import qualified Control.Exception as E
import qualified Control.Monad.Trans.State as State
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Text.Parsec as P
import qualified Text.Parsec.Pos as Pos

type IncludeStack = [(Pos.SourcePos, String)]
type Vars = Map String String
type Parser = P.ParsecT String IncludeStack (StateT Vars IO)

horizSpace :: Parser Char
horizSpace = P.satisfy (`elem` " \t")

horizSpaces :: Parser ()
horizSpaces = P.skipMany horizSpace

horizSpaces1 :: Parser ()
horizSpaces1 = P.skipMany1 horizSpace

tillEndOfLine :: Parser String
tillEndOfLine = P.many (P.satisfy (/= '\n'))

comment :: Parser ()
comment = void $ P.char '#' *> tillEndOfLine

skipLineSuffix :: Parser ()
skipLineSuffix = horizSpaces <* P.optional comment <* P.lookAhead (void (P.char '\n') <|> P.eof)

filepath :: Parser FilePath
filepath = P.many1 $ P.satisfy $ \x -> x `notElem` ":#| \t\r\n"

-- Parsec's sepBy cannot handle the separator following the sequence
-- without a following element:
sepBy :: Parser a -> Parser () -> Parser [a]
item `sepBy` sep = sepBy1 item sep <|> return []

sepBy1 :: Parser a -> Parser () -> Parser [a]
item `sepBy1` sep = (:) <$> item <*> P.many (P.try (sep >> item))

filepaths :: Parser [FilePath]
filepaths = filepath `sepBy` horizSpaces1

filepaths1 :: Parser [FilePath]
filepaths1 = filepath `sepBy1` horizSpaces1

literalString :: Char -> Parser String
literalString delimiter = do
  x <- P.char delimiter
  str <- concat <$> P.many p
  y <- P.char delimiter
  return $ concat [[x], str, [y]]
  where
    p = escapeSequence <|>
        ((: []) <$> P.satisfy (`notElem` ['\n', delimiter]))

escapeSequence :: Parser String
escapeSequence = do
  esc <- P.char '\\'
  code <- P.anyChar
  return [esc, code]

ident :: Parser String
ident = (:) <$> P.satisfy isAlphaEx <*> P.many (P.satisfy isAlphaNumEx)

varId :: [FilePath] -> [FilePath] -> [FilePath] -> Parser ((String -> String) -> String)
varId outputPaths inputPaths ooInputPaths =
  P.choice
  [ firstOutput <$ P.char '@'
  , firstInput  <$ P.char '<'
  , allInputs   <$ P.char '^'
  , allOOInputs <$ P.char '|'
  ]
  where
    getFirst err paths = fromMaybe err $ listToMaybe paths
    firstOutput toString = toString $ getFirst "No first output for @ variable" outputPaths
    firstInput  toString = toString $ getFirst "No first input for < variable"  inputPaths
    allInputs   toString = unwords $ map toString inputPaths
    allOOInputs toString = unwords $ map toString ooInputPaths

varModifier :: Parser (String -> String)
varModifier =
  P.choice
  [ takeDirectory <$ P.char 'D'
  , takeFileName  <$ P.char 'F'
  ]

metaVariable :: [FilePath] -> [FilePath] -> [FilePath] -> Parser String
metaVariable outputPaths inputPaths ooInputPaths =
  P.try (P.char '(' *> (vid <*> varModifier) <* P.char ')') <|>
  (vid <*> pure id)
  where
    vid = varId outputPaths inputPaths ooInputPaths

-- '$' already parsed
variable :: Parser String
variable = do
  varName <- P.char '{' *> ident <* P.char '}'
  mResult <- lift $ State.gets $ M.lookup varName
  case mResult of
    Nothing -> do
      posStr <- showPos <$> P.getPosition
      liftIO $ hPutStrLn stderr $ posStr ++ ": No such variable: " ++ show varName
      fail "No such variable"
    Just val -> return val

-- Inside a single line
interpolateString :: Parser String -> Parser String
interpolateString var =
  concat <$> P.many (literalString '\'' <|> interpolatedChar)
  where
    interpolatedChar =
      escapeSequence <|> (P.char '$' *> var) <|>
      (: []) <$> P.satisfy (/= '\n')

type IncludePath = FilePath

includeLine :: Parser IncludePath
includeLine = P.try $ do
  horizSpaces
  fileNameStr <-
    P.string "include" *> horizSpaces1 *>
    (literalString '"' <|> (wrap <$> tillEndOfLine))
  skipLineSuffix
  case reads fileNameStr of
    [(path, "")] -> return path
    _ -> P.unexpected $ "Malformed include statement: " ++ show fileNameStr
  where
    wrap x = concat ["\"", x, "\""]

runInclude :: IncludePath -> Parser ()
runInclude includedPath = do
  eFileContent <- liftIO $ E.try $ readFile includedPath
  case eFileContent of
    Left e@E.SomeException {} -> fail $ "Failed to read include file: " ++ show e
    Right fileContent ->
      void $ P.updateParserState $ \oldState -> oldState
        { P.stateInput = fileContent
        , P.statePos = Pos.initialPos includedPath
        , P.stateUser = (P.statePos oldState, P.stateInput oldState) : P.stateUser oldState
        }

returnToIncluder :: Parser ()
returnToIncluder =
  P.eof *> do
    posStack <- P.getState
    case posStack of
      [] -> fail "Don't steal eof"
      ((pos, input) : rest) ->
        void $ P.setParserState
        P.State { P.statePos = pos, P.stateInput = input, P.stateUser = rest }
    -- "include" did not eat the end of line, so when we return here,
    -- we'll be before the newline, and we'll read a fake empty line
    -- here, but no big deal

beginningOfLine :: Parser ()
beginningOfLine = do
  mIncludePath <- P.optionMaybe $ P.try (includeLine <* P.optional (P.char '\n'))
  case mIncludePath of
    Just includePath -> runInclude includePath *> beginningOfLine
    Nothing -> -- A line that begins with eof can still lead to a new line in the includer
      P.optional $ returnToIncluder *> beginningOfLine

-- Called to indicate we are willing to start a new line, which can be
-- done in two ways:
-- * A simple newline char
-- * End of file that leads back to the includer.
--
-- Either way, we get to the beginning of a new line, and despite
-- Parsec unconvinced, we do make progress in both, so it is safe for
-- Applicative.many (P.many complains)
newline :: Parser ()
newline =
  (returnToIncluder <|> void (P.char '\n')) *> beginningOfLine

-- we're at the beginning of a line, and we can eat
-- whitespace-only lines, as long as we also eat all the way to
-- the end of line (including the next newline if it exists)
-- Always succeeds, but may eat nothing at all:
noiseLines :: Parser ()
noiseLines =
  P.try (horizSpaces1 *> ((eol *> noiseLines) <|> properEof)) <|>
  P.optional (P.try (eol *> noiseLines))
  where
    eol = skipLineSuffix *> newline

cmdLine :: Parser String -> Parser String
cmdLine var =
  P.try $
  newline *> noiseLines *> P.char '\t' *>
  interpolateString var <*
  skipLineSuffix

-- Parses the target's entire lines (excluding the pre/post newlines)
target :: Parser Target
target = do
  outputPaths <- P.try $
    -- disallow tab here
    P.skipMany (P.char ' ') *>
    (filepaths1 <?> "outputs") <*
    horizSpaces <* P.char ':'
  horizSpaces
  inputPaths <- filepaths <?> "inputs"
  orderOnlyInputs <-
    fmap (fromMaybe []) . P.optionMaybe $ P.try $
    horizSpaces *> P.char '|' *> horizSpaces *> filepaths
  skipLineSuffix
  let var = variable <|> metaVariable outputPaths inputPaths orderOnlyInputs
  cmdLines <- P.many (cmdLine var <?> "cmd line")
  return Target
    { targetOutputPaths = outputPaths
    , targetExplicitInputHints = inputPaths
    , targetOrderOnlyInputHints = orderOnlyInputs
    , targetCmds = filter (not . null) cmdLines
    }

mkMakefile :: [Target] -> Makefile
mkMakefile targets
  | not $ null $ concatMap targetCmds phonyTargets = error ".PHONY targets may not have commands!"
  | not $ null missingPhonies = error $ "missing .PHONY targets: " ++ show missingPhonies
  | otherwise =
    Makefile
    { makefileTargets = regularTargets
    , makefilePhonies = phonies
    }
  where
    missingPhonies = S.toList $ S.fromList phonies `S.difference` outputPathsSet
    outputPathsSet = S.fromList (concatMap targetOutputPaths regularTargets)
    phonies = concatMap getPhonyInputs phonyTargets
    getPhonyInputs (Target [".PHONY"] inputs [] []) = inputs
    getPhonyInputs t = error $ "Invalid .PHONY target: " ++ show t
    (phonyTargets, regularTargets) = partition ((".PHONY" `elem`) . targetOutputPaths) targets

properEof :: Parser ()
properEof = do
  P.eof
  posStack <- P.getState
  case posStack of
    [] -> return ()
    _ -> fail "EOF but includers still pending"

isAlphaEx :: Char -> Bool
isAlphaEx x = isAlpha x || x == '_'

isAlphaNumEx :: Char -> Bool
isAlphaNumEx x = isAlphaNum x || x == '_'

setVariable :: Parser ()
setVariable = do
  varName <- P.try $ ident <* P.char '='
  value <- interpolateString variable
  lift $ State.modify (M.insert varName value)

makefile :: Parser Makefile
makefile =
  mkMakefile . concat <$>
  ( beginningOfLine *> -- due to beginning of file
    noiseLines *>
    ( ( ((: []) <$> target) <|>
        ([] <$ setVariable)
      ) `sepBy` (newline *> noiseLines)
    ) <*
    P.optional (newline *> noiseLines) <*
    properEof
  )

parseMakefile :: FilePath -> IO Makefile
parseMakefile makefileName = do
  parseAction <- parseFromFile makefile makefileName
  res <- evalStateT parseAction M.empty
  case res of
    Right x -> return x
    Left err -> do
      hPutStrLn stderr $ showErr err
      fail "Makefile parse failure"
