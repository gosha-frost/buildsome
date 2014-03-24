{-# LANGUAGE DeriveGeneric, OverloadedStrings #-}
module Lib.StdOutputs
  ( StdOutputs(..)
  , printStdouts
  ) where

import Data.Binary (Binary)
import Data.ByteString (ByteString)
import Data.Monoid
import GHC.Generics (Generic)
import qualified Data.ByteString.Char8 as BS8

data StdOutputs = StdOutputs
  { _stdOut :: ByteString
  , _stdErr :: ByteString
  } deriving (Generic, Show)
instance Binary StdOutputs

printStdouts :: String -> StdOutputs -> IO ()
printStdouts strLabel (StdOutputs stdout stderr) = do
  showOutput ("STDOUT" <> plabel) stdout
  showOutput ("STDERR" <> plabel) stderr
  where
    plabel = "(" <> BS8.pack strLabel <> ")"
    showOutput name bs
      | BS8.null bs = return ()
      | otherwise =
        BS8.putStrLn $ mconcat
        [ name, ":\n"
        , BS8.intercalate "\n" $ BS8.lines bs
        ]
