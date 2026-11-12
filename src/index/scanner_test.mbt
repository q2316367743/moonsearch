///|
/// An in-memory scan source used by the scanner tests.
///
/// It implements the same `ScanSource` trait as the async file system backend,
/// so the tests exercise the real recursion, exclusion, and statistics logic
/// without touching the disk.
struct FakeSource {
  dirs : Map[String, @platform.DirListing]
  stats : Map[String, @platform.NodeInfo]
  missing : Array[String]
  denied : Array[String]
  io_errors : Map[String, String]
  realpath_io_errors : Map[String, String]
  mut devices : Bool
}

///|
fn fake_source() -> FakeSource {
  {
    dirs: Map([]),
    stats: Map([]),
    missing: [],
    denied: [],
    io_errors: Map([]),
    realpath_io_errors: Map([]),
    devices: true,
  }
}

///|
fn FakeSource::root(self : FakeSource, path : String) -> FakeSource {
  self.stats.set(
    path,
    @platform.NodeInfo::new(name=path, kind=@platform.Directory, mtime=100L),
  )
  self
}

///|
fn FakeSource::root_on_device(
  self : FakeSource,
  path : String,
  device : UInt64,
) -> FakeSource {
  self.stats.set(
    path,
    @platform.NodeInfo::new(
      name=path,
      kind=@platform.Directory,
      mtime=100L,
      device=Some(device),
    ),
  )
  self
}

///|
fn FakeSource::file_root(self : FakeSource, path : String) -> FakeSource {
  self.stats.set(
    path,
    @platform.NodeInfo::new(name=path, kind=@platform.File, size=1L, mtime=1L),
  )
  self
}

///|
fn FakeSource::dir(
  self : FakeSource,
  path : String,
  entries : Array[@platform.NodeInfo],
) -> FakeSource {
  ignore(self.root(path))
  self.dirs.set(path, @platform.DirListing::new(entries~))
  self
}

///|
fn FakeSource::deny(self : FakeSource, path : String) -> FakeSource {
  ignore(self.root(path))
  self.denied.push(path)
  self
}

///|
fn FakeSource::fail_io(
  self : FakeSource,
  path : String,
  message : String,
) -> FakeSource {
  self.io_errors.set(path, message)
  self
}

///|
fn FakeSource::fail_realpath_io(
  self : FakeSource,
  path : String,
  message : String,
) -> FakeSource {
  self.realpath_io_errors.set(path, message)
  self
}

///|
fn FakeSource::without_devices(self : FakeSource) -> FakeSource {
  self.devices = false
  self
}

///|
impl @platform.ScanSource for FakeSource with fn has_devices(self) -> Bool {
  self.devices
}

///|
impl @platform.ScanSource for FakeSource with fn realpath(self, path) -> String raise @platform.PlatformError {
  let key = "\{path}"
  match self.realpath_io_errors.get(key) {
    Some(message) => raise @platform.PlatformError::io(message)
    None => ()
  }
  if self.missing.contains(key) {
    raise @platform.PlatformError::not_found(key)
  }
  key
}

///|
impl @platform.ScanSource for FakeSource with fn stat(self, path) -> @platform.NodeInfo raise @platform.PlatformError {
  let key = "\{path}"
  match self.io_errors.get(key) {
    Some(message) => raise @platform.PlatformError::io(message)
    None => ()
  }
  match self.stats.get(key) {
    Some(info) => info
    None => raise @platform.PlatformError::not_found(key)
  }
}

///|
impl @platform.ScanSource for FakeSource with fn list(self, path) -> @platform.DirListing raise @platform.PlatformError {
  let key = "\{path}"
  if self.denied.contains(key) {
    raise @platform.PlatformError::access_denied(key)
  }
  match self.dirs.get(key) {
    Some(listing) => listing
    None => raise @platform.PlatformError::not_found(key)
  }
}

///|
fn dir_entry(name : String) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.Directory, mtime=50L)
}

///|
fn dir_on_device(name : String, device : UInt64) -> @platform.NodeInfo {
  @platform.NodeInfo::new(
    name~,
    kind=@platform.Directory,
    mtime=50L,
    device=Some(device),
  )
}

///|
fn file_entry(name : String, size : Int64) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.File, size~, mtime=50L)
}

///|
fn file_on_device(
  name : String,
  size : Int64,
  device : UInt64,
) -> @platform.NodeInfo {
  @platform.NodeInfo::new(
    name~,
    kind=@platform.File,
    size~,
    mtime=50L,
    device=Some(device),
  )
}

