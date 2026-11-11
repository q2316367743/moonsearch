///|
/// The production scan source, backed by `moonbitlang/core/async/fs`.
///
/// This is the "stage A" backend from the migration plan: it uses path-based
/// syscalls, decodes names to `String` (so invalid UTF-8 names are mangled by
/// the runtime), and cannot read `st_dev`. A POSIX FFI backend will replace the
/// implementation later without changing `ScanSource`.
pub(all) struct SystemScanSource {
  priv marker : Unit
}

///|
/// Create a scan source that reads the real file system.
pub fn SystemScanSource::new() -> SystemScanSource {
  { marker: (), }
}

///|
/// Convenience constructor used by the CLI and integration tests.
pub fn system_source() -> SystemScanSource {
  SystemScanSource::new()
}

///|
/// Convert an `OsError` (or any other error) into a platform error.
///
/// Messages describe the condition only; the caller knows the path and adds it
/// when reporting, which avoids printing the same path twice.
fn to_platform_error(err : Error) -> PlatformError {
  match err {
    @os_error.OsError(NotFound, ..) => NotFound("no such file or directory")
    @os_error.OsError(AccessDenied, ..) => AccessDenied("permission denied")
    @os_error.OsError(NotDirectory, ..) => NotDirectory("not a directory")
    @os_error.OsError(OperationNotSupported, ..) =>
      Unsupported("operation not supported")
    _ => Io("\{err}")
  }
}

///|
/// Inspect one directory entry without following symlinks.
///
/// A failure returns `Err` instead of raising so a single vanished entry does
/// not abort the listing.
async fn inspect_entry(
  path : StringView,
  name : String,
) -> Result[NodeInfo, String] {
  let kind = @fs.kind(path, follow_symlink=false) catch {
    err => return Err(to_platform_error(err).message())
  }
  let node_kind = match kind {
    Directory => Directory
    Regular => File
    SymLink => Symlink
    _ => Other
  }
  let mtime = @fs.mtime(path, follow_symlink=false) catch {
    err => return Err(to_platform_error(err).message())
  }
  let size = if node_kind is File {
    @fs.file_size(path) catch {
      err => return Err(err.to_string())
    }
  } else {
    0L
  }
  Ok({ name, kind: node_kind, size, mtime: mtime.sec(), device: None, })
}

///|
pub extend SystemScanSource with ScanSource::{list, stat, has_devices, realpath}

///|
pub impl ScanSource for SystemScanSource with fn has_devices(self) -> Bool {
  ignore(self.marker)
  false
}

///|
pub impl ScanSource for SystemScanSource with fn realpath(_, path) -> String raise PlatformError {
  @fs.realpath(path) catch {
    err => raise to_platform_error(err)
  }
}

///|
pub impl ScanSource for SystemScanSource with fn stat(_, path) -> NodeInfo raise PlatformError {
  let kind = @fs.kind(path) catch { err => raise to_platform_error(err) }
  guard kind is Directory else {
    raise NotDirectory("\{path}: not a directory")
  }
  let mtime = @fs.mtime(path) catch { err => raise to_platform_error(err) }
  {
    name: "\{path}",
    kind: Directory,
    size: 0L,
    mtime: mtime.sec(),
    device: None,
  }
}

///|
pub impl ScanSource for SystemScanSource with fn list(_, path) -> DirListing raise PlatformError {
  let dir = @fs.opendir(path) catch { err => raise to_platform_error(err) }
  defer dir.close()
  let entries : Array[NodeInfo] = []
  let failures : Array[DirFailure] = []
  let mut done = false
  while !done {
    let next = dir.next() catch { err => raise to_platform_error(err) }
    match next {
      None => done = true
      Some(entry) => {
        let child = @util.join_path(path, entry.name)
        let inspected = inspect_entry(child, entry.name) catch {
          err => Err(err.to_string())
        }
        match inspected {
          Ok(info) => entries.push(info)
          Err(message) => failures.push({ name: entry.name, message, })
        }
      }
    }
  }
  { entries, failures, }
}
