///|
/// An in-memory scan source used by the scanner tests.
///
/// It implements the same `ScanSource` trait as the async file system backend,
/// so the tests exercise the real recursion, exclusion, and statistics logic
/// without touching the disk.
struct FakeSource {
  dirs : Map[Bytes, @platform.DirListing]
  stats : Map[Bytes, @platform.NodeInfo]
  missing : Array[Bytes]
  denied : Array[Bytes]
  io_errors : Map[Bytes, String]
  realpath_io_errors : Map[Bytes, String]
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
fn FakeSource::root(self : FakeSource, path : Bytes) -> FakeSource {
  self.stats.set(
    path,
    @platform.NodeInfo::new(name=path, kind=@platform.Directory, mtime=100L),
  )
  self
}

///|
fn FakeSource::root_on_device(
  self : FakeSource,
  path : Bytes,
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
fn FakeSource::file_root(self : FakeSource, path : Bytes) -> FakeSource {
  self.stats.set(
    path,
    @platform.NodeInfo::new(name=path, kind=@platform.File, size=1L, mtime=1L),
  )
  self
}

///|
fn FakeSource::dir(
  self : FakeSource,
  path : Bytes,
  entries : Array[@platform.NodeInfo],
) -> FakeSource {
  ignore(self.root(path))
  self.dirs.set(path, @platform.DirListing::new(entries~))
  self
}

///|
fn FakeSource::deny(self : FakeSource, path : Bytes) -> FakeSource {
  ignore(self.root(path))
  self.denied.push(path)
  self
}

///|
fn FakeSource::fail_io(
  self : FakeSource,
  path : Bytes,
  message : String,
) -> FakeSource {
  self.io_errors.set(path, message)
  self
}

///|
fn FakeSource::fail_realpath_io(
  self : FakeSource,
  path : Bytes,
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
impl @platform.ScanSource for FakeSource with fn realpath(self, path) -> Bytes raise @platform.PlatformError {
  let key = path.to_owned()
  match self.realpath_io_errors.get(key) {
    Some(message) => raise @platform.PlatformError::io(message)
    None => ()
  }
  if self.missing.contains(key) {
    raise @platform.PlatformError::not_found(@utf8.decode_lossy(key))
  }
  key
}

///|
impl @platform.ScanSource for FakeSource with fn stat(self, path) -> @platform.NodeInfo raise @platform.PlatformError {
  let key = path.to_owned()
  match self.io_errors.get(key) {
    Some(message) => raise @platform.PlatformError::io(message)
    None => ()
  }
  match self.stats.get(key) {
    Some(info) => info
    None => raise @platform.PlatformError::not_found(@utf8.decode_lossy(key))
  }
}

///|
impl @platform.ScanSource for FakeSource with fn list(self, path) -> @platform.DirListing raise @platform.PlatformError {
  let key = path.to_owned()
  if self.denied.contains(key) {
    raise @platform.PlatformError::access_denied(@utf8.decode_lossy(key))
  }
  match self.dirs.get(key) {
    Some(listing) => listing
    None => raise @platform.PlatformError::not_found(@utf8.decode_lossy(key))
  }
}

///|
fn dir_entry(name : BytesView) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.Directory, mtime=50L)
}

///|
fn dir_on_device(name : BytesView, device : UInt64) -> @platform.NodeInfo {
  @platform.NodeInfo::new(
    name~,
    kind=@platform.Directory,
    mtime=50L,
    device=Some(device),
  )
}

///|
fn file_entry(name : BytesView, size : Int64) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.File, size~, mtime=50L)
}

///|
fn file_on_device(
  name : BytesView,
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
fn symlink_entry(name : BytesView, size~ : Int64 = 0L) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.Symlink, size~, mtime=50L)
}

///|
fn socket_entry(name : BytesView) -> @platform.NodeInfo {
  @platform.NodeInfo::new(name~, kind=@platform.Other, mtime=50L)
}

///|
fn config(roots : Array[Bytes]) -> @index.ScanConfig {
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
    .dir(b"/r", [dir_entry(b"a"), file_entry(b"b.txt", 10L), dir_entry(b"z")])
    .dir(b"/r/a", [file_entry(b"x.html", 5L), dir_entry(b"inner")])
    .dir(b"/r/a/inner", [file_entry(b"deep.bin", 7L)])
    .dir(b"/r/z", [])
  let report = run(config([b"/r"]), source)
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
  // File ids follow physical canonical name order, not depth-first scan order.
  assert_eq(store.file_path(0), b"/r/b.txt")
  assert_eq(store.file_path(1), b"/r/a/inner/deep.bin")
  assert_eq(store.file_path(2), b"/r/a/x.html")
}

