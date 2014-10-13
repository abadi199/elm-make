{-# LANGUAGE FlexibleContexts #-}
module LoadInterfaces where

import Control.Monad.Error (MonadError, MonadIO, liftIO, throwError)
import Control.Monad.Reader (MonadReader)
import qualified Data.Graph as Graph
import qualified Data.List as List
import Data.Map ((!))
import qualified Data.Map as Map
import System.Directory (doesFileExist, getModificationTime)

import qualified Elm.Compiler.Module as Module
import qualified Path
import TheMasterPlan
    ( ModuleID(ModuleID), Location(..)
    , ProjectSummary, ProjectData(..)
    , BuildSummary, BuildData(..)
    )


prepForBuild
    :: (MonadIO m, MonadError String m, MonadReader FilePath m)
    => ProjectSummary Location
    -> m BuildSummary
prepForBuild projectSummary =
  do  enhancedSummary <- addInterfaces projectSummary
      filteredSummary <- filterStaleInterfaces enhancedSummary
      return (enrichDependencies filteredSummary)


--- LOAD INTERFACES -- what has already been compiled?

addInterfaces
    :: (MonadIO m, MonadReader FilePath m)
    => ProjectSummary Location
    -> m (ProjectSummary (Location, Maybe Module.Interface))
addInterfaces projectSummary =
  do  enhancedSummary <- mapM maybeLoadInterface (Map.toList projectSummary)
      return (Map.fromList enhancedSummary)
      

maybeLoadInterface
    :: (MonadIO m, MonadReader FilePath m)
    => (ModuleID, ProjectData Location)
    -> m (ModuleID, ProjectData (Location, Maybe Module.Interface))
maybeLoadInterface (moduleID, (ProjectData location deps)) =
  do  interfacePath <- Path.fromModuleID moduleID
      let sourcePath = Path.fromLocation location
      fresh <- liftIO (isFresh sourcePath interfacePath)

      maybeInterface <-
          case fresh of
            False -> return Nothing
            True ->
              do  interface <- (error "Module.readInterface") interfacePath
                  return (Just interface)

      return (moduleID, ProjectData (location, maybeInterface) deps)
                    

isFresh :: FilePath -> FilePath -> IO Bool
isFresh sourcePath interfacePath =
  do  exists <- doesFileExist interfacePath
      case exists of
        False -> return False
        True ->
          do  sourceTime <- getModificationTime sourcePath
              interfaceTime <- getModificationTime interfacePath
              return (sourceTime <= interfaceTime)


-- FILTER STALE INTERFACES -- have files become stale due to other changes?

filterStaleInterfaces
    :: (MonadError String m)
    => ProjectSummary (Location, Maybe Module.Interface)
    -> m (ProjectSummary (Either Location Module.Interface))
filterStaleInterfaces summary =
  do  sortedNames <- topologicalSort (Map.map projectDependencies summary)
      return (List.foldl' (filterIfStale summary) Map.empty sortedNames)


filterIfStale
    :: ProjectSummary (Location, Maybe Module.Interface)
    -> ProjectSummary (Either Location Module.Interface)
    -> ModuleID
    -> ProjectSummary (Either Location Module.Interface)
filterIfStale enhancedSummary filteredSummary moduleName =
    Map.insert moduleName (ProjectData trueLocation deps) filteredSummary
  where
    (ProjectData (filePath, maybeInterface) deps) =
        enhancedSummary ! moduleName

    trueLocation =
        case maybeInterface of
          Just interface
            | all (haveInterface enhancedSummary) deps ->
                Right interface

          _ -> Left filePath


haveInterface
    :: ProjectSummary (Location, Maybe Module.Interface)
    -> ModuleID
    -> Bool
haveInterface enhancedSummary name =
    case projectLocation (enhancedSummary ! name) of
      (_, Just _) -> True
      (_, Nothing) -> False


-- ENRICH DEPENDENCIES -- augment dependencies based on available interfaces

enrichDependencies
    :: ProjectSummary (Either Location Module.Interface)
    -> BuildSummary
enrichDependencies summary =
    Map.mapMaybe (enrich summary) summary


enrich
    :: ProjectSummary (Either Location Module.Interface)
    -> ProjectData (Either Location Module.Interface)
    -> Maybe BuildData
enrich projectSummary (ProjectData trueLocation dependencies) =
  case trueLocation of
    Right _ -> Nothing
    Left location ->
        Just (BuildData blocking ready location)

  where
    (blocking, ready) =
        List.foldl' insert ([], Map.empty) dependencies

    insert (blocking, ready) name =
        case projectLocation `fmap` Map.lookup name projectSummary of
          Just (Right interface) ->
              (blocking, Map.insert name interface ready)
          _ ->
              (name : blocking, ready)


-- SORT GRAPHS / CHECK FOR CYCLES

topologicalSort :: (MonadError String m) => Map.Map ModuleID [ModuleID] -> m [ModuleID]
topologicalSort dependencies =
    mapM errorOnCycle components
  where
    components =
        Graph.stronglyConnComp (map toNode (Map.toList dependencies))

    toNode (name, deps) =
        (name, name, deps)

    errorOnCycle scc =
        case scc of
          Graph.AcyclicSCC name -> return name
          Graph.CyclicSCC cycle ->
              throwError $
              "Your dependencies for a cycle:\n\n"
              ++ showCycle dependencies cycle
              ++ "\nYou may need to move some values to a new module to get rid of thi cycle."


showCycle :: Map.Map ModuleID [ModuleID] -> [ModuleID] -> String
showCycle _dependencies [] = ""
showCycle dependencies (name:rest) =
    "    " ++ idToString name ++ " => " ++ idToString next ++ "\n"
    ++ showCycle dependencies (next:remaining)
  where
    idToString (ModuleID _ moduleName) =
        Module.nameToString moduleName
    ([next], remaining) =
        List.partition (`elem` rest) (dependencies Map.! name)
