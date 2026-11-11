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
  mut devices : Bool
}

///|
fn fake_source() -> FakeSource {
  { dirs: Map([]), stats: Map([]), missing: [], denied: [], devices: true, }
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
  if self.missing.contains(key) {
    raise @platform.PlatformError::not_found(key)
  }
  key
}

///|
impl @platform.ScanSource for FakeSource with fn stat(self, path) -> @platform.NodeInfo raise @platform.PlatformError {
  match self.stats.get("\{path}") {
    Some(info) => info
    None => raise @platform.PlatformError::not_found("\{path}")
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
    @index.NestedRoots(..) => ()
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
    @index.RootMissing(path) => assert_eq(path, "/nope")
    _ => abort("expected RootMissing, got \{err.message()}")
  }
}

///|
async test "a file used as a root is rejected" {
  let source = fake_source().file_root("/r/file")
  let err = expect_error(config(["/r/file"]), source)
  match err {
    @index.RootNotDirectory(path) => assert_eq(path, "/r/file")
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
