///|
/// Public facade for the `moonsearch` library.
///
/// S04 added the query language on top of the scanner stack: the lexer, the
/// precedence-climbing parser, the typed `Query` tree, term flags, value
/// parsing, and macro expansion. S05 adds the scan engine that evaluates a
/// compiled query against a store, including date resolution in the local time
/// zone. S06 adds the `Ids` set algebra and the compressed bitmap containers
/// that the bitmap engine will evaluate on. Later steps add the field indexes
/// and persistence.
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
  type EntryRef,
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
pub using @ids {
  BITMAP_BLOCK_SIZE,
  BITMAP_BLOCK_SHIFT,
  BITMAP_BLOCK_MASK,
  BITMAP_WORDS,
  BITMAP_WORD_BITS,
  BITMAP_MAX_BLOCK,
  CONTAINER_ARRAY_MAX,
  IDS_SORTED_MAX,
  IDS_DENSITY_DIVISOR,
  type Bitmap,
  type Ids,
  type IdsError,
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
  find_bytes_with,
  contains_bytes,
  contains_bytes_with,
  eq_bytes,
  has_glob_meta,
  join_path,
  is_within,
  glob_match,
  glob_match_with,
  type DateSpan,
  current_unix_seconds,
  local_zone,
  resolve_date_span,
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
  bad_regex,
  bad_value,
  kind_query,
  lex,
  name_query,
  parse,
  parse_count,
  parse_count_comparison,
  parse_date_comparison,
  parse_size,
  parse_size_comparison,
}

///|
pub using @exec {
  type ScanOptions,
  exec_count,
  exec_count_with,
  exec_scan,
  exec_scan_with,
  explain_query,
}
