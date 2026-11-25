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
  @fs.chmod(locked, 0o755)
  @fs.remove(dir, recursive=true)
  if denied {
    assert_eq(report.issues.length(), 1)
    assert_true(@util.contains_bytes(report.issues[0].path[:], b"locked"))
    // open.txt is still indexed; locked/secret is not.
    assert_eq(report.store.file_count(), 1)
    assert_eq(report.store.folder_count(), 2)
  } else {
    assert_eq(report.issues.length(), 0)
    assert_eq(report.store.file_count(), 2)
  }
}
