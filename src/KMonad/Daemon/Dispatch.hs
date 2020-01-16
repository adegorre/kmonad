module KMonad.Daemon.Dispatch
  ( Dispatch
  , HasDispatch
  , dispatch
  , mkDispatch
  , pull
  , rerun
  , captureInput
  , releaseInput
  )
where

import Prelude

import KMonad.Keyboard
import KMonad.Util

import RIO.Seq (Seq(..), (><))
import qualified RIO.Text as T (replicate)
import qualified RIO.Seq as Seq


--------------------------------------------------------------------------------
-- $env
--
--


data Dispatch = Dispatch
  { _rerunBuf :: IORef (Seq KeyEvent)
  , _redirect :: IORef (Maybe (KeyEvent -> IO ()))
  }
makeClassy ''Dispatch

mkDispatch' :: RIO e Dispatch
mkDispatch' = do
  rrb <- newIORef $ Seq.empty
  rdr <- newIORef $ Nothing
  pure $ Dispatch rrb rdr

mkDispatch :: ContT r (RIO e) Dispatch
mkDispatch = lift mkDispatch'

-- | Try to read a KeyEvent.
--
-- If there are any events on the 'rerunBuf', those are consumed head first.
-- Afterwards, we try to pull events from the TChan of raw OS input. If no
-- capturing process is registered, this function returns a 'Left KeyEvent',
-- otherwise it returns a 'Right IO ()'. This IO action needs to be executed to
-- dispatch the 'KeyEvent' to the capturing process.
pull :: (HasLogFunc e, HasDispatch e)
  => RIO e KeyEvent
  -> RIO e KeyEvent
pull pullSrc = do
  d <- view dispatch

  -- Get an event from the rerunBuf, or if empty, from the OS
  e <- readIORef (d^.rerunBuf) >>= \case
    Seq.Empty -> pullSrc
    (e' :<| b) -> do
      writeIORef (d^.rerunBuf) b
      logDebug $ "\n" <> display (T.replicate 80 "-")
              <> "\n Rerunning event: " <> display e'
      pure e'

  -- If we have a registered process, dispatch event, otherwise return it
  readIORef (d^.redirect) >>= \case
    Nothing -> pure e
    Just f  -> do
      logDebug $ "Dispatching event to external process"
      liftIO $ f e
      pull pullSrc

-- | Add a list of 'KeyEvent's to the front of the rerun-buffer. These events
-- will be taken before any new events are read from the OS. The list is
-- consumed head-first.
rerun :: HasDispatch e => [KeyEvent] -> RIO e ()
rerun es = do
  rr <- view rerunBuf
  modifyIORef' rr (Seq.fromList es ><)

-- | Register a capturing process with the 'Dispatch'
--
-- NOTE: This blocks if the input is already captured by a different process.
--
captureInput :: (HasLogFunc e, HasDispatch e) => (KeyEvent -> RIO e ()) -> RIO e ()
captureInput f = do
  logDebug $ "Registering external process to capture input"
  u   <- askRunInIO
  rdr <- view redirect
  writeIORef rdr (Just $ u . f)

-- | Remove the registered capture from the 'Dispatch'
--
-- NOTE: This blocks if there is no registered process capturing the input.
--
releaseInput :: (HasLogFunc e, HasDispatch e) => RIO e ()
releaseInput = do
  logDebug $ "Unregistering external process from input"
  rdr <- view redirect
  writeIORef rdr Nothing
