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

{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Control.Concurrent.MVar
import Data.String
import Data.Time
import Data.Word (Word64)
import Options.Applicative
import Pipes
import System.Locale
import System.Log.Logger
import Data.Binary.IEEE754
import Data.Text (Text)
import qualified Data.Text             as T
import qualified Data.ByteString.Char8 as S
import qualified Data.Attoparsec.Text  as PT
import qualified Data.HashMap.Strict   as HT
import Text.Printf

import Marquise.Client
import Package (package, version)
import Vaultaire.Util
import Vaultaire.Program

--
-- Component line option parsing
--

data Options = Options
  { broker    :: String
  , debug     :: Bool
  , component :: Component }

data Component = 
                 Time
               | Read { human   :: Bool
                      , origin  :: Origin
                      , address :: Address
                      , start   :: Word64
                      , end     :: Word64 }
               | List { origin :: Origin }
               | Add { origin :: Origin
                     , addr   :: Address
                     , dict   :: [Tag] }
               | Remove  { origin :: Origin
                     , addr   :: Address
                     , dict   :: [Tag] }

type Tag = (Text, Text)

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
        <> parseRemoveComponent )

    parseTimeComponent =
        componentHelper "now" (pure Time) "Display the current time"

    parseReadComponent =
        componentHelper "read" readOptionsParser "Read points from a given address and time range"

    parseListComponent =
        componentHelper "list" listOptionsParser "List addresses and metadata in origin"

    parseAddComponent =
        componentHelper "add-source" addOptionsParser "Add some tags to an address"

    parseRemoveComponent =
        componentHelper "remove-source" addOptionsParser "Remove some tags from an address, does nothing if the tags do not exist"

    componentHelper cmd_name parser desc =
        command cmd_name (info (helper <*> parser) (progDesc desc))


parseAddress :: Parser Address
parseAddress = argument (fmap fromString . str) (metavar "ADDRESS")

parseOrigin :: Parser Origin
parseOrigin = argument (fmap mkOrigin . str) (metavar "ORIGIN")
  where
    mkOrigin = Origin . S.pack

parseTags :: Parser [Tag]
parseTags = many $ argument (fmap mkTag . str) (metavar "TAG")
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

    parseStart = option $
        long "start"
        <> short 's'
        <> value 0
        <> showDefault
        <> help "Start time in nanoseconds since epoch"

    parseEnd = option $
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

--
-- Actual tools
--

runPrintDate :: IO ()
runPrintDate = do
    now <- getCurrentTime
    let time = formatTime defaultTimeLocale "%FT%TZ" now
    putStrLn time


runReadPoints :: String -> Bool -> Origin -> Address -> Word64 -> Word64 -> IO ()
runReadPoints broker raw origin addr start end = do
    withReaderConnection broker $ \c ->
        runEffect $ for (readSimple addr start end origin c >-> decodeSimple)
                        (lift . putStrLn . (displayPoint raw))

displayPoint :: Bool -> SimplePoint -> String
displayPoint raw (SimplePoint address timestamp payload) =
    if raw
        then
            show address ++ "," ++ show timestamp ++ "," ++ show payload
        else
            formatTimestamp timestamp ++ " " ++ formatValue payload
  where
    formatTimestamp :: Word64 -> String
    formatTimestamp t = show $ (fromIntegral t :: Int) `div` 1000000000

    formatValue :: Word64 -> String
    formatValue v = if v > (2^(51 :: Int) :: Word64)
        then
            printf "% 25.6f" (wordToDouble v)
        else
            printf "% 18d" v


runListContents :: String -> Origin -> IO ()
runListContents broker origin = do
    withContentsConnection broker $ \c ->
        runEffect $ for (enumerateOrigin origin c) (lift . print)

runAddTags, runRemoveTags :: String -> Origin -> Address -> [Tag] -> IO ()
runAddTags    = run updateSourceDict
runRemoveTags = run removeSourceDict

run op broker origin addr ts = do
  let dict = case makeSourceDict $ HT.fromList ts of
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
        case component of
            Time ->
                runPrintDate
            Read human origin addr start end ->
                runReadPoints broker human origin addr start end
            List origin ->
                runListContents broker origin
            Add origin addr tags ->
                runAddTags broker origin addr tags
            Remove  origin addr tags ->
                runRemoveTags broker origin addr tags
        putMVar quit ()

    takeMVar quit
    debugM "Main.main" "End"