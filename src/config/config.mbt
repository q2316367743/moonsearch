///|
/// A root directory from the configuration file.
pub struct RootConfig {
  path : String
  /// Overrides the top-level `one_file_system` default for this root.
  one_file_system : Bool?
}

///|
/// Build a configured root.
pub fn RootConfig::new(
  path~ : String,
  one_file_system~ : Bool? = None,
) -> RootConfig {
  { path, one_file_system, }
}

///|
/// One configured exclusion rule.
pub struct ExcludeConfig {
  pattern : String
  kind : @index.ExcludeKind
  scope : @index.ExcludeScope
  target : @index.ExcludeTarget
  active : Bool
}

///|
/// Build a configured exclusion rule.
pub fn ExcludeConfig::new(
  pattern~ : String,
  kind~ : @index.ExcludeKind = @index.Glob,
  scope~ : @index.ExcludeScope = @index.FullPath,
  target~ : @index.ExcludeTarget = @index.Both,
  active~ : Bool = true,
) -> ExcludeConfig {
  { pattern, kind, scope, target, active, }
}

///|
/// Search defaults. Command-line options override these values.
pub struct SearchConfig {
  sort : String
  limit : Int32
  reverse : Bool
  folders_first : Bool
  kind : @query.KindFilter
  case_sensitive : Bool
  exact : Bool
  search_path : Bool
  regex : Bool
}

///|
/// Default search behavior.
pub fn SearchConfig::new() -> SearchConfig {
  {
    sort: "name",
    limit: 0,
    reverse: false,
    folders_first: false,
    kind: @query.AnyKind,
    case_sensitive: false,
    exact: false,
    search_path: false,
    regex: false,
  }
}

///|
/// A validated configuration file.
///
/// Optional top-level booleans stay optional so `update` can distinguish an
/// absent setting from an explicit `false` when it reuses roots from an existing
/// database.
pub struct Config {
  database : String?
  roots : Array[RootConfig]
  exclude_hidden : Bool
  excludes : Array[ExcludeConfig]
  exclude_scope : @index.ExcludeScope
  exclude_target : @index.ExcludeTarget
  macros : @query.Macros
  search : SearchConfig
  /// `scan` or `bitmap`; `None` uses the CLI default.
  engine : String?
  /// Range fields materialized eagerly while building an index.
  fast_fields : Array[@index.RangeField]?
  /// `None` uses the CLI default and enables trigram postings.
  trigram : Bool?
  one_file_system : Bool?
  allow_nested_roots : Bool?
  default_excludes : Bool?
  unreadable_directories : @index.UnreadableDirectoryPolicy
}

///|
/// The empty configuration, equivalent to no configuration file.
pub fn Config::default() -> Config {
  {
    database: None,
    roots: [],
    exclude_hidden: false,
    excludes: [],
    exclude_scope: @index.FullPath,
    exclude_target: @index.Both,
    macros: @query.Macros::new(),
    search: SearchConfig::new(),
    engine: None,
    fast_fields: None,
    trigram: None,
    one_file_system: None,
    allow_nested_roots: None,
    default_excludes: None,
    unreadable_directories: @index.Continue,
  }
}

///|
/// Configuration failures shown directly by the CLI.
pub suberror ConfigError {
  Read(String)
  Invalid(String)
}

///|
/// Human-readable configuration error.
pub fn ConfigError::message(self : ConfigError) -> String {
  match self {
    Read(message) => message
    Invalid(message) => message
  }
}
