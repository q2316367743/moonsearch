///|
/// The real file system scan source.
///
/// Unix uses the byte-preserving POSIX backend in `posix.mbt`. Windows keeps the
/// async/fs fallback, where OS paths are UTF-16 and the runtime performs the
/// necessary conversion at this boundary.
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
/// Convert a Windows `OsError` into a platform error.
#cfg(platform="windows")
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
/// Map a POSIX errno to the platform error model without decoding the path.
#cfg(not(platform="windows"))
fn posix_error(code : Int32) -> PlatformError {
  match code {
    2 => NotFound("no such file or directory")
    13 => AccessDenied("permission denied")
    20 => NotDirectory("not a directory")
    45 | 95 => Unsupported("operation not supported")
    _ => Io("filesystem I/O failed (errno \{code})")
  }
}

///|
/// Classify the `st_mode` value written by the POSIX stub.
#cfg(not(platform="windows"))
fn posix_kind(mode : UInt32) -> NodeKind {
  match mode & 0o170000U {
    0o040000U => Directory
    0o100000U => File
    0o120000U => Symlink
    _ => Other
  }
}

///|
#cfg(not(platform="windows"))
fn system_list_posix(path : BytesView) -> DirListing raise PlatformError {
  let owned = path.to_owned()
  let dir = match Directory::open(owned) {
    Ok(dir) => dir
    Err(code) => raise posix_error(code)
  }
  defer dir.close()
  let entries : Array[NodeInfo] = []
  let failures : Array[DirFailure] = []
  let names = FixedArray::make(65_536, b'\x00')
  let metadata = FixedArray::make(6, 0L)
  while true {
    match dir.read_name(names) {
      End => break
      NameTooLong =>
        failures.push(
          DirFailure::new(
            name=b"",
            message="directory name exceeds 65535 bytes",
          ),
        )
      Failed(code) => raise posix_error(code)
      Name(name) => {
        if name == b"." || name == b".." {
          continue
        }
        match dir.stat_into(name, metadata) {
          Err(code) =>
            failures.push(
              DirFailure::new(name~, message=posix_error(code).message()),
            )
          Ok(_) => {
            let info = PosixStat::from_buffer(metadata)
            let kind = posix_kind(info.mode)
            let size = match kind {
              File | Symlink => info.size
              _ => 0L
            }
            entries.push(
              NodeInfo::new(
                name~,
                kind~,
                size~,
                mtime=info.mtime,
                device=Some(info.device),
              ),
            )
          }
        }
      }
    }
  }
  { entries, failures, }
}

///|
#cfg(not(platform="windows"))
fn system_stat_posix(path : BytesView) -> NodeInfo raise PlatformError {
  let owned = path.to_owned()
  let metadata = FixedArray::make(6, 0L)
  match stat_path(owned, metadata) {
    Err(code) => raise posix_error(code)
    Ok(_) => ()
  }
  let info = PosixStat::from_buffer(metadata)
  let kind = posix_kind(info.mode)
  guard kind is Directory else { raise NotDirectory("root is not a directory") }
  NodeInfo::new(
    name=owned,
    kind=Directory,
    mtime=info.mtime,
    device=Some(info.device),
  )
}

///|
#cfg(not(platform="windows"))
fn system_realpath_posix(path : BytesView) -> Bytes raise PlatformError {
  match canonical_path(path.to_owned()) {
    Ok(path) => path
    Err(-2) => raise Io("root path exceeds the platform path limit")
    Err(code) => raise posix_error(code)
  }
}

///|
/// Inspect one Windows directory entry without following symlinks.
#cfg(platform="windows")
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
  Ok(
    NodeInfo::new(
      name=@utf8.encode(name),
      kind=node_kind,
      size~,
      mtime=mtime.sec(),
      device=None,
    ),
  )
}

///|
#cfg(platform="windows")
async fn system_list_windows(
  path : BytesView,
) -> DirListing raise PlatformError {
  let text = @utf8.decode_lossy(path)
  let dir = @fs.opendir(text) catch { err => raise to_platform_error(err) }
  defer dir.close()
  let entries : Array[NodeInfo] = []
  let failures : Array[DirFailure] = []
  let mut done = false
  while !done {
    let next = dir.next() catch { err => raise to_platform_error(err) }
    match next {
      None => done = true
      Some(entry) => {
        let parent = @utf8.encode(text)
        let name = @utf8.encode(entry.name)
        let child = @util.join_path(parent[:], name[:])
        let inspected = inspect_entry(@utf8.decode_lossy(child), entry.name) catch {
          err => Err(err.to_string())
        }
        match inspected {
          Ok(info) => entries.push(info)
          Err(message) => failures.push(DirFailure::new(name~, message~))
        }
      }
    }
  }
  { entries, failures, }
}

///|
#cfg(platform="windows")
async fn system_stat_windows(path : BytesView) -> NodeInfo raise PlatformError {
  let text = @utf8.decode_lossy(path)
  let kind = @fs.kind(text) catch { err => raise to_platform_error(err) }
  guard kind is Directory else { raise NotDirectory("root is not a directory") }
  let mtime = @fs.mtime(text) catch { err => raise to_platform_error(err) }
  NodeInfo::new(name=path, kind=Directory, mtime=mtime.sec(), device=None)
}

///|
#cfg(platform="windows")
async fn system_realpath_windows(path : BytesView) -> Bytes raise PlatformError {
  let text = @utf8.decode_lossy(path)
  let resolved = @fs.realpath(text) catch {
    err => raise to_platform_error(err)
  }
  @utf8.encode(resolved)
}

///|
#cfg(not(platform="windows"))
fn backend_list(path : BytesView) -> DirListing raise PlatformError {
  system_list_posix(path)
}

///|
#cfg(not(platform="windows"))
fn backend_stat(path : BytesView) -> NodeInfo raise PlatformError {
  system_stat_posix(path)
}

///|
#cfg(not(platform="windows"))
fn backend_realpath(path : BytesView) -> Bytes raise PlatformError {
  system_realpath_posix(path)
}

///|
#cfg(platform="windows")
async fn backend_list(path : BytesView) -> DirListing raise PlatformError {
  system_list_windows(path)
}

///|
#cfg(platform="windows")
async fn backend_stat(path : BytesView) -> NodeInfo raise PlatformError {
  system_stat_windows(path)
}

///|
#cfg(platform="windows")
async fn backend_realpath(path : BytesView) -> Bytes raise PlatformError {
  system_realpath_windows(path)
}

///|
pub extend SystemScanSource with ScanSource::{list, stat, has_devices, realpath}

///|
#cfg(not(platform="windows"))
pub impl ScanSource for SystemScanSource with fn has_devices(self) -> Bool {
  ignore(self.marker)
  true
}

///|
#cfg(platform="windows")
pub impl ScanSource for SystemScanSource with fn has_devices(self) -> Bool {
  ignore(self.marker)
  false
}

///|
pub impl ScanSource for SystemScanSource with fn realpath(_, path) -> Bytes raise PlatformError {
  backend_realpath(path)
}

///|
pub impl ScanSource for SystemScanSource with fn stat(_, path) -> NodeInfo raise PlatformError {
  backend_stat(path)
}

///|
pub impl ScanSource for SystemScanSource with fn list(_, path) -> DirListing raise PlatformError {
  backend_list(path)
}
