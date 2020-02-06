{-# LANGUAGE FlexibleContexts #-}

module TimeTagParser where

import Data.List (intercalate, isSuffixOf)
import Data.Maybe (catMaybes)
import Data.Time
import PandocParser
import PandocStream
import Text.Pandoc
import Text.Parsec

type Project   = String
type Task      = String
type Timestamp = String
data TimeTag   =
    StartTimeTag Project Task ZonedTime
  | StopTimeTag  Project Task ZonedTime
  deriving Show

instance Eq TimeTag where
  (StartTimeTag p1 t1 zt1) == (StartTimeTag p2 t2 zt2) =
    p1 == p2 && t1 == t2 && zonedTimeToUTC zt1 == zonedTimeToUTC zt2
  (StopTimeTag p1 t1 zt1) == (StopTimeTag p2 t2 zt2) =
    p1 == p2 && t1 == t2 && zonedTimeToUTC zt1 == zonedTimeToUTC zt2
  _ == _ = False

parseTagTime = parseTimeM False defaultTimeLocale "%Y%m%d %T %z"

isTagElement     e =
     isHeaderL 1 e || isHeaderL 2 e || isHeaderL 3 e
  || maybe False ("<task-start" `isSuffixOf`) s
  || maybe False ("<task-stop"  `isSuffixOf`) s
  where s = toStr e
isNonTagElement  e = not (isTagElement e)
isDayElement     e = not (isHeaderL 1 e)  && isNonTagElement e
isProjectElement e = not (isHeaderL 2 e)  && isDayElement e
isTaskElement    e = not (isHeaderL 3 e)  && isProjectElement e

nonTagElement, dayElement, projectElement, taskElement
  :: Stream s m PandocElement => ParsecT s u m PandocElement
nonTagElement  = satisfyElement isNonTagElement <?> "non-tag element"
dayElement     = satisfyElement isDayElement <?> "day element"
projectElement = satisfyElement isProjectElement <?> "project element"
taskElement    = satisfyElement isTaskElement <?> "task element"

timeTags :: Stream s m PandocElement => ParsecT s u m [TimeTag]
timeTags = concat <$> many dayTimeTags

dayTimeTags, projectTimeTags
  :: Stream s m PandocElement => ParsecT s u m [TimeTag]

dayTimeTags = do
  many nonTagElement
  headerL 1
  concat <$> many (try $ projectTimeTags)

projectTimeTags = do
  many dayElement
  Header _ _ is2 <- headerL 2
  let project = writeInlines is2
  concat <$> many (try $ taskTimeTags project)

taskTimeTags :: Stream s m PandocElement
  => Project -> ParsecT s u m [TimeTag]
taskTimeTags project = do
  many projectElement
  Header _ _ is3 <- headerL 3
  let task = writeInlines is3
  catMaybes
    <$> many (Just <$> try (timeTag project task) <|> Nothing <$ taskElement)

timeTag :: Stream s m PandocElement =>
  String -> String -> ParsecT s u m TimeTag
timeTag project task = do
  start <-
        True  <$ satisfyElement
                 (maybe False ("<task-start" `isSuffixOf`) . toStr)
    <|> False <$ satisfyElement
                 (maybe False ("<task-stop" `isSuffixOf`)  . toStr)
  inline Space
  Str date' <- anyInline
  date      <- case splitAt 3 date' of
                ("t=\"", d) -> return d
                _           ->
                  fail "Malformed <task-start/> or <task-stop/>"
  inline Space
  Str time  <- anyInline
  inline Space
  Str tz'   <- anyInline
  tz        <- case splitAt 5 tz' of
                 (t, "\"/>") -> return t
                 _           ->
                   fail "Malformed <task-start/> or <task-stop/>"
  let timestampStr = intercalate " " [date, time, tz]
  timestamp <-
        case parseTagTime timestampStr of
          Just t  -> return t
          Nothing -> fail $ "Wrong timestamp string: " ++ timestampStr
  if start
    then return $ StartTimeTag project task timestamp
    else return $ StopTimeTag  project task timestamp
