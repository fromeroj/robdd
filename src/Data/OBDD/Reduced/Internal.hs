{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE Rank2Types #-}
module Data.OBDD.Reduced.Internal where

import Prelude hiding (not, and, or, const)
import qualified Prelude
import Data.Map (Map, (!))
import qualified Data.Map as Map
import Control.Applicative
import Control.Monad.State

newtype Var = Var Int
  deriving (Eq, Ord, Show)

-- The p parameter ensures that we always deal with 'Id's from the same pool
newtype Id p = Id Int
  deriving (Eq, Ord)

type IdPool p = Map (Var, Id p, Id p) (Id p)

newtype RobddM p a = RobddM (State (IdPool p) a)
  deriving (Functor, Applicative, Monad, MonadState (IdPool p))

runRobddM :: forall a. (forall p. RobddM p a) -> a
runRobddM (RobddM s) = evalState s Map.empty

type RefPool p = Map (Id p) (Robdd p)
type RefPoolM p a = StateT (RefPool p) (RobddM p) a

data BranchType = Orig | Ref
  deriving (Eq, Ord, Show)

data Robdd p
  = Branch BranchType (Id p) Var (Robdd p) (Robdd p)
  | Leaf Bool
  deriving Eq

getId :: Robdd p -> Id p
getId (Branch _ i _ _ _) = i
getId (Leaf False)       = Id 0
getId (Leaf True)        = Id 1

instance Show (Robdd p) where
  show (Leaf False)                    = "F"
  show (Leaf True)                     = "T"
  show (Branch t (Id i) (Var v) lo hi) = showType t ++ "#" ++ show i ++ " "
                                      ++ show v
                                      ++ " (" ++ show lo ++ ")"
                                      ++ " (" ++ show hi ++ ")"
    where
      showType Orig = "Branch"
      showType Ref  = "Ref"

varM :: Int -> RobddM p (Robdd p)
varM x = evalStateT (branch (Var x) (Leaf False) (Leaf True)) Map.empty

apply :: (Bool -> Bool -> Bool) -> Robdd p -> Robdd p -> RobddM p (Robdd p)
apply f a b = evalStateT (go a b) Map.empty
  where
    go :: Robdd p -> Robdd p -> RefPoolM p (Robdd p)
    go x@(Branch _ _ xv xlo xhi) y@(Branch _ _ yv ylo yhi)
      | xv < yv                  = branchM xv (go xlo y)   (go xhi y)
      | yv < xv                  = branchM yv (go x   ylo) (go x   yhi)
      | otherwise                = branchM xv (go xlo ylo) (go xhi yhi)
    go x (Branch _ _ yv ylo yhi) = branchM yv (go x   ylo) (go x   yhi)
    go (Branch _ _ xv xlo xhi) y = branchM xv (go xlo y)   (go xhi y)
    go (Leaf x) (Leaf y)         = return . Leaf $ f x y

branchM :: Var -> RefPoolM p (Robdd p) -> RefPoolM p (Robdd p) -> RefPoolM p (Robdd p)
branchM v loM hiM = do
  lo <- loM
  hi <- hiM
  branch v lo hi

restrict :: Var -> Bool -> Robdd p -> RobddM p (Robdd p)
restrict variable value robdd = evalStateT (go robdd) Map.empty
  where
    go (Branch _ _ v lo hi)
      | v < variable = branchM v (go lo) (go hi)
      | v > variable = branchM v (rebuild lo) (rebuild hi)
      | value        = rebuild hi
      | otherwise    = rebuild lo
    go x = return x

rebuild :: Robdd p -> RefPoolM p (Robdd p)
rebuild (Branch _ _ v lo hi) = branch v lo hi
rebuild x                    = return x

nextId :: RobddM p (Id p)
nextId = do
  pool <- get
  return . Id $ 2 + Map.size pool

branch :: Var -> Robdd p -> Robdd p -> RefPoolM p (Robdd p)
branch v lo hi
  | lo `equals` hi = return lo
  | otherwise      = do
      idPool <- lift get
      case Map.lookup key idPool of
        Just i  -> get >>= maybe (newBranch i) return . Map.lookup i
        Nothing -> lift nextId >>= newBranch
  where
    key = (v, getId lo, getId hi)

    newBranch i = do
      lift . modify $ Map.insert key i
      let origBranch = Branch Orig i v lo hi
          refBranch  = Branch Ref  i v lo hi
      modify $ Map.insert i refBranch
      return origBranch

const :: Bool -> Robdd p
const = Leaf

notM :: Robdd p -> RobddM p (Robdd p)
notM = (`xorM` (const True))

andM :: Robdd p -> Robdd p -> RobddM p (Robdd p)
andM = apply (&&)

orM :: Robdd p -> Robdd p -> RobddM p (Robdd p)
orM = apply (||)

xorM :: Robdd p -> Robdd p -> RobddM p (Robdd p)
xorM = apply (/=)

iffM :: Robdd p -> Robdd p -> RobddM p (Robdd p)
iffM = apply (==)

implM :: Robdd p -> Robdd p -> RobddM p (Robdd p)
implM = apply (\x y -> Prelude.not x || y)

data Expr
  = EConst Bool
  | EVar   Int
  | ENot   Expr
  | EAnd   Expr Expr
  | EOr    Expr Expr
  | EXor   Expr Expr
  | EIff   Expr Expr
  | EImpl  Expr Expr
  deriving (Eq, Show)

true :: Expr
true = EConst True

false :: Expr
false = EConst False

var :: Int -> Expr
var = EVar

not :: Expr -> Expr
not = ENot

and :: Expr -> Expr -> Expr
and = EAnd

or :: Expr -> Expr -> Expr
or = EOr

xor :: Expr -> Expr -> Expr
xor = EXor

iff :: Expr -> Expr -> Expr
iff = EIff

impl :: Expr -> Expr -> Expr
impl = EImpl

reduce :: Expr -> RobddM p (Robdd p)
reduce (EConst x)   = return $ const x
reduce (EVar   x)   = varM x
reduce (ENot   x)   = reduce x >>= notM
reduce (EAnd   x y) = binary andM  x y
reduce (EOr    x y) = binary orM   x y
reduce (EXor   x y) = binary xorM  x y
reduce (EIff   x y) = binary iffM  x y
reduce (EImpl  x y) = binary implM x y

binary :: (Robdd p -> Robdd p -> RobddM p (Robdd p)) -> Expr -> Expr -> RobddM p (Robdd p)
binary f x y = do
  x' <- reduce x
  y' <- reduce y
  f x' y'

exists :: Var -> Robdd p -> RobddM p Bool
exists v x = isTautology <$> do
  xT <- restrict v True  x
  xF <- restrict v False x
  orM xT xF

forall :: Var -> Robdd p -> RobddM p Bool
forall v x = isTautology <$> do
  xT <- restrict v True  x
  xF <- restrict v False x
  andM xT xF

equals :: Robdd p -> Robdd p -> Bool
equals x y = getId x == getId y

isTautology :: Robdd p -> Bool
isTautology = (`equals` (const True))

isContradiction :: Robdd p -> Bool
isContradiction = (`equals` (const False))

fold :: forall a p. (Var -> a -> a -> a) -> a -> a -> Robdd p -> a
fold f z0 z1 robdd = evalState (go robdd) Map.empty
  where
    go :: Robdd p -> State (Map (Id p) a) a
    go (Leaf False)            = return z0
    go (Leaf True)             = return z1
    go (Branch Ref i _ _ _)    = get >>= return . (! i)
    go (Branch Orig i v lo hi) = do
      result <- f v <$> go lo <*> go hi
      modify $ Map.insert i result
      return result

type Binding = Map Var Bool

evaluate :: Binding -> Robdd p -> Bool
evaluate env = fold f False True
  where
    f i lo hi = case Map.lookup i env of
      Just False -> lo
      Just True  -> hi
      Nothing    -> error "evaluate: incorrect binding"

anySat :: Robdd p -> Maybe Binding
anySat = fold f Nothing (Just Map.empty)
  where
    f i lo hi = Map.insert i False <$> lo
            <|> Map.insert i True  <$> hi

allSat :: Robdd p -> [Binding]
allSat = fold f [] [Map.empty]
  where
    f i lo hi = map (Map.insert i False) lo
             ++ map (Map.insert i True)  hi
