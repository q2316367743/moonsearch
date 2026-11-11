///|
/// Kind of a directory entry as reported by `lstat`.
///
/// Symbolic links are never followed by the scanner: a link to a directory is
/// listed as a `Symlink` entry, not descended into.
pub(all) enum NodeKind {
  Directory
  File
  Symlink
  /// Sockets, pipes, block and character devices.
  Other
}

///|
/// One file system entry with the metadata the scanner needs.
///
/// `size` is the file size for regular files and zero for directories and
/// special files. For symbolic links it is also zero: the link itself occupies
/// no searchable bytes and counting the target would double count it.
pub(all) struct NodeInfo {
  name : String
  kind : NodeKind
  size : Int64
  mtime : Int64
  /// Device id (`st_dev`) when the backend can supply one.
  ///
  /// The pure MoonBit backend cannot read `st_dev`, so it reports `None`; the
  /// scanner then treats every entry as being on the root device. A POSIX FFI
  /// backend fills this in later without changing the scanner.
  device : UInt64?
}

///|
/// Build a `NodeInfo` explicitly, for backends and tests.
pub fn NodeInfo::new(
  name~ : String,
  kind~ : NodeKind,
  size~ : Int64 = 0L,
  mtime~ : Int64 = 0L,
  device~ : UInt64? = None,
) -> NodeInfo {
  { name, kind, size, mtime, device, }
}

///|
/// Build a directory listing, for backends and tests.
pub fn DirListing::new(
  entries~ : Array[NodeInfo],
  failures~ : Array[DirFailure] = [],
) -> DirListing {
  { entries, failures, }
}

///|
/// A directory entry that could not be inspected.
///
/// The most common cause is a race: the entry disappeared between `readdir` and
/// `lstat`. The scanner records the failure and keeps going instead of failing
/// the whole scan.
pub(all) struct DirFailure {
  name : String
  message : String
}

///|
/// Record an entry that could not be inspected.
pub fn DirFailure::new(name~ : String, message~ : String) -> DirFailure {
  { name, message, }
}

///|
/// Result of listing one directory.
///
/// `entries` is in whatever order the backend produced; the scanner sorts by
/// name before assigning ids, so `readdir` order never reaches the index.
pub(all) struct DirListing {
  entries : Array[NodeInfo]
  failures : Array[DirFailure]
}

///|
/// Errors raised by the platform layer while reading the file system.
///
/// These are I/O conditions, not index corruption; the scanner decides which of
/// them are recoverable. Every variant carries the path (and possibly the
/// underlying message) for logging.
pub suberror PlatformError {
  NotFound(String)
  AccessDenied(String)
  NotDirectory(String)
  Unsupported(String)
  Io(String)
}

///|
/// The file system operations the scanner needs.
///
/// Keeping the scanner generic over this trait has two benefits: the async
/// backend can be replaced by a POSIX FFI implementation later, and tests can
/// build directory trees in memory without touching the real file system.
pub(open) trait ScanSource {
  /// List the children of `path` without following symlinks.
  ///
  /// The order is irrelevant: the scanner sorts by name.
  ///
  /// Raises only when the directory itself cannot be opened or read.
  async fn list(Self, StringView) -> DirListing raise PlatformError

  /// Metadata of `path` itself, following a symlink at the root.
  ///
  /// Raises `NotDirectory` when the path is not a directory.
  async fn stat(Self, StringView) -> NodeInfo raise PlatformError

  /// Whether `NodeInfo::device` carries a real device id.
  ///
  /// `--one-file-system` is only enforceable when this is true.
  fn has_devices(Self) -> Bool

  /// Resolve a configured root to an absolute path with symlinks removed.
  ///
  /// Raising `NotFound` here means the configured root does not exist.
  async fn realpath(Self, StringView) -> String raise PlatformError
}

///|
/// Build a `NotFound` error outside the platform package.
pub fn PlatformError::not_found(message : String) -> PlatformError {
  NotFound(message)
}

///|
/// Build an `AccessDenied` error outside the platform package.
pub fn PlatformError::access_denied(message : String) -> PlatformError {
  AccessDenied(message)
}

///|
/// Human-readable text of a platform error.
pub fn PlatformError::message(self : PlatformError) -> String {
  match self {
    NotFound(message) => message
    AccessDenied(message) => message
    NotDirectory(message) => message
    Unsupported(message) => message
    Io(message) => message
  }
}
