///|
/// Errors raised by scanning and index building.
///
/// Recoverable conditions (an unreadable subdirectory, a vanished entry, a name
/// that no longer fits) are reported as `ScanIssue`s instead; these variants
/// abort the command and map to exit code 2.
pub suberror IndexError {
  /// A configured root does not exist or cannot be resolved.
  RootMissing(Bytes)
  /// A configured root exists but is not a directory.
  RootNotDirectory(Bytes)
  /// `nested` lies inside `outer` and nested roots were not allowed.
  NestedRoots(outer~ : Bytes, nested~ : Bytes)
  /// A directory could not be read and the configured policy makes it fatal.
  UnreadableDirectory(Bytes)
  /// A name does not fit in the `UInt16` length field.
  NameTooLong(Int32)
  /// The name pool reached its 32-bit offset limit.
  NamePoolFull
  /// Any other I/O failure that makes the scan useless.
  Io(String)
}

///|
/// Human-readable text of an index error.
pub fn IndexError::message(self : IndexError) -> String {
  match self {
    RootMissing(path) => "root does not exist: \{@utf8.decode_lossy(path)}"
    RootNotDirectory(path) =>
      "root is not a directory: \{@utf8.decode_lossy(path)}"
    NestedRoots(outer~, nested~) =>
      "root \{@utf8.decode_lossy(nested)} is inside \{@utf8.decode_lossy(outer)}; pass --allow-nested-roots to index both"
    UnreadableDirectory(path) =>
      "directory is not readable: \{@utf8.decode_lossy(path)}"
    NameTooLong(length) => "a name is too long (\{length} bytes)"
    NamePoolFull => "the name pool reached its 32-bit offset limit"
    Io(message) => message
  }
}