///|
fn symlink_entry(name : String) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.Symlink, mtime=50L)
}

///|
fn socket_entry(name : String) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.Other, mtime=50L)
}

///|
fn config(roots : Array[String]) -> @index.ScanConfig {
  @index.ScanConfig::new(
    roots=roots.map(fn(path) { @index.RootSpec::new(path~) }),
  )
}

///|
async fn run(
  config : @index.ScanConfig,
  source : FakeSource,
) -> @index.ScanReport {
  @index.scan(config, source) catch {
    err => abort(err.message())
  }
}

///|
async fn expect_error(
  config : @index.ScanConfig,
  source : FakeSource,
) -> @index.IndexError {
  try @index.scan(config, source) catch {
    err => err
  } noraise {
    _ => abort("expected the scan to fail")
  }
}

///|
async test "scan builds folders, files, sizes, and paths" {
  let source = fake_source()
    .dir("/r", [dir_entry("a"), file_entry("b.txt", 10L), dir_entry("z")])
    .dir("/r/a", [file_entry("x.html", 5L), dir_entry("inner")])
    .dir("/r/a/inner", [file_entry("deep.bin", 7L)])
    .dir("/r/z", [])
  let report = run(config(["/r"]), source)
  let store = report.store
  assert_eq(store.folder_count(), 4)
  assert_eq(store.file_count(), 3)
  assert_eq(store.total_size(), 22L)
  // Root statistics cover the subtree below the root.
  let root = store.roots()[0]
  assert_eq(root.files, 3U)
  assert_eq(root.folders, 3U)
  assert_eq(root.size, 22L)
  // Direct child counts and subtree sizes are filled in post-order.
  let root_folder = store.folder(0).unwrap()
  assert_eq(root_folder.num_files(), 1U)
  assert_eq(root_folder.num_folders(), 2U)
  assert_eq(root_folder.size(), 22L)
  let a = store.folder(1).unwrap()
  assert_eq(a.num_files(), 1U)
  assert_eq(a.num_folders(), 1U)
  assert_eq(a.size(), 12L)
  // Paths are reconstructed through the parent chain and root name.
  assert_eq(store.folder_path(0), b"/r")
  assert_eq(store.folder_path(1), b"/r/a")
  assert_eq(store.folder_path(2), b"/r/a/inner")
  assert_eq(store.folder_path(3), b"/r/z")
  // File ids follow the depth-first insertion order, not lexicographic path
  // order: a's subtree is scanned before b.txt.
  assert_eq(store.file_path(0), b"/r/a/inner/deep.bin")
  assert_eq(store.file_path(1), b"/r/a/x.html")
  assert_eq(store.file_path(2), b"/r/b.txt")
}

///|
async test "scan sorts entries by name regardless of listing order" {
  let source = fake_source().dir("/r", [
    file_entry("z", 1L),
    file_entry("a", 1L),
    file_entry("m", 1L),
  ])
  let report = run(config(["/r"]), source)
  assert_eq(report.store.file_path(0), b"/r/a")
  assert_eq(report.store.file_path(1), b"/r/m")
  assert_eq(report.store.file_path(2), b"/r/z")
}

///|
async test "exclude_hidden skips dot entries" {
  let source = fake_source().dir("/r", [
    dir_entry(".git"),
    file_entry(".env", 1L),
    file_entry("readme.md", 2L),
  ])
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path="/r")],
    exclude_hidden=true,
  )
  let report = run(config, source)
  assert_eq(report.skipped_hidden, 2)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/readme.md")
}

///|
async test "hidden entries are kept without the flag but flagged" {
  let source = fake_source().dir("/r", [file_entry(".env", 1L)])
  let report = run(config(["/r"]), source)
  assert_eq(report.store.file_count(), 1)
  assert_true(report.store.file(0).unwrap().is_hidden())
}

