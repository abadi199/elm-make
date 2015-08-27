{-# OPTIONS_GHC -Wall #-}
module BuildManager where

import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.State (StateT, liftIO, runStateT)
import qualified Control.Monad.State as State
import qualified Data.Time.Clock.POSIX as Time
import qualified Elm.Compiler as Compiler
import qualified Elm.Compiler.Version as CompilerVersion
import qualified Elm.Compiler.Module as Module
import qualified Elm.Package as Pkg
import qualified Elm.Package.Paths as Path
import System.FilePath ((</>))

import qualified Report
import qualified TheMasterPlan as TMP


-- CONFIGURATION

data Config = Config
    { _artifactDirectory :: FilePath
    , _files :: [FilePath]
    , _output :: Output
    , _autoYes :: Bool
    , _reportType :: Report.Type
    , _warn :: Bool
    , _docs :: Maybe FilePath
    }


data Output
    = Html FilePath
    | JS FilePath


outputFilePath :: Config -> FilePath
outputFilePath config =
  case _output config of
    Html file -> file
    JS file -> file


artifactDirectory :: FilePath
artifactDirectory =
    Path.stuffDirectory </> "build-artifacts" </> CompilerVersion.version


-- RUN A BUILD

type Task a =
  ExceptT Error (StateT [Phase] IO) a


run :: Task a -> IO (Either Error (a, Timeline))
run task =
  do  result <-
          runStateT (runExceptT (phase "elm-make" task)) []
      case result of
        (Right answer, [Phase _ start phases end]) ->
            return (Right (answer, Timeline start phases end))

        (Left err, _) ->
            return (Left err)


-- TIMELINE

data Timeline = Timeline
    { _start :: Time.POSIXTime
    , _phases :: [Phase]
    , _end :: Time.POSIXTime
    }


data Phase = Phase
    { _tag :: String
    , _start_ :: Time.POSIXTime
    , _subphases :: [Phase]
    , _end_ :: Time.POSIXTime
    }


phase :: String -> Task a -> Task a
phase name task =
  do  phasesSoFar <- State.get
      State.put []
      start <- liftIO Time.getPOSIXTime
      result <- task
      end <- liftIO Time.getPOSIXTime
      State.modify' (\phases -> Phase name start (reverse phases) end : phasesSoFar)
      return result


timelineToString :: Timeline -> String
timelineToString (Timeline start phases end) =
  let
    duration = end - start
  in
    "\nOverall time: " ++ show duration ++ "\n"
    ++ concatMap (phaseToString duration 1) phases
    ++ "\n"


phaseToString :: Time.POSIXTime -> Int -> Phase -> String
phaseToString overallDuration indent (Phase tag start subphases end) =
  let
    duration = end - start
    percent = truncate (100 * duration / overallDuration) :: Int
  in
    '\n' : replicate (indent * 4) ' ' ++ show percent ++ "% - " ++ tag
    ++ concatMap (phaseToString duration (indent + 1)) subphases


-- ERRORS

data Error
    = BadFlags
    | CompilerErrors FilePath String [Compiler.Error]
    | CorruptedArtifact FilePath
    | Cycle [TMP.CanonicalModule]
    | PackageProblem String
    | MissingPackage Pkg.Name
    | ModuleNotFound Module.Name (Maybe Module.Name)
    | ModuleDuplicates
        { _name :: Module.Name
        , _parent :: Maybe Module.Name
        , _local :: [FilePath]
        , _foreign :: [Pkg.Name]
        }
    | ModuleName
        { _path :: FilePath
        , _expectedName :: Module.Name
        , _actualName :: Module.Name
        }


errorToString :: Error -> String
errorToString err =
  case err of
    BadFlags ->
        error "TODO bad flags"

    CompilerErrors _ _ _ ->
        error "TODO"

    CorruptedArtifact filePath ->
        concat
          [ "Error reading build artifact ", filePath, "\n"
          , "    The file was generated by a previous build and may be outdated or corrupt.\n"
          , "    Please remove the file and try again."
          ]

    Cycle moduleCycle ->
        "Your dependencies form a cycle:\n\n"
        ++ error "TODO" moduleCycle
        ++ "\nYou may need to move some values to a new module to get rid of the cycle."

    PackageProblem msg ->
        msg

    MissingPackage name ->
        error "TODO" name

    ModuleNotFound name maybeParent ->
        unlines
        [ "Error when searching for modules" ++ toContext maybeParent ++ ":"
        , "    Could not find module '" ++ Module.nameToString name ++ "'"
        , ""
        , "Potential problems could be:"
        , "  * Misspelled the module name"
        , "  * Need to add a source directory or new dependency to " ++ Path.description
        ]

    ModuleDuplicates name maybeParent filePaths pkgs ->
        "Error when searching for modules" ++ toContext maybeParent ++ ".\n" ++
        "Found multiple modules named '" ++ Module.nameToString name ++ "'\n" ++
        "Modules with that name were found in the following locations:\n\n" ++
        concatMap (\str -> "    " ++ str ++ "\n") (paths ++ packages)
      where
        packages =
            map ("package " ++) (map Pkg.toString pkgs)

        paths =
            map ("directory " ++) filePaths

    ModuleName path nameFromPath nameFromSource ->
        unlines
          [ "The module name is messed up for " ++ path
          , "    According to the file's name it should be " ++ Module.nameToString nameFromPath
          , "    According to the source code it should be " ++ Module.nameToString nameFromSource
          , "Which is it?"
          ]


toContext :: Maybe Module.Name -> String
toContext maybeParent =
  case maybeParent of
    Nothing ->
        " exposed by " ++ Path.description

    Just parent ->
        " imported by module '" ++ Module.nameToString parent ++ "'"

