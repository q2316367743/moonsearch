///|
async test "system backend normalizes trailing and dot root aliases" {
  let dir = @fs.tmpdir(prefix="moonsearch-alias")
  @fs.write_text("\{dir}/a.txt", "a")
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path=@utf8.encode(dir)),
    @index.RootSpec::new(path=@utf8.encode("\{dir}/.")),
    @index.RootSpec::new(path=@utf8.encode("\{dir}/")),
  ])
  let report = @index.scan(config, @platform.system_source()) catch {
    err => abort(err.message())
  }
  let expected = @utf8.encode(@fs.realpath(dir))
  @fs.remove(dir, recursive=true)
  assert_eq(report.store.roots().length(), 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.roots()[0].path, expected)
}

///|
#cfg(not(platform="windows"))
test "POSIX system source reports real device ids" {
  assert_true(@platform.system_source().has_devices())
}

///|
#cfg(not(platform="windows"))
async test "POSIX symlinks record their own target length without following" {
  let dir = @fs.tmpdir(prefix="moonsearch-symlink")
  @fs.mkdir("\{dir}/target")
  @fs.write_binary("\{dir}/target/large.bin", Bytes::make(4096, b'x')[:])
  @fs.symlink(target="target", "\{dir}/link")
  @fs.symlink(target="missing-target", "\{dir}/dangling")
  let root = @fs.realpath(dir)
  let report = @index.scan(
    @index.ScanConfig::new(roots=[@index.RootSpec::new(path=@utf8.encode(root))]),
    @platform.system_source(),
  ) catch {
    err => abort(err.message())
  }
  @fs.remove(dir, recursive=true)
  assert_true(report.device_ids_available)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 3)
  let link_path = @utf8.encode("\{root}/link")
  let dangling_path = @utf8.encode("\{root}/dangling")
  let mut link_size = -1L
  let mut dangling_size = -1L
  for id in 0..<report.store.file_count() {
    let entry = report.store.file(id).unwrap()
    let path = report.store.file_path(id)
    if path == link_path {
      assert_true(entry.is_symlink())
      link_size = entry.size()
    } else if path == dangling_path {
      assert_true(entry.is_symlink())
      dangling_size = entry.size()
    }
  }
  assert_eq(link_size, @utf8.encode("target").length().to_int64())
  assert_eq(dangling_size, @utf8.encode("missing-target").length().to_int64())
  assert_eq(report.store.total_size(), 4096L + link_size + dangling_size)
  assert_eq(report.store.roots()[0].size, report.store.total_size())
}

///|
/// The system backend must turn an unreadable directory into a scan issue and
/// keep indexing its siblings.
///
/// The permission assertion is skipped when the test runs as root (or on a file
/// system that ignores permissions), because then the directory stays readable
/// and nothing should be denied.
async test "system backend reports unreadable directories as issues" {
  let dir = @fs.tmpdir(prefix="moonsearch-perm")
  let locked = "\{dir}/locked"
  @fs.mkdir(locked)
  @fs.write_text("\{locked}/secret", "x")
  @fs.write_text("\{dir}/open.txt", "hi")
  @fs.chmod(locked, 0o000)
  let denied = !@fs.can_read(locked)
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=@utf8.encode(dir))],
    default_excludes=false,
  )
  let report = @index.scan(config, @platform.system_source()) catch {
    err => abort(err.message())
  }
  if denied {
    assert_eq(report.issues.length(), 1)
    assert_true(@util.contains_bytes(report.issues[0].path[:], b"locked"))
    // open.txt is still indexed; locked/secret is not.
    assert_eq(report.store.file_count(), 1)
    assert_eq(report.store.folder_count(), 2)
    let fatal = try
      @index.scan(
        @index.ScanConfig::new(
          roots=[@index.RootSpec::new(path=@utf8.encode(dir))],
          default_excludes=false,
          unreadable_directories=@index.Fatal,
        ),
        @platform.system_source(),
      )
    catch {
      err => err
    } noraise {
      _ => abort("expected fatal unreadable directory")
    }
    match fatal {
      @index.UnreadableDirectory(path) =>
        assert_true(@util.contains_bytes(path[:], b"locked"))
      _ => abort("expected UnreadableDirectory")
    }
  } else {
    assert_eq(report.issues.length(), 0)
    assert_eq(report.store.file_count(), 2)
  }
  @fs.chmod(locked, 0o755)
  @fs.remove(dir, recursive=true)
}
