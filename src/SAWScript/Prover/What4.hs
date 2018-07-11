{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GADTs #-}

module SAWScript.Prover.What4 where

import qualified Data.Vector as V
import qualified Data.Map as Map
import           Control.Monad(filterM)
import           Data.Maybe (catMaybes)

import Verifier.SAW.SharedTerm
import Verifier.SAW.FiniteValue

import Verifier.SAW.TypedTerm(TypedTerm(..), mkTypedTerm)
import Verifier.SAW.Recognizer(asPi)

import           SAWScript.Prover.Rewrite(rewriteEqs)
import           SAWScript.Prover.Mode(ProverMode(..))
import           SAWScript.Prover.SolverStats
import           SAWScript.Prover.Util

import Data.Parameterized.Nonce

import           What4.Config
import           What4.Solver
import           What4.SatResult
import           What4.Interface
import           What4.BaseTypes
import           What4.Expr.GroundEval
import qualified What4.Solver.Z3 as Z3
import qualified Verifier.SAW.Simulator.What4 as W
import           Verifier.SAW.Simulator.What4.FirstOrder
import qualified What4.Expr.Builder as B

-- import System.IO

-- This class allows the "sim" argument to be passed implicitly,
-- allowing the What4 module to make an instance of the 'SymbolicValue' class.
import           Data.Reflection(Given(..),give)




----------------------------------------------------------------

-- TODO: runST version instead of the GlobalNonceGenerator    
type Gt = GlobalNonceGenerator

data St g = St

type SYM = B.ExprBuilder GlobalNonceGenerator St



prepWhat4 :: forall sym. (Given sym, IsSymExprBuilder sym) =>
  SharedContext -> [String] -> Term ->
  IO (Term, [String], ([Maybe (W.Labeler sym)],Pred sym))
prepWhat4 sc unints t0 = do
  -- Abstract over all non-function ExtCns variables
  let nonFun e = fmap ((== Nothing) . asPi) (scWhnf sc (ecType e))
  exts <- filterM nonFun (getAllExts t0)

  TypedTerm schema t' <-
      scAbstractExts sc exts t0 >>= rewriteEqs sc >>= mkTypedTerm sc

  checkBooleanSchema schema
  
  (argNames, lit) <- W.w4Solve sc Map.empty unints t'

  return (t', argNames, lit)

  
-- | Check the satisfiability of a theorem using What4.
satWhat4 ::
  SharedContext {- ^ Context for working with terms -} ->
  ProverMode    {- ^ Prove/check -} ->
  Term          {- ^ A boolean term to be proved/checked. -} ->
  IO (Maybe [(String,FirstOrderValue)], SolverStats)
  -- ^ (example/counter-example, solver statistics)
satWhat4 sc mode term = 
  do
     let gen = globalNonceGenerator
     sym <- B.newExprBuilder St gen

     let cfg = getConfiguration sym
     extendConfig (solver_adapter_config_options Z3.z3Adapter) cfg
     
     -- symbolically evaluate
     (t', argNames, iolit0) <- give sym $ prepWhat4 sc [] term

     let (bvs,lit0) = iolit0

       -- lit :: Pred sym === Expr sym BoolType
     lit <- case mode of
              CheckSat -> return lit0
              Prove    -> notPred sym lit0

     -- dummy stats
     let stats = solverStats "What4->Z3" (scSharedSize t')

     -- log to stdout
     let logger _ str = putStr str

     -- dump Z3 file (for debugging)
     -- handle <- openFile "/Users/sweirich/dump.txt" WriteMode 
     -- solver_adapter_write_smt2 Z3.z3Adapter sym handle lit 
     -- hClose handle
     
     -- runZ3
     Z3.runZ3InOverride sym logger lit $ \ result -> case result of 
         Sat (gndEvalFcn,_) -> do
           mvals <- mapM (getValues @SYM gndEvalFcn) (zip bvs argNames)
           return (Just (catMaybes mvals), stats) where

         Unsat   -> return (Nothing, stats)
         Unknown -> fail "Prover returned Unknown"

getValues :: forall sym gt. (SymExpr sym ~ B.Expr gt) => GroundEvalFn gt ->
  (Maybe (W.Labeler sym), String) -> IO (Maybe (String, FirstOrderValue))
getValues _ (Nothing, _) = return Nothing
getValues f (Just labeler, orig) = do
  fov <- getLabelValues f labeler
  return $ Just (orig,fov)
  

getLabelValues :: forall sym gt. (SymExpr sym ~ B.Expr gt) => GroundEvalFn gt ->
  W.Labeler sym -> IO FirstOrderValue
  
getLabelValues f (W.TupleLabel labels) = do
  vals <- mapM (getLabelValues f) (V.toList labels)
  return (FOVTuple vals)

getLabelValues f (W.VecLabel labels) = do
  let vty = error "TODO: compute vector type, or just store it"
  vals <- mapM (getLabelValues f) (V.toList labels)
  return (FOVVec vty vals)

getLabelValues f (W.RecLabel m) = do
  m' <- mapM (getLabelValues f) m
  return (FOVRec m')
  
getLabelValues f (W.BaseLabel (W.TypedExpr ty bv)) = do
  gv <- groundEval f bv
  case (groundToFOV ty gv) of
    Left err  -> fail err
    Right fov -> return fov



printValue :: SYM -> GroundEvalFn Gt -> (Maybe (W.TypedExpr SYM), String) -> IO ()
printValue _ _ (Nothing, _) = return ()
printValue _ f (Just (W.TypedExpr (ty :: BaseTypeRepr ty) (bv :: B.Expr Gt ty)), orig) = do
  gv <- groundEval f @ty bv
  putStr $ orig ++ "=?"
  print (groundToFOV ty gv)

