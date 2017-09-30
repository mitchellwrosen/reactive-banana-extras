{-# language DeriveFunctor              #-}
{-# language GADTs                      #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# options_ghc -fno-warn-orphans       #-}

module Reactive.Banana.Instant
  ( Instant
  , liftMomentIO
    -- ** Combinators
  , ievent
  , ibehavior
  , iaccumE
  , istepper
    -- ** Frameworks
  , ifromAddHandler
  , icompile
  ) where

import Control.Monad.Fix
import Control.Monad.Reader
import Data.IORef
import Data.Default.Class
import Data.Dependent.Map (DMap)
import Data.GADT.Compare
import Data.Maybe
import Reactive.Banana
import Reactive.Banana.Frameworks
import System.IO.Unsafe (unsafeInterleaveIO)
import Type.Reflection

import qualified Data.Dependent.Map as DMap

data Env = Env
  { envE :: IORef (DMap TypeRep Event)
  , envB :: IORef (DMap TypeRep Behavior)
  }

-- | An 'Instant' is similar to 'MonadIO', but allows you to generate
-- globally-shared 'Event's and 'Behavior's indexed by their 'TypeRep'.
newtype Instant a
  = Instant (ReaderT Env MomentIO a)
  deriving (Functor, Applicative, Monad, MonadFix, MonadIO)

instance MonadMoment Instant where
  liftMoment = Instant . lift . liftMoment

liftMomentIO :: MomentIO a -> Instant a
liftMomentIO = Instant . lift

insertEvent :: Typeable a => Event a -> Instant ()
insertEvent e = Instant $ do
  ref <- asks envE
  liftIO (modifyIORef ref (DMap.insert typeRep e))

insertBehavior :: Typeable a => Behavior a -> Instant ()
insertBehavior b = Instant $ do
  ref <- asks envB
  liftIO (modifyIORef ref (DMap.insert typeRep b))


--------------------------------------------------------------------------------
-- Combinators

-- | Look up the unique 'Event' with type @a@.
ievent :: Typeable a => Instant (Event a)
ievent = Instant $ do
  eventsRef <- asks envE

  liftIO
    (fromMaybe never . DMap.lookup typeRep <$>
      unsafeInterleaveIO (readIORef eventsRef))

-- | Look up the unique 'Behavior' with type @a@.
ibehavior :: (Default a, Typeable a) => Instant (Behavior a)
ibehavior = Instant $ do
  behaviorsRef <- asks envB

  liftIO
    (fromMaybe (pure def) . DMap.lookup typeRep <$>
      unsafeInterleaveIO (readIORef behaviorsRef))

iaccumE :: Typeable a => a -> Event (a -> a) -> Instant (Event a)
iaccumE e es = do
  e' <- accumE e es
  insertEvent e'
  pure e'

-- | Create a unique 'Behavior' with type @a@, accessible by 'behaviorI'.
istepper :: Typeable a => a -> Event a -> Instant (Behavior a)
istepper e es = do
  b <- stepper e es
  insertBehavior b
  pure b


--------------------------------------------------------------------------------
-- Frameworks

ifromAddHandler :: Typeable a => AddHandler a -> Instant (Event a)
ifromAddHandler ah = do
  e <- liftMomentIO (fromAddHandler ah)
  insertEvent e
  pure e

icompile :: Instant () -> IO EventNetwork
icompile (Instant m) = do
  env <- Env
    <$> newIORef DMap.empty
    <*> newIORef DMap.empty
  compile (runReaderT m env)


--------------------------------------------------------------------------------
-- Orphans

instance GEq TypeRep where
  geq t1 t2 =
    case eqTypeRep t1 t2 of
      Nothing -> Nothing
      Just HRefl -> Just Refl

instance GCompare TypeRep where
  gcompare t1 t2 =
    case geq t1 t2 of
      Nothing ->
        case compare (SomeTypeRep t1) (SomeTypeRep t2) of
          LT -> GLT
          EQ -> undefined -- impossible
          GT -> GGT
      Just Refl -> GEQ
