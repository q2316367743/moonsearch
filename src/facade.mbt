///|
/// Public facade for the `moonsearch` library.
///
/// S03 adds the scanner stack on top of the S02 byte-level model: the platform
/// abstraction over the async file system, and the index builder/scanner that
/// turns a directory tree into an immutable in-memory `Store`. Later steps add
/// the query, execution, and persistence APIs.
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
