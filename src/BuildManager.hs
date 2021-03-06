{-# OPTIONS_GHC -Wall #-}
module BuildManager where

import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.State (StateT, liftIO, runStateT)
import qualified Control.Monad.State as State
import qualified Data.List as List
import qualified Data.Time.Clock.POSIX as Time
import qualified Elm.Compiler as Compiler
import qualified Elm.Compiler.Module as Module
import qualified Elm.Package as Pkg
import qualified Elm.Package.Paths as Path
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

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
    , _permissions :: Permissions
    }


data Output
    = Html FilePath
    | JS FilePath
    | DevNull


outputFilePath :: Config -> FilePath
outputFilePath config =
  case _output config of
    Html file -> file
    JS file -> file
    DevNull -> "/dev/null"


artifactDirectory :: FilePath
artifactDirectory =
    Path.stuffDirectory </> "build-artifacts" </> (Pkg.versionToString Compiler.version)


data Permissions
  = PortsAndEffects
  | Effects
  | None



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

        (Right _, _) ->
            error "Something impossible happened when profiling elm-make."




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
    = CompilerErrors FilePath String [Compiler.Error]
    | CorruptedArtifact FilePath
    | Cycle [TMP.CanonicalModule]
    | PackageProblem String
    | MissingPackage Pkg.Name
    | ModuleNotFound Module.Raw (Maybe Module.Raw)
    | ModuleDuplicates
        { _name :: Module.Raw
        , _parent :: Maybe Module.Raw
        , _local :: [FilePath]
        , _foreign :: [Pkg.Name]
        }
    | ModuleName
        { _path :: FilePath
        , _expectedName :: Module.Raw
        , _actualName :: Module.Raw
        }
    | UnpublishablePorts FilePath Module.Raw
    | UnpublishableEffects FilePath Module.Raw



printError :: Error -> IO ()
printError err =
  case err of
    CompilerErrors path source errors ->
        do  errIsTerminal <- Report.checkIfErrIsTerminal
            mapM_ (Report.printError errIsTerminal Compiler.dummyLocalizer path source) errors

    CorruptedArtifact filePath ->
        hPutStrLn stderr $
          "Error reading build artifact " ++ filePath ++ "\n"
          ++ "\n"
          ++ "The file was generated by a previous build and may be outdated or corrupt.\n"
          ++ "Remove the file and try again."

    Cycle moduleCycle ->
        hPutStrLn stderr $
          "Your dependencies form a cycle:\n\n"
          ++ drawCycle moduleCycle
          ++ "\nYou may need to move some values to a new module to get rid of the cycle."

    PackageProblem msg ->
        hPutStrLn stderr msg

    MissingPackage name ->
        hPutStrLn stderr $
          "Could not find package " ++ Pkg.toString name ++ ".\n"
          ++ "\n"
          ++ "Maybe your elm-stuff/ directory has been corrupted? You can usually fix stuff\n"
          ++ "like this by deleting elm-stuff/ and rebuilding your project."

    ModuleNotFound name maybeParent ->
        hPutStrLn stderr $
          "I cannot find module '" ++ Module.nameToString name ++ "'.\n"
          ++ "\n"
          ++ toContext maybeParent
          ++ "\n"
          ++ "Potential problems could be:\n"
          ++ "  * Misspelled the module name\n"
          ++ "  * Need to add a source directory or new dependency to " ++ Path.description

    ModuleDuplicates name maybeParent filePaths pkgs ->
        let
          packages =
            map ("package " ++) (map Pkg.toString pkgs)

          paths =
            map ("directory " ++) filePaths
        in
          hPutStrLn stderr $
            "I found multiple modules named '" ++ Module.nameToString name ++ "'.\n"
            ++ "\n"
            ++ toContext maybeParent
            ++ "\n"
            ++ "Modules with that name were found in the following locations:\n\n" ++
            concatMap (\str -> "    " ++ str ++ "\n") (paths ++ packages)

    ModuleName path nameFromPath nameFromSource ->
        hPutStrLn stderr $
          "The module name is messed up for " ++ path ++ "\n"
          ++ "\n"
          ++ "    According to the file's name it should be " ++ Module.nameToString nameFromPath ++ "\n"
          ++ "    According to the source code it should be " ++ Module.nameToString nameFromSource ++ "\n"
          ++ "\n"
          ++ "Which is it?"

    UnpublishablePorts path name ->
        hPutStrLn stderr $ List.intercalate "\n" $
          [ "You are trying to publish `port module " ++ Module.nameToString name ++ "` which"
          , "is defined in: " ++ path
          , ""
          , "Modules with ports cannot be published. Imagine installing a new package, only"
          , "to find that it silently does not work at all unless you hook up some poorly"
          , "documented ports with specific names. And these port names may overlap with"
          , "names you are already using in your project! Suddenly it became much trickier"
          , "to add a dependency."
          , ""
          , "So basically, it would suck for everyone if any packages declared ports."
          , ""
          , "If you think the Elm community really need this in the package ecosystem for"
          , "some reason, ask around on the mailing list or Slack channel listed at"
          , "<http://elm-lang.org/community>. Folks are friendly and helpful, and there is"
          , "likely some other way!"
          ]

    UnpublishableEffects path name ->
        hPutStrLn stderr $ List.intercalate "\n" $
          [ "Your package includes `effect module " ++ Module.nameToString name ++ "` which"
          , "is defined in: " ++ path
          , ""
          , "Effect modules in the package ecosystem define \"The Elm Platform\", providing"
          , "nice APIs for things like web sockets, geolocation, and page visibility."
          , ""
          , "The only intent of effect modules is to help Elm communicate with EXTERNAL"
          , "services. If you want to write a wrapper around GraphQL or Phoenix Channels,"
          , "you are using effect modules as intended. If you are doing any other kind of"
          , "thing, it may be subverting \"The Elm Platform\" in relatively serious ways."
          , ""
          , "So to publish your own effect module, you need to go through a review process"
          , "to make sure these facilities are not being abused. Think of it as contributing"
          , "to the compiler or core libraries. Obviously someone is going to review that PR"
          , "in those cases. Same thing here."
          , ""
          , "To make this as smooth as possible, let folks on the elm-dev mailing list know"
          , "what you are up to as soon as possible."
          , ""
          , "    <https://groups.google.com/forum/#!forum/elm-dev>"
          , ""
          , "It is impossible to collaborate with people if you do not communicate. So come"
          , "and talk through your goals. See if it aligns with Elm overall or if there is"
          , "some nicer way. When things get to a point where you want to publish something,"
          , "open an issue in the following repo:"
          , ""
          , "    <https://github.com/elm-lang/package.elm-lang.org/issues>"
          , ""
          , "With a title like \"Effect manager review for _____\"."
          ]


toContext :: Maybe Module.Raw -> String
toContext maybeParent =
  case maybeParent of
    Nothing ->
        "This module is demanded in " ++ Path.description ++ ".\n"

    Just parent ->
        "Module '" ++ Module.nameToString parent ++ "' is trying to import it.\n"


drawCycle :: [TMP.CanonicalModule] -> String
drawCycle modules =
  let
    topLine=
        [ "  ┌─────┐"
        , "  │     V"
        ]

    line (TMP.CanonicalModule _ name) =
        [ "  │    " ++ Module.nameToString name ]

    midLine =
        [ "  │     │"
        , "  │     V"
        ]

    bottomLine =
        "  └─────┘"
  in
    unlines (topLine ++ List.intercalate midLine (map line modules) ++ [ bottomLine ])
