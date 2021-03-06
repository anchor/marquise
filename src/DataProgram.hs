--
-- Data vault for metrics
--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

{-# LANGUAGE DoAndIfThenElse   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import Control.Concurrent.MVar
import qualified Data.Attoparsec.Text as PT
import Data.Binary.IEEE754
import qualified Data.ByteString.Char8 as S
import qualified Data.HashMap.Strict as HT
import Data.String
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
import Data.Time.Clock.POSIX
import Data.Word
import Options.Applicative
import Options.Applicative.Types
import Pipes
import qualified Pipes.Prelude as P
import System.IO
import System.Locale
import System.Log.Logger
import Text.Printf

import Marquise.Classes
import Marquise.Client
import Package (package, version)
import Vaultaire.Program
import Vaultaire.Types
import Vaultaire.Util

--
-- Component line option parsing
--

data Options = Options
  { broker    :: String
  , debug     :: Bool
  , component :: Component }

data Component =
                 Now
               | Read { raw     :: Bool
                      , origin  :: Origin
                      , address :: Address
                      , start   :: TimeStamp
                      , end     :: TimeStamp }
               | List { origin :: Origin }
               | Add { origin :: Origin
                     , addr   :: Address
                     , dict   :: [Tag] }
               | Remove  { origin :: Origin
                     , addr       :: Address
                     , dict       :: [Tag] }
               | SourceCache { cacheFile :: FilePath }

type Tag = (Text, Text)

justRead :: Read a => ReadM a
justRead = readerAsk >>= return . read

helpfulParser :: ParserInfo Options
helpfulParser = info (helper <*> optionsParser) fullDesc

optionsParser :: Parser Options
optionsParser = Options <$> parseBroker
                        <*> parseDebug
                        <*> parseComponents
  where
    parseBroker = strOption $
           long "broker"
        <> short 'b'
        <> metavar "BROKER"
        <> value "localhost"
        <> showDefault
        <> help "Vaultaire broker hostname or IP address"

    parseDebug = switch $
           long "debug"
        <> short 'd'
        <> help "Output lots of debugging information"

    parseComponents = subparser
       (   parseTimeComponent
        <> parseReadComponent
        <> parseListComponent
        <> parseAddComponent
        <> parseRemoveComponent
        <> parseSourceCacheComponent )

    parseTimeComponent =
        componentHelper "now" (pure Now) "Display the current time"

    parseReadComponent =
        componentHelper "read" readOptionsParser "Read points from a given address and time range"

    parseListComponent =
        componentHelper "list" listOptionsParser "List addresses and metadata in origin"

    parseAddComponent =
        componentHelper "add-source" addOptionsParser "Add some tags to an address"

    parseRemoveComponent =
        componentHelper "remove-source" addOptionsParser "Remove some tags from an address, does nothing if the tags do not exist"

    parseSourceCacheComponent =
        componentHelper "source-cache" sourceCacheOptionsParser "Validate the contents of a Marquise daemon source cache file"

    componentHelper cmd_name parser desc =
        command cmd_name (info (helper <*> parser) (progDesc desc))


parseAddress :: Parser Address
parseAddress = argument (readerAsk >>= return . fromString) (metavar "ADDRESS")

parseOrigin :: Parser Origin
parseOrigin = argument (readerAsk >>= return . mkOrigin) (metavar "ORIGIN")
  where
    mkOrigin = Origin . S.pack

parseTags :: Parser [Tag]
parseTags = many $ argument (readerAsk >>= return . mkTag) (metavar "TAG")
  where
    mkTag x = case PT.parseOnly tag $ T.pack x of
      Left _  -> error "data: invalid tag format"
      Right y -> y
    tag = (,) <$> PT.takeWhile (/= ':')
              <* ":"
              <*> PT.takeWhile (/= ',')

readOptionsParser :: Parser Component
readOptionsParser = Read <$> parseRaw
                         <*> parseOrigin
                         <*> parseAddress
                         <*> parseStart
                         <*> parseEnd
  where
    parseRaw = switch $
        long "raw"
        <> short 'r'
        <> help "Output values in a raw form (human-readable otherwise)"

    parseStart = option justRead $
        long "start"
        <> short 's'
        <> value 0
        <> showDefault
        <> help "Start time in nanoseconds since epoch"

    parseEnd = option justRead $
        long "end"
        <> short 'e'
        <> value maxBound
        <> showDefault
        <> help "End time in nanoseconds since epoch"

listOptionsParser :: Parser Component
listOptionsParser = List <$> parseOrigin

addOptionsParser :: Parser Component
addOptionsParser = Add <$> parseOrigin <*> parseAddress <*> parseTags

removeOptionsParser :: Parser Component
removeOptionsParser = Remove <$> parseOrigin <*> parseAddress <*> parseTags

sourceCacheOptionsParser :: Parser Component
sourceCacheOptionsParser = SourceCache <$> parseFilePath
  where
    parseFilePath = argument str $ metavar "CACHEFILE"

--
-- Actual tools
--

runPrintDate :: IO ()
runPrintDate = do
    now <- getCurrentTime
    let time = formatTime defaultTimeLocale "%FT%TZ" now
    putStrLn time

runReadPoints :: String -> Bool -> Origin -> Address -> TimeStamp -> TimeStamp -> IO ()
runReadPoints broker raw origin addr start end =
    withReaderConnection broker $ \c ->
        runEffect $   readSimplePoints addr start end origin c
                  >-> P.map (displayPoint raw)
                  >-> P.print

displayPoint :: Bool -> SimplePoint -> String
displayPoint raw (SimplePoint address timestamp payload) =
    if raw
        then
            show address ++ "," ++ show timestamp ++ "," ++ show payload
        else
            show address ++ "  " ++ formatTimestamp timestamp ++ " " ++ formatValue payload
  where
    formatTimestamp :: TimeStamp -> String
    formatTimestamp (TimeStamp t) =
      let
        seconds = posixSecondsToUTCTime $ realToFrac (fromIntegral t / 1000000000 :: Rational)
        iso8601 = formatTime defaultTimeLocale "%FT%T.%q" seconds
      in
        take 29 iso8601 ++ "Z"

{-
    Take a stab at differentiating between raw integers and encoded floats.
    The 2^51 is somewhat arbitrary, being one less bit than the size of the
    significand in an IEEE 754 64-bit double. Seems safe to assume anything
    larger than that was in fact an encoded float; 2^32 (aka 10^9) is too small
    — we have counters bigger than that — but nothing has gone past 10^15 so
    there seemed plenty of headroom. At the end of the day this is just a
    convenience; if you need the real value and know its interpretation then
    you can request raw (in this program) output or actual bytes (via reader
    daemon).
-}
    formatValue :: Word64 -> String
    formatValue v = if v > (2^(51 :: Int) :: Word64)
        then
            printf "% 24.6f" (wordToDouble v)
        else
            printf "% 17d" v


runListContents :: String -> Origin -> IO ()
runListContents broker origin =
    withContentsConnection broker $ \c ->
        runEffect $ enumerateOrigin origin c >-> P.print

runAddTags, runRemoveTags :: String -> Origin -> Address -> [Tag] -> IO ()
runAddTags    = run updateSourceDict
runRemoveTags = run removeSourceDict

runSourceCache :: FilePath -> IO ()
runSourceCache cacheFile = do
    bits <- withFile cacheFile ReadMode S.hGetContents
    case fromWire bits of
        Left e -> putStrLn . concat $
            [ "Error parsing cache file: "
            , show e
            ]
        Right cache -> putStrLn . concat $
            [ "Valid Marquise source cache. Contains "
            , show . sizeOfSourceCache $ cache
            , " entries."
            ]

run :: (MarquiseContentsMonad m connection, Functor m)
    => (Address -> SourceDict -> Origin -> connection -> m a)
    -> String -> Origin -> Address -> [(Text, Text)] -> m a
run op broker origin addr sdPairs = do
  let dict = case makeSourceDict $ HT.fromList sdPairs of
                  Left e  -> error e
                  Right a -> a
  withContentsConnection broker $ \c ->
        op addr dict origin c

--
-- Main program entry point
--

main :: IO ()
main = do
    Options{..} <- execParser helpfulParser

    let level = if debug
        then Debug
        else Quiet

    quit <- initializeProgram (package ++ "-" ++ version) level

    -- Run selected component.
    debugM "Main.main" "Running command"

    -- Although none of the components are running in the background, we get off
    -- of the main thread so that we can block the main thread on the quit
    -- semaphore, such that a user interrupt will kill the program.

    linkThread $ do
        _ <- case component of
            Now ->
                runPrintDate
            Read human origin addr start end ->
                runReadPoints broker human origin addr start end
            List origin ->
                runListContents broker origin
            Add origin addr tags ->
                runAddTags broker origin addr tags
            Remove  origin addr tags ->
                runRemoveTags broker origin addr tags
            SourceCache cacheFile ->
                runSourceCache cacheFile
        putMVar quit ()

    takeMVar quit
    debugM "Main.main" "End"