///|
async test "exclude rules filter files by basename glob" {
  let source = fake_source().dir("/r", [
    file_entry("keep.txt", 1L),
    file_entry("drop.tmp", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Glob,
    pattern="*.tmp",
    scope=Basename,
    target=Files,
  )
  let config = @index.ScanConfig::new(roots=[@index.RootSpec::new(path="/r")], excludes=[
    exclude,
  ])
  let report = run(config, source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/keep.txt")
}

///|
async test "folder-only rules do not match files" {
  let source = fake_source().dir("/r", [
    dir_entry("build"),
    file_entry("build", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Fixed,
    pattern="build",
    scope=Basename,
    target=Folders,
  )
  let config = @index.ScanConfig::new(roots=[@index.RootSpec::new(path="/r")], excludes=[
    exclude,
  ])
  let report = run(config, source)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "symlinks are indexed as files and not descended into" {
  let source = fake_source().dir("/r", [symlink_entry("link")])
  let report = run(config(["/r"]), source)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
  let link = report.store.file(0).unwrap()
  assert_true(link.is_symlink())
  assert_eq(link.size(), 0L)
}

///|
async test "special files are indexed with the special flag" {
  let source = fake_source().dir("/r", [socket_entry("sock")])
  let report = run(config(["/r"]), source)
  let entry = report.store.file(0).unwrap()
  assert_eq(entry.flags() & @core.ENTRY_FLAG_SPECIAL, @core.ENTRY_FLAG_SPECIAL)
}

///|
async test "an unreadable directory becomes an issue, not a failure" {
  let source = fake_source()
    .dir("/r", [dir_entry("locked"), file_entry("ok.txt", 3L)])
    .deny("/r/locked")
  let report = run(config(["/r"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, "/r/locked")
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.folder(1).unwrap().child_count(), 0U)
}

///|
async test "one-file-system skips directories on other devices" {
  let source = fake_source()
    .dir("/r", [
      dir_on_device("mnt", 2UL),
      file_on_device("remote.bin", 4L, 2UL),
    ])
    .root_on_device("/r", 1UL)
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path="/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 1)
  assert_eq(report.store.folder_count(), 1)
  // Files are not mount points; the check only applies to directories.
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.total_size(), 4L)
}

///|
async test "unknown device ids disable one-file-system for that entry" {
  let source = fake_source()
    .dir("/r", [dir_entry("plain")])
    .dir("/r/plain", [file_entry("x", 1L)])
    .without_devices()
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path="/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 1)
  assert_false(report.device_ids_available)
}

///|
async test "default excludes skip pseudo file systems" {
  let source = fake_source()
    .dir("/", [dir_entry("proc"), dir_entry("home")])
    .dir("/proc", [file_entry("cpuinfo", 1L)])
    .dir("/home", [])
  let report = run(config(["/"]), source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 0)
}

///|
async test "default excludes can be disabled" {
  let source = fake_source()
    .dir("/", [dir_entry("proc")])
    .dir("/proc", [file_entry("cpuinfo", 1L)])
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path="/")],
    default_excludes=false,
  )
  let report = run(config, source)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "duplicate roots are scanned once" {
  let source = fake_source().dir("/r", [file_entry("a", 1L)])
  let report = run(config(["/r", "/r"]), source)
  assert_eq(report.store.roots().length(), 1)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "nested roots are rejected by default" {
  let source = fake_source()
    .root("/r")
    .root("/r/sub")
    .dir("/r", [dir_entry("sub")])
    .dir("/r/sub", [])
  let err = expect_error(config(["/r", "/r/sub"]), source)
  match err {
    @index.NestedRoots(..) =>
      assert_true(err.message().contains("--allow-nested-roots"))
    _ => abort("expected NestedRoots, got \{err.message()}")
  }
}

///|
async test "nested roots are accepted with the flag" {
  let source = fake_source()
    .root("/r")
    .root("/r/sub")
    .dir("/r", [dir_entry("sub")])
    .dir("/r/sub", [file_entry("x", 1L)])
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path="/r"), @index.RootSpec::new(path="/r/sub")],
    allow_nested_roots=true,
  )
  let report = run(config, source)
  assert_eq(report.store.roots().length(), 2)
  // The file is indexed under both roots, which is what opting in means.
  assert_eq(report.store.file_count(), 2)
}

///|
async test "a missing root is a configuration error" {
  let source = fake_source()
  source.missing.push("/nope")
  let err = expect_error(config(["/nope"]), source)
  match err {
    @index.RootMissing(path) => {
      assert_eq(path, "/nope")
      assert_eq(err.message(), "root does not exist: /nope")
    }
    _ => abort("expected RootMissing, got \{err.message()}")
  }
}

///|
async test "a file used as a root is rejected" {
  let source = fake_source().file_root("/r/file")
  let err = expect_error(config(["/r/file"]), source)
  match err {
    @index.RootNotDirectory(path) => {
      assert_eq(path, "/r/file")
      assert_true(err.message().contains("not a directory"))
    }
    _ => abort("expected RootNotDirectory, got \{err.message()}")
  }
}

///|
async test "a root named / reconstructs child paths without double slashes" {
  let source = fake_source()
    .dir("/", [dir_entry("tmp")])
    .dir("/tmp", [file_entry("x", 1L)])
  let report = run(config(["/"]), source)
  assert_eq(report.store.folder_path(0), b"/")
  assert_eq(report.store.folder_path(1), b"/tmp")
  assert_eq(report.store.file_path(0), b"/tmp/x")
}

///|
async test "a directory with a failing entry reports an issue" {
  let source = fake_source().dir("/r", [])
  // Replace the listing with one that has a failure recorded.
  source.dirs.set(
    "/r",
    @platform.DirListing::new(entries=[file_entry("ok", 1L)], failures=[
      @platform.DirFailure::new(name="gone", message="vanished"),
    ]),
  )
  let report = run(config(["/r"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, "/r/gone")
  assert_eq(report.store.file_count(), 1)
}

///|
/// Build an ASCII name of exactly `length` bytes.
fn long_name(length : Int32) -> String {
  let chars : Array[Char] = []
  for _ in 0..<length {
    chars.push('n')
  }
  String::from_array(chars)
}

///|
async test "names at the maximum indexable length are accepted" {
  let name = long_name(@core.MAX_NAME_LEN)
  let source = fake_source().dir("/r", [file_entry(name, 1L)])
  let report = run(config(["/r"]), source)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.issues.length(), 0)
  // The stored path is `/r/` followed by the name.
  assert_eq(report.store.file_path(0).length(), 3 + @core.MAX_NAME_LEN)
}

///|
async test "names longer than the index can hold become issues" {
  let name = long_name(@core.MAX_NAME_LEN + 1)
  let source = fake_source().dir("/r", [
    file_entry(name, 1L),
    file_entry("kept", 2L),
  ])
  let report = run(config(["/r"]), source)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/kept")
  assert_eq(report.issues.length(), 1)
  assert_true(report.issues[0].message.contains("does not fit"))
  assert_eq(report.issues[0].path.length(), 3 + @core.MAX_NAME_LEN + 1)
}

///|
async test "hidden directories are skipped without descending" {
  let source = fake_source().dir("/r", [
    dir_entry(".git"),
    file_entry(".env", 1L),
    file_entry("a.b", 2L),
  ])
  // No listing for /r/.git: descending would raise a NotFound issue, so a
  // clean report proves the subtree was never visited.
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path="/r")],
    exclude_hidden=true,
  )
  let report = run(config, source)
  assert_eq(report.skipped_hidden, 2)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/a.b")
}

