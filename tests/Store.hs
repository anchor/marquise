{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}

-- Hide warnings for the deprecated ErrorT transformer:
{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}

module Store where

import Control.Applicative
import Control.Lens hiding (op)
import Control.Monad.Error
import Control.Monad.State
import Data.Map (Map)
import qualified Data.Map as M
import Data.Monoid

import Marquise.Classes
import Marquise.Types
import Vaultaire.Types


data PureStore
   = PureStore { _contents      :: [Data (Address, SourceDict)]
               , _points        :: [Data (SimpleBurst, SimplePoint)]
               -- No multiplexing, this seems to be the desired behaviour
               -- for each ZMQ connection.
               , _contentsConns :: Map Name ContentsConn
               , _pointsConns   :: Map Name PointsConn }

data Data a = Data a | FakeError
     deriving Show

-- current operation and index into response "stream"
type ContentsConn = (ContentsOperation, Int)
type PointsConn   = (ReadRequest,       Int)

newtype Name = Name String
        deriving (Eq, Ord)
newtype Store a = Store { store :: State PureStore a }
        deriving (Functor, Applicative, Monad, MonadState PureStore)

makeLenses ''PureStore
makeLenses ''Store

instance MarquiseContentsMonad Store Name where
  -- "connect" to the purestore
  sendContentsRequest op _ i = lift $ contentsConns %= M.insert i (op, 0)

  -- "receive" responses
  recvContentsResponse i =
    lift (use contentsConns >>= return . M.lookup i)
    >>= maybe (throwError $ Other "no connection")
              (\c -> case c of
                (ContentsListRequest, streamIx) ->
                    lift (use contents) >>= go . drop streamIx
                _                               ->
                    throwError $ MalformedResponse None $
                        "recvContentsResponse only expects ContentsListRequest, got: " <> show c)
    where go []              = return EndOfContentsList
          go (FakeError:_)   = get >>= throwError . Timeout
          go (Data (a,d):_)
            = let resp = ContentsListEntry a d
              in  inc >> return resp
          inc = lift $ contentsConns %= M.adjust (_2 +~ 1) i
  withContentsConnection n act = act (Name n)

instance MarquiseReaderMonad Store Name where
  sendReaderRequest op _ i = lift $ pointsConns %= M.insert i (op, 0)
  recvReaderResponse i =
    lift (use pointsConns >>= return . M.lookup i)
    >>= maybe (throwError $ Other "no connection")
              (\c -> case c of
                (SimpleReadRequest   _ s e, streamIx) ->
                    lift (use points) >>= go s e . drop streamIx
                (ExtendedReadRequest _ s e, streamIx) ->
                    lift (use points) >>= go s e . drop streamIx)
    where go _ _ []            = return EndOfStream
          go _ _ (FakeError:_) = get >>= throwError . Timeout
          go s e (Data (burst, SimplePoint _ t _):xs)
            = let resp = SimpleStream burst
              in  if   t < s || t >= e
                  then inc >> go s e xs
                  else inc >> return resp
          inc = lift $ pointsConns %= M.adjust (_2 +~ 1) i
  withReaderConnection n act = act (Name n)