///|
async test "scan sorts entries by name regardless of listing order" {
  let source = fake_source().dir(b"/r", [
    file_entry(b"z", 1L),
    file_entry(b"a", 1L),
    file_entry(b"m", 1L),
  ])
  let report = run(config([b"/r"]), source)
  assert_eq(report.store.file_path(0), b"/r/a")
  assert_eq(report.store.file_path(1), b"/r/m")
  assert_eq(report.store.file_path(2), b"/r/z")
}

///|
async test "exclude_hidden skips dot entries" {
  let source = fake_source().dir(b"/r", [
    dir_entry(b".git"),
    file_entry(b".env", 1L),
    file_entry(b"readme.md", 2L),
  ])
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/r")],
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
  let source = fake_source().dir(b"/r", [file_entry(b".env", 1L)])
  let report = run(config([b"/r"]), source)
  assert_eq(report.store.file_count(), 1)
  assert_true(report.store.file(0).unwrap().is_hidden())
}

///|
async test "exclude rules filter files by basename glob" {
  let source = fake_source().dir(b"/r", [
    file_entry(b"keep.txt", 1L),
    file_entry(b"drop.tmp", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Glob,
    pattern="*.tmp",
    scope=Basename,
    target=Files,
  )
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/r")],
    excludes=[exclude],
  )
  let report = run(config, source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/keep.txt")
}

///|
async test "folder-only rules do not match files" {
  let source = fake_source().dir(b"/r", [
    dir_entry(b"build"),
    file_entry(b"build", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Fixed,
    pattern="build",
    scope=Basename,
    target=Folders,
  )
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/r")],
    excludes=[exclude],
  )
  let report = run(config, source)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "symlinks are indexed as files with their own size and not descended into" {
  let source = fake_source().dir(b"/r", [symlink_entry(b"link", size=7L)])
  let report = run(config([b"/r"]), source)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
  let link = report.store.file(0).unwrap()
  assert_true(link.is_symlink())
  assert_eq(link.size(), 7L)
  assert_eq(report.store.folder(0).unwrap().size(), 7L)
  assert_eq(report.store.roots()[0].size, 7L)
  assert_eq(report.store.total_size(), 7L)
}

///|
async test "special files are indexed with the special flag" {
  let source = fake_source().dir(b"/r", [socket_entry(b"sock")])
  let report = run(config([b"/r"]), source)
  let entry = report.store.file(0).unwrap()
  assert_eq(entry.flags() & @core.ENTRY_FLAG_SPECIAL, @core.ENTRY_FLAG_SPECIAL)
}

///|
async test "regex excludes prune folders and filter files during scanning" {
  let source = fake_source()
    .dir(b"/r", [
      dir_entry(b"cache"),
      file_entry(b"drop.tmp", 2L),
      file_entry(b"keep.txt", 3L),
    ])
    .dir(b"/r/cache", [file_entry(b"hidden", 100L)])
  let excludes = [
    @index.ExcludeRule::parse(
      "regex:^cache$",
      scope=@index.Basename,
      target=@index.Folders,
    ),
    @index.ExcludeRule::parse(
      "regex:^drop\\.tmp$",
      scope=@index.Basename,
      target=@index.Files,
    ),
  ]
  let report = run(
    @index.ScanConfig::new(roots=[@index.RootSpec::new(path=b"/r")], excludes~),
    source,
  )
  assert_eq(report.skipped_excluded, 2)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/keep.txt")
  assert_eq(report.store.total_size(), 3L)
}

///|
async test "an unreadable directory becomes an issue, not a failure" {
  let source = fake_source()
    .dir(b"/r", [dir_entry(b"locked"), file_entry(b"ok.txt", 3L)])
    .deny(b"/r/locked")
  let report = run(config([b"/r"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, b"/r/locked")
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.folder(1).unwrap().child_count(), 0U)
}

///|
async test "fatal unreadable policy rejects a child directory" {
  let source = fake_source()
    .dir(b"/r", [dir_entry(b"locked"), file_entry(b"ok.txt", 3L)])
    .deny(b"/r/locked")
  let err = expect_error(
    @index.ScanConfig::new(
      roots=[@index.RootSpec::new(path=b"/r")],
      unreadable_directories=@index.Fatal,
    ),
    source,
  )
  match err {
    @index.UnreadableDirectory(path) => {
      assert_eq(path, b"/r/locked")
      assert_eq(err.message(), "directory is not readable: /r/locked")
    }
    _ => abort("expected UnreadableDirectory, got \{err.message()}")
  }
}

///|
async test "fatal unreadable policy rejects an unreadable root listing" {
  let source = fake_source().deny(b"/r")
  let err = expect_error(
    @index.ScanConfig::new(
      roots=[@index.RootSpec::new(path=b"/r")],
      unreadable_directories=@index.Fatal,
    ),
    source,
  )
  match err {
    @index.UnreadableDirectory(path) => assert_eq(path, b"/r")
    _ => abort("expected UnreadableDirectory, got \{err.message()}")
  }
}

///|
async test "fatal unreadable policy leaves vanished directories recoverable" {
  let source = fake_source().root(b"/r")
  let report = run(
    @index.ScanConfig::new(
      roots=[@index.RootSpec::new(path=b"/r")],
      unreadable_directories=@index.Fatal,
    ),
    source,
  )
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, b"/r")
  assert_eq(report.store.folder_count(), 1)
}

///|
async test "one-file-system skips every cross-device entry kind" {
  let source = fake_source()
    .dir(b"/r", [
      dir_on_device(b"mnt", 2UL),
      file_on_device(b"remote.bin", 4L, 2UL),
      @platform.NodeInfo::new(
        name=b"remote.sock",
        kind=@platform.Other,
        mtime=50L,
        device=Some(2UL),
      ),
      file_on_device(b"local.bin", 3L, 1UL),
    ])
    .root_on_device(b"/r", 1UL)
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path=b"/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 3)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/local.bin")
  assert_eq(report.store.total_size(), 3L)
  assert_eq(report.store.file(0).unwrap().flags() & @core.ENTRY_FLAG_SPECIAL, 0)
}

///|
async test "one-file-system disabled keeps cross-device entries" {
  let source = fake_source()
    .dir(b"/r", [dir_on_device(b"mnt", 2UL), file_on_device(b"remote", 4L, 2UL)])
    .dir(b"/r/mnt", [file_entry(b"inside", 1L)])
    .root_on_device(b"/r", 1UL)
  let report = run(config([b"/r"]), source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 2)
  assert_eq(report.store.total_size(), 5L)
}

///|
async test "one-file-system applies to symlinks on other devices" {
  let source = fake_source()
    .dir(b"/r", [symlink_entry(b"remote-link", size=9L)])
    .root_on_device(b"/r", 1UL)
  source.dirs.set(
    b"/r",
    @platform.DirListing::new(entries=[
      @platform.NodeInfo::new(
        name=b"remote-link",
        kind=@platform.Symlink,
        size=9L,
        mtime=50L,
        device=Some(2UL),
      ),
    ]),
  )
  let report = run(
    @index.ScanConfig::new(roots=[
      @index.RootSpec::new(path=b"/r", one_file_system=true),
    ]),
    source,
  )
  assert_eq(report.skipped_mount, 1)
  assert_eq(report.store.file_count(), 0)
}

///|
async test "each root uses its own device for one-file-system" {
  let source = fake_source()
    .dir(b"/first", [file_on_device(b"x", 1L, 1UL)])
    .dir(b"/second", [file_on_device(b"x", 2L, 2UL)])
    .root_on_device(b"/first", 1UL)
    .root_on_device(b"/second", 2UL)
  let report = run(
    @index.ScanConfig::new(roots=[
      @index.RootSpec::new(path=b"/first", one_file_system=true),
      @index.RootSpec::new(path=b"/second", one_file_system=true),
    ]),
    source,
  )
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 2)
  assert_eq(report.store.total_size(), 3L)
}

///|
async test "unknown device ids disable one-file-system for that entry" {
  let source = fake_source()
    .dir(b"/r", [dir_entry(b"plain")])
    .dir(b"/r/plain", [file_entry(b"x", 1L)])
    .without_devices()
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path=b"/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 1)
  assert_false(report.device_ids_available)
}

///|
async test "default excludes skip pseudo file systems" {
  let source = fake_source()
    .dir(b"/", [dir_entry(b"proc"), dir_entry(b"home")])
    .dir(b"/proc", [file_entry(b"cpuinfo", 1L)])
    .dir(b"/home", [])
  let report = run(config([b"/"]), source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 0)
}

///|
async test "default excludes can be disabled" {
  let source = fake_source()
    .dir(b"/", [dir_entry(b"proc")])
    .dir(b"/proc", [file_entry(b"cpuinfo", 1L)])
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/")],
    default_excludes=false,
  )
  let report = run(config, source)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "duplicate roots are scanned once" {
  let source = fake_source().dir(b"/r", [file_entry(b"a", 1L)])
  let report = run(config([b"/r", b"/r"]), source)
  assert_eq(report.store.roots().length(), 1)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "nested roots are rejected by default" {
  let source = fake_source()
    .root(b"/r")
    .root(b"/r/sub")
    .dir(b"/r", [dir_entry(b"sub")])
    .dir(b"/r/sub", [])
  let err = expect_error(config([b"/r", b"/r/sub"]), source)
  match err {
    @index.NestedRoots(..) =>
      assert_true(err.message().contains("--allow-nested-roots"))
    _ => abort("expected NestedRoots, got \{err.message()}")
  }
}

///|
async test "nested roots are accepted with the flag" {
  let source = fake_source()
    .root(b"/r")
    .root(b"/r/sub")
    .dir(b"/r", [dir_entry(b"sub")])
    .dir(b"/r/sub", [file_entry(b"x", 1L)])
  let config = @index.ScanConfig::new(
    roots=[
      @index.RootSpec::new(path=b"/r"),
      @index.RootSpec::new(path=b"/r/sub"),
    ],
    allow_nested_roots=true,
  )
  let report = run(config, source)
  assert_eq(report.store.roots().length(), 2)
  // The file is indexed under both roots, which is what opting in means.
  assert_eq(report.store.file_count(), 2)
  assert_eq(report.store.folder_count(), 3)
  assert_eq(report.store.roots()[0].folder, 0)
  assert_eq(report.store.roots()[1].folder, 1)
  assert_eq(report.store.file_path(0), b"/r/sub/x")
  assert_eq(report.store.file_path(1), b"/r/sub/x")
  assert_eq(report.store.file(0).unwrap().parent(), 2)
  assert_eq(report.store.file(1).unwrap().parent(), 1)
}

///|
async test "a missing root is a configuration error" {
  let source = fake_source()
  source.missing.push(b"/nope")
  let err = expect_error(config([b"/nope"]), source)
  match err {
    @index.RootMissing(path) => {
      assert_eq(path, b"/nope")
      assert_eq(err.message(), "root does not exist: /nope")
    }
    _ => abort("expected RootMissing, got \{err.message()}")
  }
}

///|
async test "a file used as a root is rejected" {
  let source = fake_source().file_root(b"/r/file")
  let err = expect_error(config([b"/r/file"]), source)
  match err {
    @index.RootNotDirectory(path) => {
      assert_eq(path, b"/r/file")
      assert_true(err.message().contains("not a directory"))
    }
    _ => abort("expected RootNotDirectory, got \{err.message()}")
  }
}

///|
async test "a root named / reconstructs child paths without double slashes" {
  let source = fake_source()
    .dir(b"/", [dir_entry(b"tmp")])
    .dir(b"/tmp", [file_entry(b"x", 1L)])
  let report = run(config([b"/"]), source)
  assert_eq(report.store.folder_path(0), b"/")
  assert_eq(report.store.folder_path(1), b"/tmp")
  assert_eq(report.store.file_path(0), b"/tmp/x")
}

///|
async test "a directory with a failing entry reports an issue" {
  let source = fake_source().dir(b"/r", [])
  // Replace the listing with one that has a failure recorded.
  source.dirs.set(
    b"/r",
    @platform.DirListing::new(entries=[file_entry(b"ok", 1L)], failures=[
      @platform.DirFailure::new(name=b"gone", message="vanished"),
    ]),
  )
  let report = run(config([b"/r"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, b"/r/gone")
  assert_eq(report.store.file_count(), 1)
}

///|
/// Build an ASCII name of exactly `length` bytes.
fn long_name(length : Int32) -> Bytes {
  Bytes::make(length, b'n')
}

///|
async test "names at the maximum indexable length are accepted" {
  let name = long_name(@core.MAX_NAME_LEN)
  let source = fake_source().dir(b"/r", [file_entry(name, 1L)])
  let report = run(config([b"/r"]), source)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.issues.length(), 0)
  // The stored path is `/r/` followed by the name.
  assert_eq(report.store.file_path(0).length(), 3 + @core.MAX_NAME_LEN)
}

///|
async test "names longer than the index can hold become issues" {
  let name = long_name(@core.MAX_NAME_LEN + 1)
  let source = fake_source().dir(b"/r", [
    file_entry(name, 1L),
    file_entry(b"kept", 2L),
  ])
  let report = run(config([b"/r"]), source)
  assert_eq(report.store.file_count(), 1)
  assert_eq(report.store.file_path(0), b"/r/kept")
  assert_eq(report.issues.length(), 1)
  assert_true(report.issues[0].message.contains("does not fit"))
  assert_eq(report.issues[0].path.length(), 3 + @core.MAX_NAME_LEN + 1)
}

///|
async test "hidden directories are skipped without descending" {
  let source = fake_source().dir(b"/r", [
    dir_entry(b".git"),
    file_entry(b".env", 1L),
    file_entry(b"a.b", 2L),
  ])
  // No listing for /r/.git: descending would raise a NotFound issue, so a
  // clean report proves the subtree was never visited.
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/r")],
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
  let source = fake_source().dir(b"/r", [
    dir_entry(b"build"),
    file_entry(b"keep", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Fixed,
    pattern="build",
    scope=Basename,
    target=Folders,
  )
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/r")],
    excludes=[exclude],
  )
  let report = run(config, source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.folder_count(), 1)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "full-path exclusion rules can prune whole subtrees" {
  let source = fake_source().dir(b"/r", [
    dir_entry(b"skip-this"),
    dir_entry(b"keep"),
    file_entry(b"keep.txt", 1L),
  ])
  let exclude = @index.ExcludeRule::new(
    kind=Glob,
    pattern="/r/skip-*",
    scope=FullPath,
    target=Folders,
  )
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=b"/r")],
    excludes=[exclude],
  )
  let report = run(config, source)
  assert_eq(report.skipped_excluded, 1)
  assert_eq(report.store.folder_count(), 2)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "a failing root listing leaves an empty root with stats of zero" {
  // The root stat works but listing it fails.
  let source = fake_source().root(b"/r")
  let report = run(config([b"/r"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, b"/r")
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
  let err = expect_error(config([b"/r"]), source)
  match err {
    @index.RootMissing(path) => assert_eq(path, b"/r")
    _ => abort("expected RootMissing, got \{err.message()}")
  }
}

///|
async test "a non-I/O stat failure is reported as an index error" {
  let source = fake_source().fail_io(b"/r", "disk on fire")
  let err = expect_error(config([b"/r"]), source)
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
  let source = fake_source().dir(b"/r", [])
  let report = run(config([b"/r"]), source)
  assert_eq(report.store.folder(0).unwrap().mtime(), 100L)
  assert_eq(report.store.roots()[0].folder, 0)
}

///|
async test "listing order never changes ids or paths" {
  let entries_forward = [
    dir_entry(b"a"),
    dir_entry(b"m"),
    file_entry(b"b.txt", 2L),
    file_entry(b"z.txt", 1L),
  ]
  let entries_reverse = [
    file_entry(b"z.txt", 1L),
    file_entry(b"b.txt", 2L),
    dir_entry(b"m"),
    dir_entry(b"a"),
  ]
  let forward = run(
    config([b"/r"]),
    fake_source()
    .dir(b"/r", entries_forward)
    .dir(b"/r/a", [file_entry(b"x", 3L)])
    .dir(b"/r/m", []),
  )
  let reverse = run(
    config([b"/r"]),
    fake_source()
    .dir(b"/r", entries_reverse)
    .dir(b"/r/m", [])
    .dir(b"/r/a", [file_entry(b"x", 3L)]),
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
  let source = fake_source().dir(b"/r", [
    file_entry(b"é", 1L),
    file_entry(b"z", 2L),
    file_entry(b"A", 3L),
    file_entry(b"a", 4L),
  ])
  let report = run(config([b"/r"]), source)
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
  let mut parent_path = b"/r"
  for _ in 0..<depth {
    let child_path = @util.join_path(parent_path, b"d")
    source.dirs.set(
      parent_path,
      @platform.DirListing::new(entries=[dir_entry(b"d")]),
    )
    ignore(source.root(parent_path))
    parent_path = child_path
  }
  source.dirs.set(
    parent_path,
    @platform.DirListing::new(entries=[file_entry(b"leaf", 1L)]),
  )
  ignore(source.root(parent_path))
  let report = run(config([b"/r"]), source)
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
async test "nested size overflow saturates every total and warns once" {
  let source = fake_source()
    .dir(b"/r", [dir_entry(b"a"), file_entry(b"z", 1L)])
    .dir(b"/r/a", [
      file_entry(b"x", 9223372036854775800L),
      file_entry(b"y", 10L),
    ])
  let report = run(config([b"/r"]), source)
  let store = report.store
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, b"/r/a/y")
  assert_eq(
    report.issues[0].message,
    "size overflow: cumulative size saturated at the Int64 limit",
  )
  assert_eq(store.folder(0).unwrap().size(), 9223372036854775807L)
  assert_eq(store.folder(1).unwrap().size(), 9223372036854775807L)
  assert_eq(store.roots()[0].size, 9223372036854775807L)
  assert_eq(store.total_size(), 9223372036854775807L)
  for id in 0..<store.folder_count() {
    assert_true(store.folder(id).unwrap().size() >= 0L)
  }
}

///|
async test "global size overflow across roots saturates and warns once" {
  let source = fake_source()
    .dir(b"/first", [file_entry(b"x", 9223372036854775800L)])
    .dir(b"/second", [file_entry(b"y", 10L)])
  let report = run(config([b"/first", b"/second"]), source)
  assert_eq(report.issues.length(), 1)
  assert_eq(report.issues[0].path, b"/second/y")
  assert_eq(report.store.roots()[0].size, 9223372036854775800L)
  assert_eq(report.store.roots()[1].size, 10L)
  assert_eq(report.store.total_size(), 9223372036854775807L)
  assert_eq(
    report.store.folder(0).unwrap().size(),
    report.store.roots()[0].size,
  )
  assert_eq(
    report.store.folder(1).unwrap().size(),
    report.store.roots()[1].size,
  )
}

///|
async test "multiple roots are scanned independently and keep their order" {
  let source = fake_source()
    .dir(b"/first", [file_entry(b"a", 1L)])
    .dir(b"/second", [dir_entry(b"sub"), file_entry(b"b", 2L)])
    .dir(b"/second/sub", [file_entry(b"c", 4L)])
  let report = run(config([b"/second", b"/first"]), source)
  assert_eq(report.store.roots().length(), 2)
  assert_eq(report.store.roots()[0].path, b"/second")
  assert_eq(report.store.roots()[1].path, b"/first")
  assert_eq(report.store.folder_count(), 3)
  assert_eq(report.store.file_count(), 3)
  assert_eq(report.store.total_size(), 7L)
  // Root records keep configuration order, while file ids follow name order.
  assert_eq(report.store.roots()[0].folder, 1)
  assert_eq(report.store.roots()[1].folder, 0)
  assert_eq(report.store.file_path(0), b"/first/a")
  assert_eq(report.store.file_path(1), b"/second/b")
  assert_eq(report.store.file_path(2), b"/second/sub/c")
}

///|
async test "a child with an unknown device id disables the mount check" {
  let source = fake_source()
    .dir(b"/r", [dir_entry(b"unknown")])
    .dir(b"/r/unknown", [file_entry(b"x", 1L)])
    .root_on_device(b"/r", 1UL)
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path=b"/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "the root device id is required for mount filtering" {
  let source = fake_source()
    .dir(b"/r", [dir_on_device(b"mnt", 2UL)])
    .dir(b"/r/mnt", [file_entry(b"x", 1L)])
  // The root metadata has no device id, so no entry can be compared.
  let config = @index.ScanConfig::new(roots=[
    @index.RootSpec::new(path=b"/r", one_file_system=true),
  ])
  let report = run(config, source)
  assert_eq(report.skipped_mount, 0)
  assert_eq(report.store.file_count(), 1)
}

///|
async test "a realpath I/O failure is an index error" {
  let source = fake_source().fail_realpath_io(b"/r", "mount vanished")
  let err = expect_error(config([b"/r"]), source)
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
  path : Bytes,
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
      let name = @utf8.encode("d\{index}")
      entries.push(dir_entry(name))
      next = grow_tree(
        source,
        @util.join_path(path, name),
        depth + 1,
        tree_seed(next),
      )
    } else {
      let size = next % 100L
      entries.push(file_entry(@utf8.encode("f\{index}"), size))
    }
  }
  ignore(source.dir(path, entries))
  next
}

///|
async test "scanner statistics are internally consistent on a generated tree" {
  let source = fake_source()
  ignore(grow_tree(source, b"/r", 0, 42L))
  let report = run(config([b"/r"]), source)
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
