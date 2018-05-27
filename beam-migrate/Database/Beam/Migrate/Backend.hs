{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE CPP #-}

-- | Definitions of interest to those implement a new beam backend.
--
-- Steps to defining a beam backend:
--
--   1. Ensure the command syntax for your backend satisfies 'Sql92SaneDdlCommandSyntax'.
--   2. Create a value of type 'BeamMigrationBackend'
--   3. For compatibility with @beam-migrate-cli@, export this value in an
--      exposed module with the name 'migrationBackend'.
--
-- This may sound trivial, but it's a bit more involved. In particular, in order
-- to complete step 2, you will have to define several instances for some of
-- your syntax pieces (for example, data types and constraints will need to be
-- 'Hashable'). You will also need to provide a reasonable function to fetch
-- predicates from your database, and a function to convert all these predicates
-- to corresponding predicates in the Haskell syntax. If you have custom data
-- types or predicates, you will need to supply 'BeamDeserializers' to
-- deserialize them from JSON. Finally, if your backend has custom
-- 'DatabasePredicate's you will have to provide appropriate 'ActionProvider's
-- to discover potential actions for your backend. See the documentation for
-- "Database.Beam.Migrate.Actions" for more information.
--
-- Tools may be interested in the 'SomeBeamMigrationBackend' data type which
-- provides a monomorphic type to wrap the polymorphic 'BeamMigrationBackend'
-- type. Currently, @beam-migrate-cli@ uses this type to get the underlying
-- 'BeamMigrationBackend' via the @hint@ package.
--
-- For an example migrate backend, see "Database.Beam.Sqlite.Migrate"
module Database.Beam.Migrate.Backend
  ( BeamMigrationBackend(..)
  , DdlError

  -- * Haskell predicate conversion
  , HaskellPredicateConverter(..)
  , sql92HsPredicateConverters
  , hasColumnConverter
  , trivialHsConverter, hsPredicateConverter

  -- * For tooling authors
  , SomeBeamMigrationBackend(..) )
where

import           Database.Beam
import           Database.Beam.Backend.SQL
import           Database.Beam.Migrate.Actions
import           Database.Beam.Migrate.Checks
import           Database.Beam.Migrate.Serialization
import           Database.Beam.Migrate.SQL
import           Database.Beam.Migrate.Types
  ( SomeDatabasePredicate(..), MigrationSteps )

import           Database.Beam.Haskell.Syntax

import           Control.Applicative


import qualified Data.ByteString.Lazy as BL
#if ! MIN_VERSION_base(4,11,0)
import           Data.Semigroup
#endif
import           Data.Text (Text)
import           Data.Time

import           Data.Typeable

-- | Type of errors that can be thrown by backends during DDL statement
-- execution. Currently just a synonym for 'String'
type DdlError = String

-- | Backends should create a value of this type and export it in an exposed
-- module under the name 'migrationBackend'. See the module documentation for
-- more details.
data BeamMigrationBackend be hdl m where
  BeamMigrationBackend ::
    ( MonadBeam be hdl m
    , Typeable be
    , HasQBuilder be
    , BeamMigrateSqlBackend be
    , HasQBuilder (Sql92SelectSyntax commandSyntax)
    , BeamSqlBackendCanSerialize be Text
    , HasSqlValueSyntax (BeamSqlBackendDataTypeSyntax be) LocalTime
    , HasSqlValueSyntax (BeamSqlBackendDataTypeSyntax be) (Maybe LocalTime)
    , HasSqlValueSyntax (BeamSqlBackendDataTypeSyntax be) Text
    , HasSqlValueSyntax (BeamSqlBackendDataTypeSyntax be) SqlNull
    , Sql92ReasonableMarshaller be ) =>
    { backendName :: String
    , backendConnStringExplanation :: String
    , backendRenderSteps :: forall a. MigrationSteps be () a -> BL.ByteString
    , backendGetDbConstraints :: m [ SomeDatabasePredicate ]
    , backendPredicateParsers :: BeamDeserializers be
    , backendRenderSyntax :: BeamSqlBackendSyntax be -> String
    , backendFileExtension :: String
    , backendConvertToHaskell :: HaskellPredicateConverter
    , backendActionProvider :: ActionProvider be
    , backendTransact :: forall a. String -> m a -> IO (Either DdlError a)
    } -> BeamMigrationBackend be hdl m

-- | Monomorphic wrapper for use with plugin loaders that cannot handle
-- polymorphism
data SomeBeamMigrationBackend where
  SomeBeamMigrationBackend :: ( BeamMigrateSqlBackend be
                              , Typeable be )
                           => BeamMigrationBackend be hdl m
                           -> SomeBeamMigrationBackend

-- | In order to support Haskell schema generation, backends need to provide a
-- way to convert arbitrary 'DatabasePredicate's generated by the backend's
-- 'backendGetDbConstraints' function into appropriate predicates in the Haskell
-- syntax. Not all predicates have any meaning when translated to Haskell, so
-- backends can choose to drop any predicate (simply return 'Nothing').
newtype HaskellPredicateConverter
  = HaskellPredicateConverter (SomeDatabasePredicate -> Maybe SomeDatabasePredicate)

instance Semigroup HaskellPredicateConverter where
  (<>) = mappend

-- | 'HaskellPredicateConverter's can be combined monoidally.
instance Monoid HaskellPredicateConverter where
  mempty = HaskellPredicateConverter $ \_ -> Nothing
  mappend (HaskellPredicateConverter a) (HaskellPredicateConverter b) =
    HaskellPredicateConverter $ \r -> a r <|> b r

-- | Converters for the 'TableExistsPredicate', 'TableHasPrimaryKey', and
-- 'TableHasColumn' (when supplied with a function to convert a backend data
-- type to a haskell one).
sql92HsPredicateConverters :: forall fromBe
                             . Typeable fromBe
                            => (BeamSqlBackendDataTypeSyntax fromBe -> Maybe HsDataType)
                            -> HaskellPredicateConverter
sql92HsPredicateConverters convType =
  trivialHsConverter @TableExistsPredicate <>
  trivialHsConverter @TableHasPrimaryKey   <>
  hasColumnConverter @fromBe convType

-- | Converter for 'TableHasColumn', when given a function to convert backend
-- data type to a haskell one.
hasColumnConverter :: forall fromBe
                    . Typeable fromBe
                   => (BeamSqlBackendDataTypeSyntax fromBe -> Maybe HsDataType)
                   -> HaskellPredicateConverter
hasColumnConverter convType =
  hsPredicateConverter $
  \(TableHasColumn tbl col ty :: TableHasColumn fromBe) ->
    fmap SomeDatabasePredicate (TableHasColumn tbl col <$> convType ty :: Maybe (TableHasColumn HsMigrateBackend))

-- | Some predicates have no dependence on a backend. For example, 'TableExistsPredicate' has no parameters that
-- depend on the backend. It can be converted straightforwardly:
--
-- @
-- trivialHsConverter @TableExistsPredicate
-- @
trivialHsConverter :: forall pred. Typeable pred => HaskellPredicateConverter
trivialHsConverter =
  HaskellPredicateConverter $ \orig@(SomeDatabasePredicate p') ->
  case cast p' of
    Nothing -> Nothing
    Just (_ :: pred) -> Just orig

-- | Utility function for converting a monomorphically typed predicate to a
-- haskell one.
hsPredicateConverter :: Typeable pred => (pred -> Maybe SomeDatabasePredicate) -> HaskellPredicateConverter
hsPredicateConverter f =
  HaskellPredicateConverter $ \(SomeDatabasePredicate p') ->
  case cast p' of
    Nothing -> Nothing
    Just p'' -> f p''

