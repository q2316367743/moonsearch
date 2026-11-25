///|
/// Opaque POSIX directory handle. Unix paths and directory names stay as raw
/// bytes; this layer never decodes them as UTF-8.
#cfg(not(platform="windows"))
#external
pub type Directory

///|
/// Result of one raw `readdir` operation.
#cfg(not(platform="windows"))
pub enum DirectoryRead {
  End
  Name(Bytes)
  NameTooLong
  Failed(Int32)
}

///|
/// Metadata returned by `fstatat(AT_SYMLINK_NOFOLLOW)`.
#cfg(not(platform="windows"))
pub struct PosixStat {
  mode : UInt32
  size : Int64
  mtime : Int64
  mtime_nsec : Int64
  device : UInt64
  inode : UInt64
}

///|
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn posix_opendir(path : Bytes, path_len : Int32) -> Directory = "ms_posix_opendir"

///|
#cfg(not(platform="windows"))
#borrow(dir)
extern "C" fn posix_dir_is_null(dir : Directory) -> Bool = "ms_posix_dir_is_null"

///|
#cfg(not(platform="windows"))
#borrow(dir, buffer)
extern "C" fn posix_readdir(
  dir : Directory,
  buffer : FixedArray[Byte],
  capacity : Int32,
) -> Int32 = "ms_posix_readdir"

///|
#cfg(not(platform="windows"))
#borrow(dir, name, out)
extern "C" fn posix_fstatat(
  dir : Directory,
  name : Bytes,
  name_len : Int32,
  out : FixedArray[Int64],
  out_len : Int32,
) -> Int32 = "ms_posix_fstatat"

///|
#cfg(not(platform="windows"))
#borrow(path, out)
extern "C" fn posix_stat(
  path : Bytes,
  path_len : Int32,
  out : FixedArray[Int64],
  out_len : Int32,
) -> Int32 = "ms_posix_stat"

///|
#cfg(not(platform="windows"))
#owned(dir)
extern "C" fn posix_closedir(dir : Directory) -> Unit = "ms_posix_closedir"

///|
#cfg(not(platform="windows"))
#borrow(path, buffer)
extern "C" fn posix_realpath(
  path : Bytes,
  path_len : Int32,
  buffer : FixedArray[Byte],
  capacity : Int32,
) -> Int32 = "ms_posix_realpath"

///|
#cfg(not(platform="windows"))
extern "C" fn posix_errno() -> Int32 = "ms_posix_errno"

///|
/// Open a directory using a NUL-terminated copy of the supplied bytes.
#cfg(not(platform="windows"))
pub fn Directory::open(path : Bytes) -> Result[Directory, Int32] {
  let dir = posix_opendir(path, path.length())
  if posix_dir_is_null(dir) {
    Err(posix_errno())
  } else {
    Ok(dir)
  }
}

///|
/// Copy one name into the caller's reusable buffer.
#cfg(not(platform="windows"))
pub fn Directory::read_name(
  self : Directory,
  buffer : FixedArray[Byte],
) -> DirectoryRead {
  let result = posix_readdir(self, buffer, buffer.length())
  if result > 0 {
    Name(buffer.unsafe_reinterpret_as_bytes()[:result].to_owned())
  } else {
    match result {
      0 => End
      -2 => NameTooLong
      _ => Failed(posix_errno())
    }
  }
}

///|
/// Fill the caller's reusable six-`Int64` metadata buffer.
#cfg(not(platform="windows"))
pub fn Directory::stat_into(
  self : Directory,
  name : Bytes,
  out : FixedArray[Int64],
) -> Result[Unit, Int32] {
  if posix_fstatat(self, name, name.length(), out, out.length()) == 0 {
    Ok(())
  } else {
    Err(posix_errno())
  }
}

///|
/// Inspect a path, following a symlink at the path itself.
#cfg(not(platform="windows"))
pub fn stat_path(path : Bytes, out : FixedArray[Int64]) -> Result[Unit, Int32] {
  if posix_stat(path, path.length(), out, out.length()) == 0 {
    Ok(())
  } else {
    Err(posix_errno())
  }
}

///|
/// Decode the fixed layout written by `Directory::stat_into`.
#cfg(not(platform="windows"))
pub fn PosixStat::from_buffer(out : FixedArray[Int64]) -> PosixStat {
  {
    mode: out[0].reinterpret_as_uint64().to_uint(),
    size: out[1],
    mtime: out[2],
    mtime_nsec: out[3],
    device: out[4].reinterpret_as_uint64(),
    inode: out[5].reinterpret_as_uint64(),
  }
}

///|
#cfg(not(platform="windows"))
pub fn Directory::close(self : Directory) -> Unit {
  posix_closedir(self)
}

///|
/// Resolve a root without decoding its bytes. The 64 KiB bound is far above
/// native Unix path limits and keeps the allocation explicit.
#cfg(not(platform="windows"))
pub fn canonical_path(path : Bytes) -> Result[Bytes, Int32] {
  let buffer = FixedArray::make(65_536, b'\x00')
  let result = posix_realpath(path, path.length(), buffer, buffer.length())
  if result == 0 {
    let length = buffer_length(buffer)
    Ok(buffer.unsafe_reinterpret_as_bytes()[:length].to_owned())
  } else if result == -2 {
    Err(-2)
  } else {
    Err(posix_errno())
  }
}

///|
#cfg(not(platform="windows"))
fn buffer_length(buffer : FixedArray[Byte]) -> Int32 {
  let mut length = 0
  while length < buffer.length() && buffer[length] != 0 {
    length = length + 1
  }
  length
}
