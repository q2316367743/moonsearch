///|
/// Public facade for the `moonsearch` library.
///
/// S04 adds the query language on top of the scanner stack: the lexer, the
/// precedence-climbing parser, the typed `Query` tree, term flags, value
/// parsing, and macro expansion. Later steps add the execution engines and
/// persistence.
pub using @core {
  VERSION,
  VERSION_TEXT,
  EXIT_OK,
  EXIT_NO_MATCH,
  EXIT_ERROR,
  EXIT_INTERRUPTED,
  type Entry,
  type EntryKind,
  type EntryId,
  type FolderId,
  NO_PARENT,
  ENTRY_FLAG_HIDDEN,
  ENTRY_FLAG_SYMLINK,
  ENTRY_FLAG_SPECIAL,
  MAX_NAME_LEN,
  type NamePool,
  type NamePoolError,
  type NameRef,
  type RootInfo,
  type Store,
}

///|
pub using @util {
  cmp_paths,
  is_ascii_digit,
  is_ascii_upper,
  is_ascii_lower,
  is_ascii_alpha,
  ascii_lower,
  ascii_upper,
  ascii_fold,
  eq_ignore_ascii_case,
  starts_with,
  ends_with,
  find_byte,
  find_bytes,
  contains_bytes,
  join_path,
  is_within,
  glob_match,
}

///|
pub using @platform {
  type DirFailure,
  type DirListing,
  type NodeInfo,
  type NodeKind,
  type PlatformError,
  trait ScanSource,
  type SystemScanSource,
  system_source,
}

///|
pub using @index {
  type Builder,
  type ExcludeKind,
  type ExcludeRule,
  type ExcludeScope,
  type ExcludeTarget,
  type IndexError,
  type RootSpec,
  type ScanConfig,
  type ScanIssue,
  type ScanReport,
  scan,
}

///|
pub using @query {
  type CmpOp,
  type Comparison,
  type DateComparison,
  type Flags,
  type KindFilter,
  type Macro,
  type Macros,
  type Query,
  type QueryError,
  type Term,
  type TermBody,
  type Token,
  type TokenKind,
  lex,
  parse,
  parse_count,
  parse_count_comparison,
  parse_date_comparison,
  parse_size,
  parse_size_comparison,
}
