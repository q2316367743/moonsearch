///|
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn test_mkdir(path : Bytes, path_len : Int32) -> Int32 = "ms_test_mkdir"

///|
#cfg(not(platform="windows"))
#borrow(path, contents)
extern "C" fn test_create_file(
  path : Bytes,
  path_len : Int32,
  contents : Bytes,
  contents_len : Int32,
) -> Int32 = "ms_test_create_file"

///|
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn test_unlink(path : Bytes, path_len : Int32) -> Int32 = "ms_test_unlink"

///|
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn test_rmdir(path : Bytes, path_len : Int32) -> Int32 = "ms_test_rmdir"

///|
#cfg(not(platform="windows"))
fn write_test_file(path : Bytes, contents : Bytes) -> Unit {
  if test_create_file(path, path.length(), contents, contents.length()) != 0 {
    abort("create file failed")
  }
}

///|
#cfg(not(platform="windows"))
test "POSIX readdir and fstatat preserve names as bytes" {
  let root = b"_build/platform-posix-byte-test"
  let first = b"_build/platform-posix-byte-test/first.bin"
  let second = b"_build/platform-posix-byte-test/second.bin"
  ignore(test_unlink(first, first.length()))
  ignore(test_unlink(second, second.length()))
  ignore(test_rmdir(root, root.length()))
  if test_mkdir(root, root.length()) != 0 {
    abort("mkdir failed")
  }
  defer {
    ignore(test_unlink(first, first.length()))
    ignore(test_unlink(second, second.length()))
    ignore(test_rmdir(root, root.length()))
  }
  write_test_file(first, b"abc")
  write_test_file(second, b"hello")
  let dir = @platform.Directory::open(root).unwrap()
  defer dir.close()
  let buffer = FixedArray::make(65_536, b'\x00')
  let metadata = FixedArray::make(6, 0L)
  let names : Array[Bytes] = []
  let sizes : Array[Int64] = []
  while true {
    match dir.read_name(buffer) {
      End => break
      NameTooLong => abort("unexpected long name")
      Failed(_) => abort("readdir failed")
      Name(name) => {
        if name == b"." || name == b".." {
          continue
        }
        dir.stat_into(name, metadata).unwrap()
        names.push(name)
        sizes.push(@platform.PosixStat::from_buffer(metadata).size)
      }
    }
  }
  assert_eq(names.length(), 2)
  let first_name = first[first.length() - 9:].to_owned()
  let second_name = second[second.length() - 10:].to_owned()
  assert_true(names.contains(first_name))
  assert_true(names.contains(second_name))
  assert_true(sizes.contains(3L))
  assert_true(sizes.contains(5L))
}

///|
#cfg(platform="linux")
test "POSIX readdir keeps distinct invalid UTF-8 names" {
  let root = b"_build/platform-posix-invalid-test"
  let first = b"_build/platform-posix-invalid-test/bad-\xff"
  let second = b"_build/platform-posix-invalid-test/bad-\xfe"
  ignore(test_unlink(first, first.length()))
  ignore(test_unlink(second, second.length()))
  ignore(test_rmdir(root, root.length()))
  if test_mkdir(root, root.length()) != 0 {
    abort("mkdir failed")
  }
  defer {
    ignore(test_unlink(first, first.length()))
    ignore(test_unlink(second, second.length()))
    ignore(test_rmdir(root, root.length()))
  }
  write_test_file(first, b"abc")
  write_test_file(second, b"hello")
  let dir = @platform.Directory::open(root).unwrap()
  defer dir.close()
  let buffer = FixedArray::make(65_536, b'\x00')
  let names : Array[Bytes] = []
  while true {
    match dir.read_name(buffer) {
      End => break
      NameTooLong => abort("unexpected long name")
      Failed(_) => abort("readdir failed")
      Name(name) => {
        if name != b"." && name != b".." {
          names.push(name)
        }
      }
    }
  }
  assert_eq(names.length(), 2)
  assert_true(names.contains(b"bad-\xff"))
  assert_true(names.contains(b"bad-\xfe"))
}

///|
#cfg(not(platform="windows"))
test "POSIX canonical path handles root and trailing separators as bytes" {
  assert_eq(@platform.canonical_path(b"/").unwrap(), b"/")
  let root = @platform.canonical_path(b"/").unwrap()
  let trailing = @platform.canonical_path(b"/./").unwrap()
  assert_eq(trailing, root)
  let double = @platform.canonical_path(b"//").unwrap()
  assert_true(double == b"/" || double == b"//")
}
