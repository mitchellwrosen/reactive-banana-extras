{-# language LambdaCase          #-}
{-# language RecordWildCards     #-}
{-# language RecursiveDo         #-}
{-# language ScopedTypeVariables #-}

module Reactive.Banana.Vty where

import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (forever)
import Data.ByteString (ByteString)
import Reactive.Banana
import Reactive.Banana.Frameworks

import qualified Graphics.Vty as Vty

data VtyInput = VtyInput
  { eKey :: Event (Vty.Key, [Vty.Modifier])
  , eMouseDown :: Event (Int, Int, Vty.Button, [Vty.Modifier])
  , eMouseUp :: Event (Int, Int, Maybe Vty.Button)
  , eResize :: Event (Int, Int)
  , ePaste :: Event ByteString
  , eLostFocus :: Event ()
  , eGainedFocus :: Event ()
  }

type VtyOutput
  = Behavior (Maybe Vty.Picture)

vtyMoment :: Vty.Config -> (VtyInput -> MomentIO VtyOutput) -> IO ()
vtyMoment config moment = do
  vty :: Vty.Vty <-
    Vty.mkVty config

  doneVar :: TMVar () <-
    newEmptyTMVarIO

  (keyAh,         fireKey)         <- newAddHandler
  (mouseDownAh,   fireMouseDown)   <- newAddHandler
  (mouseUpAh,     fireMouseUp)     <- newAddHandler
  (resizeAh,      fireResize)      <- newAddHandler
  (pasteAh,       firePaste)       <- newAddHandler
  (lostFocusAh,   fireLostFocus)   <- newAddHandler
  (gainedFocusAh, fireGainedFocus) <- newAddHandler

  network :: EventNetwork <-
    compile $ do
      eKey         <- fromAddHandler keyAh
      eMouseDown   <- fromAddHandler mouseDownAh
      eMouseUp     <- fromAddHandler mouseUpAh
      eResize      <- fromAddHandler resizeAh
      ePaste       <- fromAddHandler pasteAh
      eLostFocus   <- fromAddHandler lostFocusAh
      eGainedFocus <- fromAddHandler gainedFocusAh

      bPicture :: Behavior (Maybe Vty.Picture) <-
        moment (VtyInput {..})

      ePicture :: Event (Future (Maybe Vty.Picture)) <-
        changes bPicture

      let output :: Maybe Vty.Picture -> IO ()
          output = \case
            Nothing -> do
              _ <- atomically (tryPutTMVar doneVar ())
              pure ()
            Just picture -> Vty.update vty picture

      liftIO . output =<< valueB bPicture
      reactimate' (fmap output <$> ePicture)

  actuate network

  eventQueue :: TQueue Vty.Event <-
    newTQueueIO

  let worker :: IO ()
      worker = forever $ do
        event <- Vty.nextEvent vty
        atomically (writeTQueue eventQueue event)

  let loop :: IO ()
      loop = do
        result <-
          atomically $
            Left <$> takeTMVar doneVar <|>
            Right <$> readTQueue eventQueue

        case result of
          Left () -> pure ()
          Right event -> do
            case event of
              Vty.EvKey a b -> fireKey (a, b)
              Vty.EvMouseDown a b c d -> fireMouseDown (a, b, c, d)
              Vty.EvMouseUp a b c -> fireMouseUp (a, b, c)
              Vty.EvResize a b -> fireResize (a, b)
              Vty.EvPaste a -> firePaste a
              Vty.EvLostFocus -> fireLostFocus ()
              Vty.EvGainedFocus -> fireGainedFocus ()
            loop

  withAsync worker (\_ -> loop) `finally` Vty.shutdown vty
