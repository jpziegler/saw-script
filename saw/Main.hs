{- |
Module      : Main
Description :
License     : BSD3
Maintainer  : atomb
Stability   : provisional
-}
module Main where

import Control.Exception
import Control.Monad
import Data.Maybe
import Data.List

import System.IO
import System.Console.GetOpt
import System.Environment

import SAWScript.Options
import SAWScript.Utils
import SAWScript.Interpreter (processFile)
import qualified SAWScript.REPL as REPL
import SAWScript.Version (shortVersionText)
import SAWScript.Value (AIGProxy(..))
import SAWScript.Prover.Versions (getZ3Version)
import qualified Data.ABC.GIA as GIA

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  argv <- getArgs
  case getOpt Permute options argv of
    (opts, files, []) -> do
      let opts' = foldl' (flip id) defaultOptions opts
      opts'' <- processEnv opts'
      {- We have two modes of operation: batch processing, handled in
      'SAWScript.ProcessFile', and a REPL, defined in 'SAWScript.REPL'. -}
      case files of
        _ | showVersion opts'' -> hPutStrLn stderr shortVersionText
        _ | showHelp opts'' -> err opts'' (usageInfo header options)
        [] -> checkZ3Version opts'' *> REPL.run opts''
        _ | runInteractively opts'' -> checkZ3Version opts'' *> REPL.run opts''
        [file] -> checkZ3Version opts'' *>
          processFile (AIGProxy GIA.proxy) opts'' file `catch`
          (\(ErrorCall msg) -> err opts'' msg)
        (_:_) -> err opts'' "Multiple files not yet supported."
    (_, _, errs) -> do hPutStrLn stderr (concat errs ++ usageInfo header options)
                       exitProofUnknown
  where header = "Usage: saw [OPTION...] [-I | file]"
        checkZ3Version opts = do
          z3 <- getZ3Version
          unless (isJust z3)
            $ err opts "Error: z3 is required to run SAW, but it was not found on the system path."
        err opts msg = do
          when (verbLevel opts >= Error)
            (hPutStrLn stderr msg)
          exitProofUnknown
