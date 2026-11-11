///|
/// Public facade for the `moonsearch` library.
///
/// S02 exposes the byte-level building blocks that later steps share: the name
/// pool and entry model from `core`, and the byte/path helpers from `util`.
/// Later steps add the store, index, query, and execution APIs.
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
  MAX_NAME_LEN,
  type NamePool,
  type NamePoolError,
  type NameRef,
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
}
