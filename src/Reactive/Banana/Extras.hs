{-# language DeriveFunctor       #-}
{-# language InstanceSigs        #-}
{-# language LambdaCase          #-}
{-# language RankNTypes          #-}
{-# language RecursiveDo         #-}
{-# language ScopedTypeVariables #-}

module Reactive.Banana.Extras
  ( -- * Varying
    Varying(..)
    -- * Event
    -- ** Core combinators
  , pushE
  , delayE
  , applyE
  , intersectE
  , onceE
    -- ** Accumulation
  , concatE
  , amassE
  , accrueE
  , scanE
  , siftE
  , scryE
  , tripE
  , tourE
  , trekE
    -- *** Common accumulators
  , countE
  , sumE
  , orE
  , andE
  , maximumE
  , minimumE
    -- ** Batching
  , consecutiveE
  , batchE
    -- ** Filtering
  , distillE
  , takeE
  , dropE
  , isJustE
  , isNothingE
  , isLeftE
  , isRightE
  , isE
  , changedE
  , edgeE
    -- ** First-order switching
  , boolE
  , raceE
    -- ** Debugging
  , traceE
    -- * Behavior
    -- ** Core combinators
  , holdB
    -- ** Accumulation
  , concatB
  , amassB
  , accrueB
  , scanB
  , siftB
  , scryB
    -- *** Common accumulators
  , countB
  , sumB
  , orB
  , andB
  , maximumB
  , minimumB
    -- ** First-order switching
  , boolB
    -- ** Debugging
  , traceB
    -- * Dynamic
  , Dynamic
  , updates
  , current
    -- ** Core combinators
  , applyD
  , promptlyApplyD
    -- ** Accumulation
  , accumD
  , amassD
  , accrueD
  , scanD
  , siftD
  , scryD
    -- ** First-order switching
  , boolD
    -- ** Debugging
  , traceD
  ) where

import Control.Lens (Prism', _Right, preview)
import Control.Monad ((>=>), guard)
import Control.Monad.Fix (MonadFix)
import Data.Bool (bool)
import Data.Maybe (isNothing)
import Data.Monoid ((<>))
import Reactive.Banana hiding ((<@>), (<@))
import Reactive.Banana.Frameworks
import System.IO (hPrint, stderr)
import Unsafe.Coerce (unsafeCoerce)

import qualified Reactive.Banana


--------------------------------------------------------------------------------
-- Varying

class Functor f => Varying f where
  (<@>) :: f (a -> b) -> Event a -> Event b
  (<@) :: f b -> Event a -> Event b
  x <@ y = const <$> x <@> y

infixl 4 <@>
infixl 4 <@

instance Varying Behavior where
  (<@>) = (Reactive.Banana.<@>)
  (<@) = (Reactive.Banana.<@)

instance Varying Dynamic where
  (<@>) :: Dynamic (a -> b) -> Event a -> Event b
  (<@>) = applyD

instance Varying Moment where
  (<@>) :: Moment (a -> b) -> Event a -> Event b
  mf <@> ex = observeE ((\x -> mf <*> pure x) <$> ex)


--------------------------------------------------------------------------------
-- Event

-- | Push each 'Event' occurrence through the given function.
pushE :: (a -> Moment (Maybe b)) -> Event a -> Event b
pushE f e = filterJust (observeE (fmap f e))

-- | Create a delayed 'Event' that emits the previous observed value of the
-- input 'Event', beginning with the given value.
delayE :: MonadMoment m => a -> Event a -> m (Event a)
delayE a ea = do
  ba <- stepper a ea
  pure (ba <@ ea)

-- | Apply a function to a value at the discrete moments in time when both are
-- emitted.
applyE :: Event (a -> b) -> Event a -> Event b
applyE ef ea =
  isRightE
    (unionWith
      (\(Left f) (Left a) -> Right (unsafeCoerce f (unsafeCoerce a)))
      (Left <$> unsafeCoerce ef)
      (Left <$> unsafeCoerce ea))

-- | Intersect two 'Event' streams with the given function. Non-coincident
-- 'Event's are dropped.
intersectE :: (a -> b -> c) -> Event a -> Event b -> Event c
intersectE f ea = applyE (f <$> ea)

-- | Emit only the first occurrence of an 'Event'.
onceE :: MonadMoment m => Event a -> m (Event a)
onceE e = do
  b <- stepper True (False <$ e)
  pure (whenE b e)

-- | Emit the monoidal summary of all events observed so far. The latest event
-- is given as the second argument to 'mconcat', i.e. @acc <> x@.
concatE :: (Monoid a, MonadMoment m) => Event a -> m (Event a)
concatE e = accumE mempty (flip (<>) <$> e)

-- | Like 'accumE', but the accumulator is in the 'Moment' monad.
amassE
  :: (MonadFix m, MonadMoment m)
  => a -> Event (a -> Moment a) -> m (Event a)
amassE a ef = mdo
  let ea = observeE ((\a f -> f a) <$> ba <@> ef)
  ba <- stepper a ea
  pure ea

-- | Like 'accumE', but the accumulator is in the 'MomentIO' monad.
accrueE :: a -> Event (a -> MomentIO a) -> MomentIO (Event a)
accrueE a ef = mdo
  ea <- execute ((\a f -> f a) <$> ba <@> ef)
  ba <- stepper a ea
  pure ea

-- | Variant of 'accumE' that takes a step-function.
scanE :: MonadMoment m => (b -> a -> b) -> b -> Event a -> m (Event b)
scanE f b ea = accumE b (flip f <$> ea)

-- | Like 'scanE', but the step-function is in the 'Moment' monad.
siftE
  :: (MonadFix m, MonadMoment m)
  => (b -> a -> Moment b) -> b -> Event a -> m (Event b)
siftE f b ea = mdo
  let eb = observeE (f <$> bb <@> ea)
  bb <- stepper b eb
  pure eb

-- | Like 'scanE', but the step-function is in the 'MomentIO' monad.
scryE :: (b -> a -> MomentIO b) -> b -> Event a -> MomentIO (Event b)
scryE f b ea = mdo
  eb <- execute (f <$> bb <@> ea)
  bb <- stepper b eb
  pure eb

-- | Variant of 'accumE' that takes a step-function with an internal state.
tripE
  :: (MonadFix m, MonadMoment m)
  => (s -> a -> (s, b)) -> s -> Event a -> m (Event b)
tripE f s ea = mdo
  let esb = f <$> bs <@> ea
  bs <- stepper s (fst <$> esb)
  pure (snd <$> esb)

-- | Like 'tripE', but the step-function is in the 'Moment' monad.
tourE
  :: (MonadFix m, MonadMoment m)
  => (s -> a -> Moment (s, b)) -> s -> Event a -> m (Event b)
tourE f s ea = mdo
  let esb = observeE (f <$> bs <@> ea)
  bs <- stepper s (fst <$> esb)
  pure (snd <$> esb)

-- | Like 'tripE', but the step-function is in the 'MomentIO' monad.
trekE :: (s -> a -> MomentIO (s, b)) -> s -> Event a -> MomentIO (Event b)
trekE f s ea = mdo
  esb <- execute (f <$> bs <@> ea)
  bs <- stepper s (fst <$> esb)
  pure (snd <$> esb)

-- | Emit the number of times the given 'Event' has occurred.
countE :: (Num b, MonadMoment m) => Event a -> m (Event b)
countE e = accumE 0 ((+1) <$ e)

-- | Emit the sum of all 'Event's observed so far.
sumE :: (Num a, MonadMoment m) => Event a -> m (Event a)
sumE e = accumE 0 ((+) <$> e)

-- | Emit the @||@ of all 'Event's observed so far.
orE :: MonadMoment m => Event Bool -> m (Event Bool)
orE = scanE (||) False

-- | Emit the @&&@ of all 'Event's observed so far.
andE :: MonadMoment m => Event Bool -> m (Event Bool)
andE = scanE (&&) True

-- | Emit the new maximum 'Event' observed so far. The first 'Event' is always
-- emitted.
maximumE :: (Ord a, MonadMoment m) => Event a -> m (Event a)
maximumE e = do
  b <- holdB e
  pure (isJustE (f <$> b <@> e))
 where
  f Nothing x = Just x
  f (Just x) y
    | y > x = Just y
    | otherwise = Nothing

-- | Emit the new minimum 'Event' observed so far. The first 'Event' is always
-- emitted.
minimumE :: (Ord a, MonadMoment m) => Event a -> m (Event a)
minimumE e = do
  b <- holdB e
  pure (isJustE (f <$> b <@> e))
 where
  f Nothing x = Just x
  f (Just x) y
    | y < x = Just y
    | otherwise = Nothing

-- | Emit pairs of consecutive events at the moments in time the that second
-- element is emitted.
consecutiveE :: MonadMoment m => Event a -> m (Event (a, a))
consecutiveE ea = do
  ba <- holdB ea
  pure (filterJust (f <$> ba <@> ea))
 where
  f Nothing _ = Nothing
  f (Just a) b = Just (a, b)

-- | Batch @a@s until a @b@ fires, at which point all batched @a@s are emitted
-- in the order they were observed.
batchE :: MonadMoment m => Event b -> Event a -> m (Event [a])
batchE eb ea = do
  bas <-
    accumB [] (unions
      [ const [] <$ eb
      , (:) <$> ea
      ])
  pure (reverse <$> bas <@ eb)

-- | Filter an 'Event' with a predicate 'Behavior'.
distillE :: Behavior (a -> Bool) -> Event a -> Event a
distillE = filterApply

-- | Take the first @n@ occurrences of an 'Event'.
takeE :: MonadMoment m => Int -> Event a -> m (Event a)
takeE 0 _ = pure never
takeE n e = do
  bCount <- countB e
  pure (whenE ((< n) <$> bCount) e)

-- | Drop the first @n@ occurrences of an 'Event'.
dropE :: MonadMoment m => Int -> Event a -> m (Event a)
dropE 0 e = pure e
dropE n e = do
  count <- countE e
  threshold <- onceE (filterE (== n) count)
  switchE (e <$ threshold)

-- | Emit 'Just's and discard 'Nothing's.
isJustE :: Event (Maybe a) -> Event a
isJustE = filterJust

-- | Emit 'Nothing's and discard 'Just's.
isNothingE :: Event (Maybe a) -> Event ()
isNothingE e = () <$ filterE isNothing e

-- | Emit 'Left's and discard 'Right's.
isLeftE :: Event (Either a b) -> Event a
isLeftE = isJustE . fmap f
 where
  f = \case
    Left a -> Just a
    _ -> Nothing

-- | Emit 'Right's and discard 'Left's.
isRightE :: Event (Either a b) -> Event b
isRightE = isJustE . fmap f
 where
  f = \case
    Right a -> Just a
    _ -> Nothing

-- | Emit values that match a 'Prism''.
isE :: Prism' s a -> Event s -> Event a
isE p = isJustE . fmap (preview p)

-- | Emit only values that are not equal to the latest value emitted. The first
-- event is always emitted.
changedE :: (Eq a, MonadMoment m) => Event a -> m (Event a)
changedE e = do
  b <- holdB e
  pure (isJustE (f <$> b <@> e))
 where
  f Nothing a = Just a
  f (Just x) a = a <$ guard (x /= a)

-- | Emit rising edges (when 'False' becomes 'True').
edgeE :: MonadMoment m => Event Bool -> m (Event ())
edgeE eb = do
  eb' <- consecutiveE eb
  pure (() <$ filterE (\(x, y) -> not x && y) eb')

-- | When the given 'Behavior' is 'False', act as the first 'Event', else act as
-- the second 'Event' (the argument order mimics 'Data.Bool.bool').
boolE :: Event a -> Event a -> Behavior Bool -> Event a
boolE ef et bb = unionWith const (whenE bb et) (whenE (not <$> bb) ef)

-- | Race two 'Event's, returning the 'Event' whose first occurrence occurs
-- first. If both first events occur simultaneously, the left one is returned.
raceE :: MonadMoment m => Event a -> Event a -> m (Event a)
raceE eThis eThat = do
  let eThese = theseE eThis eThat

  eFirst <- onceE eThese

  let eWhich :: Event Bool
      eWhich =
        (\case
          This _ -> True
          That _ -> False
          These _ _ -> True)
        <$> eFirst

  bWhich :: Behavior (Maybe Bool) <-
    holdB eWhich

  pure (isJustE (f <$> bWhich <@> eThese))

 where
  f Nothing (This x) = Just x
  f Nothing (That x) = Just x
  f Nothing (These x _) = Just x
  f (Just True) (This x) = Just x
  f (Just True) (That _) = Nothing
  f (Just True) (These x _) = Just x
  f (Just False) (This _) = Nothing
  f (Just False) (That x) = Just x
  f (Just False) (These _ x) = Just x

-- | Trace 'Event' occurrences on @stderr@.
traceE :: Show a => Event a -> MomentIO ()
traceE e = reactimate (hPrint stderr <$> e)

--------------------------------------------------------------------------------
-- Behavior

-- | Hold the latest value emitted by an 'Event'.
holdB :: MonadMoment m => Event a -> m (Behavior (Maybe a))
holdB = stepper Nothing . fmap Just

-- | Hold the monoidal summary of all events observed so far. The latest event
-- is given as the second argument to 'mconcat', i.e. @acc <> x@.
concatB :: (Monoid a, MonadMoment m) => Event a -> m (Behavior a)
concatB e = accumB mempty (flip (<>) <$> e)

-- | Like 'accumB', but the accumulator is in the 'Moment' monad.
amassB
  :: (MonadFix m, MonadMoment m)
  => a -> Event (a -> Moment a) -> m (Behavior a)
amassB a ef = mdo
  let ea = observeE ((\a f -> f a) <$> ba <@> ef)
  ba <- stepper a ea
  pure ba

-- | Like 'accumB', but the accumulator is in the 'MomentIO' monad.
accrueB :: a -> Event (a -> MomentIO a) -> MomentIO (Behavior a)
accrueB a ef = mdo
  ea <- execute ((\a f -> f a) <$> ba <@> ef)
  ba <- stepper a ea
  pure ba

-- | Variant of 'accumB' that takes a step-function.
scanB :: MonadMoment m => (b -> a -> b) -> b -> Event a -> m (Behavior b)
scanB f b ea = accumB b (flip f <$> ea)

-- | Like 'scanB', but the step-function is in the 'Moment' monad.
siftB
  :: (MonadFix m, MonadMoment m)
  => (b -> a -> Moment b) -> b -> Event a -> m (Behavior b)
siftB f b ea = mdo
  let eb = observeE (f <$> bb <@> ea)
  bb <- stepper b eb
  pure bb

-- | Like 'scanB', but the step-function is in the 'MomentIO' monad.
scryB :: (b -> a -> MomentIO b) -> b -> Event a -> MomentIO (Behavior b)
scryB f b ea = mdo
  eb <- execute (f <$> bb <@> ea)
  bb <- stepper b eb
  pure bb

-- | Hold the number of times the given 'Event' has occurred.
countB :: (Num b, MonadMoment m) => Event a -> m (Behavior b)
countB e = accumB 0 ((+1) <$ e)

-- | Hold the sum of all 'Event's observed so far.
sumB :: (Num a, MonadMoment m) => Event a -> m (Behavior a)
sumB e = accumB 0 ((+) <$> e)

-- | Hold the @||@ of all 'Event's observed so far.
orB :: MonadMoment m => Event Bool -> m (Behavior Bool)
orB = scanB (||) False

-- | Hold the @&&@ of all 'Event's observed so far.
andB :: MonadMoment m => Event Bool -> m (Behavior Bool)
andB = scanB (&&) True

-- | Hold the maximum 'Event' observed so far, or 'minBound' if no 'Event' has
-- been observed.
maximumB :: (Bounded a, Ord a, MonadMoment m) => Event a -> m (Behavior a)
maximumB = maximumE >=> stepper minBound

-- | Hold the minimum 'Event' observed so far, or 'maxBound' if no 'Event' has
-- been observed.
minimumB :: (Bounded a, Ord a, MonadMoment m) => Event a -> m (Behavior a)
minimumB = minimumE >=> stepper maxBound

-- | When the given 'Behavior' is 'False', act as the first 'Behavior', else act
-- as the second 'Behavior' (the argument order mimics 'Data.Bool.bool').
boolB :: Behavior a -> Behavior a -> Behavior Bool -> Behavior a
boolB bf bt bb = bool <$> bf <*> bt <*> bb

-- | Trace 'Behavior' changes (including the initial value) on @stderr@.
traceB :: Show a => Behavior a -> MomentIO ()
traceB b = do
  x <- valueB b
  liftIO (hPrint stderr x)
  e <- changes b
  reactimate' (fmap (hPrint stderr) <$> e)

--------------------------------------------------------------------------------
-- Dynamic

-- | A 'Dynamic' is a 'Behavior' paired with the 'Event' that updates it.
data Dynamic a
  = Dynamic (Event a) (Behavior a)
  deriving Functor

instance Applicative Dynamic where
  pure x = Dynamic never (pure x)
  liftA2 f (Dynamic e1 b1) (Dynamic e2 b2) = Dynamic e b where
    e1b2 = flip (,) <$> b2 <@> e1
    b1e2 = (,) <$> b1 <@> e2
    d1d2 = unionWith (\(p, _) (_, q) -> (p, q)) e1b2 b1e2
    e = uncurry f <$> d1d2
    b = f <$> b1 <*> b2
  Dynamic e1 _ *> Dynamic e2 b2 = Dynamic e b2 where
    e = unionWith const e2 (b2 <@ e1)
  Dynamic e1 b1 <* Dynamic e2 _ = Dynamic e b1 where
    e = unionWith const e1 (b1 <@ e2)

-- | Get the 'Event' of a 'Dynamic'.
updates :: Dynamic a -> Event a
updates (Dynamic e _) = e

-- | Get the 'Behavior' of a 'Dynamic'.
current :: Dynamic a -> Behavior a
current (Dynamic _ b) = b

applyD :: Dynamic (a -> b) -> Event a -> Event b
applyD df ea = current df <@> ea

-- | Apply a 'Dynamic' function to an 'Event'. Unlike 'apply', in the case the
-- underlying 'Behavior' is stepping in this moment, the *new* value will be
-- used, and thus this is not suitable for value-recursion.
promptlyApplyD :: Dynamic (a -> b) -> Event a -> Event b
promptlyApplyD df ea =
  let
    e1 = Left <$> updates df
    e2 = Right . Left <$> ea
    e3 = unionWith (\(Left f) (Right (Left a)) -> Right (Right (f a))) e1 e2
    e4 = isE (_Right . _Right) e3
  in
    unionWith const e4 (current df <@> ea)
-- FIXME: Would be nice to use something like 'mergeWith' here, see
-- https://github.com/HeinrichApfelmus/reactive-banana/issues/158

-- | Like 'accumB', but for 'Dynamic's.
accumD
  :: MonadMoment m
  => a -> Event (a -> a) -> m (Dynamic a)
accumD a ef = do
  ea <- accumE a ef
  ba <- stepper a ea
  pure (Dynamic ea ba)

-- | Like 'amassB', but for 'Dynamic's.
amassD
  :: (MonadFix m, MonadMoment m)
  => a -> Event (a -> Moment a) -> m (Dynamic a)
amassD a ef = mdo
  let ea = observeE ((\a f -> f a) <$> ba <@> ef)
  ba <- stepper a ea
  pure (Dynamic ea ba)

-- | Like 'accrueB', but for 'Dynamic's.
accrueD :: a -> Event (a -> MomentIO a) -> MomentIO (Dynamic a)
accrueD a ef = mdo
  ea <- execute ((\a f -> f a) <$> ba <@> ef)
  ba <- stepper a ea
  pure (Dynamic ea ba)

-- | Like 'scanB', but for 'Dynamic's.
scanD :: MonadMoment m => (b -> a -> b) -> b -> Event a -> m (Dynamic b)
scanD f b ea = do
  eb <- scanE f b ea
  bb <- stepper b eb
  pure (Dynamic eb bb)

-- | Like 'siftB', but for 'Dynamic's.
siftD
  :: (MonadFix m, MonadMoment m)
  => (b -> a -> Moment b) -> b -> Event a -> m (Dynamic b)
siftD f b ea = mdo
  let eb = observeE (f <$> bb <@> ea)
  bb <- stepper b eb
  pure (Dynamic eb bb)

-- | Like 'scryB', but for 'Dynamic's.
scryD :: (b -> a -> MomentIO b) -> b -> Event a -> MomentIO (Dynamic b)
scryD f b ea = mdo
  eb <- execute (f <$> bb <@> ea)
  bb <- stepper b eb
  pure (Dynamic eb bb)

-- | Like 'boolB', but for 'Dynamic's.
boolD :: Dynamic a -> Dynamic a -> Behavior Bool -> Dynamic a
boolD (Dynamic ef bf) (Dynamic et bt) bb =
  Dynamic (boolE ef et bb) (boolB bf bt bb)

-- | Trace 'Dynamic' changes (including the initial value) on @stderr@.
traceD :: Show a => Dynamic a -> MomentIO ()
traceD d = do
  x <- valueB (current d)
  liftIO (hPrint stderr x)
  traceE (updates d)

--------------------------------------------------------------------------------
-- Internal

theseE :: Event a -> Event b -> Event (These a b)
theseE e1 e2 =
  unionWith (\(This a) (That b) -> These a b) (This <$> e1) (That <$> e2)

data These a b
  = This a
  | That b
  | These a b

--------------------------------------------------------------------------------
-- TODO?

{-
switchFromB :: Behavior a -> Event (a -> Moment (Behavior a)) -> m (Behavior a)
switchFromB = undefined
-}