///|
async test "an excluded directory is skipped without descending" {
  let source = fake_source().dir("/r", [
    dir_entry("build"),
    file_entry("keep", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Fixed,
    pattern="build",
    scope=Basename,
    target=Folders,
  )
  let config = @index.ScanConfig::new(roots=[@index.RootSpec::new(path="/r")], excludes=[
    exclude,
  ])
  let report = run(config, source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "full-path exclusion rules can prune whole subtrees" {
  let source = fake_source().dir("/r", [
    dir_entry("skip-this"),
    dir_entry("keep"),
    file_entry("keep.txt", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Glob,
    pattern="/r/skip-*",
    scope=FullPath,
    target=Folders,
  )
  let config = @index.ScanConfig::new(roots=[@index.RootSpec::new(path="/r")], excludes=[
    exclude,
  ])
  let report = run(config, source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "a failing root listing leaves an empty root with stats of zero" {
  // The root stat works but listing it fails.
  let source = fake_source().root("/r")
  let report = run(config(["/r"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, "/r")
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 0)
  assert_eq(report.store.folder(0).unwrap().child_count(), 0U)
  let root = report.store.roots()[0]
  assert_eq(root.files, 0U)
  assert_eq(root.folders, 0U)
  assert_eq(root.size, 0L)
}

///|
async test "a root that disappears between realpath and stat is missing" {
  let source = fake_source()
  // realpath succeeds because the path is not in `missing`, but stat has no
  // metadata for it.
  let err = expect_error(config(["/r"]), source)
  match err {
    @index.RootMissing(path) => assert_eq(path, "/r")
    _ => abort("expected RootMissing, got \{err.message()}")
  }
}

///|
async test "a non-I/O stat failure is reported as an index error" {
  let source = fake_source().fail_io("/r", "disk on fire")
  let err = expect_error(config(["/r"]), source)
  match err {
    @index.Io(message) => {
      assert_eq(message, "disk on fire")
      assert_eq(err.message(), "disk on fire")
    }
    _ => abort("expected Io, got \{err.message()}")
  }
}

///|
async test "the root folder records the root mtime" {
  let source = fake_source().dir("/r", [])
  let report = run(config(["/r"]), source)
  assert_eq(report.store.folder(0).unwrap().mtime(), 100L)
  assert_eq(report.store.roots()[0].folder, 0)
}

///|
async test "listing order never changes ids or paths" {
  let entries_forward = [
    dir_entry("a"),
    dir_entry("m"),
    file_entry("b.txt", 2L),
    file_entry("z.txt", 1L),
  ]
  let entries_reverse = [
    file_entry("z.txt", 1L),
    file_entry("b.txt", 2L),
    dir_entry("m"),
    dir_entry("a"),
  ]
  let forward = run(
    config(["/r"]),
    fake_source()
    .dir("/r", entries_forward)
    .dir("/r/a", [file_entry("x", 3L)])
    .dir("/r/m", []),
  )
  let reverse = run(
    config(["/r"]),
    fake_source()
    .dir("/r", entries_reverse)
    .dir("/r/m", [])
    .dir("/r/a", [file_entry("x", 3L)]),
  )
  assert_eq(forward.store.folder_count(), reverse.store.folder_count())
  assert_eq(forward.store.file_count(), reverse.store.file_count())
  for id in 0..<forward.store.folder_count() {
    assert_eq(forward.store.folder_path(id), reverse.store.folder_path(id))
  }
  for id in 0..<forward.store.file_count() {
    assert_eq(forward.store.file_path(id), reverse.store.file_path(id))
    assert_eq(
      forward.store.file(id).unwrap().size(),
      reverse.store.file(id).unwrap().size(),
    )
  }
}

///|
async test "names are ordered by raw bytes, not by readdir order" {
  let source = fake_source().dir("/r", [
    file_entry("é", 1L),
    file_entry("z", 2L),
    file_entry("A", 3L),
    file_entry("a", 4L),
  ])
  let report = run(config(["/r"]), source)
  // 'A'(0x41) < 'a'(0x61) < 'z'(0x7A) < 'é'(0xC3 0xA9).
  assert_eq(report.store.file_path(0), b"/r/A")
  assert_eq(report.store.file_path(1), b"/r/a")
  assert_eq(report.store.file_path(2), b"/r/z")
  assert_eq(report.store.file_path(3), b"/r/é")
}

///|
async test "deep directory chains preserve the parent chain" {
  let depth = 400
  let source = fake_source()
  let root_path = StringBuilder()
  root_path.write_string("/r")
  let mut parent_path = "/r"
  for _ in 0..<depth {
    let child_path = "\{parent_path}/d"
    source.dirs.set(
      parent_path,
      @platform.DirListing::new(entries=[dir_entry("d")]),
    )
    ignore(source.root(parent_path))
    parent_path = child_path
  }
  source.dirs.set(
    parent_path,
    @platform.DirListing::new(entries=[file_entry("leaf", 1L)]),
  )
  ignore(source.root(parent_path))
  let report = run(config(["/r"]), source)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.folder_count(), depth + 1)
  assert_eq(report.store.file_count(), 1)
  let expected = StringBuilder()
  expected.write_string("/r")
  for _ in 0..<depth {
    expected.write_string("/d")
  }
  expected.write_string("/leaf")
  let expected_len = 2 + 2 * depth + 5
  assert_eq(report.store.file_path(0).length(), expected_len)
  assert_true(@util.starts_with(report.store.file_path(0)[:], b"/r/d"[:]))
  assert_true(@util.ends_with(report.store.file_path(0)[:], b"/leaf"[:]))
  assert_true(@util.contains_bytes(report.store.file_path(0)[:], b"/d/d/d"[:]))
}

///|
async test "multiple roots are scanned independently and keep their order" {
  let source = fake_source()
    .dir("/first", [file_entry("a", 1L)])
    .dir("/second", [dir_entry("sub"), file_entry("b", 2L)])
    .dir("/second/sub", [file_entry("c", 4L)])
  let report = run(config(["/second", "/first"]), source)
  assert_eq(report.store.roots().length(), 2)
  assert_eq(report.store.roots()[0].path, "/second")
  assert_eq(report.store.roots()[1].path, "/first")
  assert_eq(report.store.folder_count(), 3)
  assert_eq(report.store.file_count(), 3)
  assert_eq(report.store.total_size(), 7L)
  // The first root's subtree is inserted before the second root's.
  assert_eq(report.store.file_path(0), b"/second/b")
  assert_eq(report.store.file_path(1), b"/second/sub/c")
  assert_eq(report.store.file_path(2), b"/first/a")
}

///|
async test "a child with an unknown device id disables the mount check" {
  let source = fake_source()
    .dir("/r", [dir_entry("unknown")])
    .dir("/r/unknown", [file_entry("x", 1L)])
    .root_on_device("/r", 1UL)
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path="/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "the root device id is required for mount filtering" {
  let source = fake_source()
    .dir("/r", [dir_on_device("mnt", 2UL)])
    .dir("/r/mnt", [file_entry("x", 1L)])
  // The root metadata has no device id, so no entry can be compared.
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path="/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "a realpath I/O failure is an index error" {
  let source = fake_source().fail_realpath_io("/r", "mount vanished")
  let err = expect_error(config(["/r"]), source)
  match err {
    @index.Io(message) => {
      assert_eq(message, "mount vanished")
      assert_eq(err.message(), "mount vanished")
    }
    _ => abort("expected Io, got \{err.message()}")
  }
}

///|
/// Advance a deterministic pseudo-random seed without relying on the platform
/// random generator.
fn tree_seed(seed : Int64) -> Int64 {
  (seed * 1103515245L + 12345L) % 2147483648L
}

///|
/// Populate a deterministic tree: up to three children per directory, with
/// directories only in the first four levels. Returns the next seed.
fn grow_tree(
  source : FakeSource,
  path : String,
  depth : Int32,
  seed : Int64,
) -> Int64 {
  let mut next = seed
  let width = (next % 3L + 1L).to_int()
  let entries : Array[@platform.NodeInfo] = []
  for index in 0..<width {
    next = tree_seed(next)
    let make_dir = depth < 4 && next % 2L == 0L
    if make_dir {
      let name = "d\{index}"
      entries.push(dir_entry(name))
      next = grow_tree(
        source,
        @util.join_path(path, name),
        depth + 1,
        tree_seed(next),
      )
    } else {
      let size = next % 100L
      entries.push(file_entry("f\{index}", size))
    }
  }
  ignore(source.dir(path, entries))
  next
}

///|
async test "scanner statistics are internally consistent on a generated tree" {
  let source = fake_source()
  ignore(grow_tree(source, "/r", 0, 42L))
  let report = run(config(["/r"]), source)
  assert_eq(report.issues.length(), 0)
  let store = report.store
  let direct_files : Map[Int32, UInt32] = Map([])
  let direct_size : Map[Int32, Int64] = Map([])
  for id in 0..<store.file_count() {
    let entry = store.file(id).unwrap()
    let parent = entry.parent()
    direct_files.set(parent, direct_files.get_or_default(parent, 0U) + 1U)
    direct_size.set(
      parent,
      direct_size.get_or_default(parent, 0L) + entry.size(),
    )
  }
  let direct_folders : Map[Int32, UInt32] = Map([])
  for id in 0..<store.folder_count() {
    let entry = store.folder(id).unwrap()
    if !entry.is_root() {
      let parent = entry.parent()
      direct_folders.set(parent, direct_folders.get_or_default(parent, 0U) + 1U)
    }
  }
  for id in 0..<store.folder_count() {
    let folder = store.folder(id).unwrap()
    assert_eq(folder.num_files(), direct_files.get_or_default(id, 0U))
    assert_eq(folder.num_folders(), direct_folders.get_or_default(id, 0U))
    let mut expected = direct_size.get_or_default(id, 0L)
    for child in 0..<store.folder_count() {
      let child_entry = store.folder(child).unwrap()
      if child_entry.parent() == id {
        expected = expected + child_entry.size()
      }
    }
    assert_eq(folder.size(), expected)
  }
  // With a single root, RootInfo covers the same subtree as the root folder.
  let root_info = store.roots()[0]
  let root_folder = store.folder(root_info.folder).unwrap()
  assert_eq(root_info.size, root_folder.size())
  assert_eq(root_info.files, store.file_count().reinterpret_as_uint())
  assert_eq(root_info.folders, (store.folder_count() - 1).reinterpret_as_uint())
  assert_eq(store.total_size(), root_info.size)
}
