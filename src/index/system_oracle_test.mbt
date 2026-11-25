///|
/// Reference metadata collected by an independent recursive walk.
struct RefTree {
  files : Map[String, Int64]
  folders : Map[String, Int64]
}

///|
fn reference_join(path : String, name : String) -> String {
  if path.has_suffix("/") {
    path + name
  } else {
    path + "/" + name
  }
}

///|
/// Independent `lstat` size for the POSIX oracle test.
#cfg(not(platform="windows"))
#borrow(path)
extern "C" fn test_lstat_size(path : Bytes, path_len : Int32) -> Int64 = "ms_test_lstat_size"

///|
#cfg(not(platform="windows"))
async fn reference_size(path : String, kind : @fs.FileKind) -> Int64 {
  match kind {
    @fs.Regular => @fs.file_size(path) catch { err => abort(err.to_string()) }
    @fs.SymLink => {
      let bytes = @utf8.encode(path)
      let size = test_lstat_size(bytes, bytes.length())
      if size < 0L {
        abort("lstat failed for \{path}")
      }
      size
    }
    _ => 0L
  }
}

///|
#cfg(platform="windows")
async fn reference_size(path : String, kind : @fs.FileKind) -> Int64 {
  if kind is @fs.Regular {
    @fs.file_size(path) catch {
      err => abort(err.to_string())
    }
  } else {
    0L
  }
}

///|
/// Walk `path` with plain `readdir`/`lstat` calls and record every entry.
///
/// This deliberately does not share code with the scanner: it spells paths
/// with `@util.join_path`, uses independent metadata calls, treats symlinks as
/// non-directories, and sums subtree sizes on the way out.
async fn reference_walk(path : String, tree : RefTree) -> Int64 {
  let names = @fs.readdir(
    path,
    include_hidden=true,
    include_special=false,
    sort=false,
  )
  let mut total = 0L
  for name in names {
    let child = reference_join(path, name)
    let kind = @fs.kind(child, follow_symlink=false)
    if kind is @fs.Directory {
      total = total + reference_walk(child, tree)
    } else {
      let size = reference_size(child, kind)
      tree.files.set(child, size)
      total = total + size
    }
  }
  tree.folders.set(path, total)
  total
}

///|
async test "the system backend matches an independent directory walk" {
  let dir = @fs.tmpdir(prefix="moonsearch-oracle")
  @fs.mkdir("\{dir}/sub")
  @fs.mkdir("\{dir}/sub/deep")
  @fs.mkdir("\{dir}/empty")
  @fs.write_text("\{dir}/hello.txt", "hello")
  @fs.write_text("\{dir}/.hidden", "hh")
  @fs.write_text("\{dir}/sub/report.pdf", "abc")
  @fs.write_text("\{dir}/sub/deep/x", "1")
  @fs.symlink(target="sub", "\{dir}/link")
  let root = @fs.realpath(dir)
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=@utf8.encode(root))],
    default_excludes=false,
  )
  let report = @index.scan(config, @platform.system_source()) catch {
    err => abort(err.message())
  }
  let tree : RefTree = { files: Map([]), folders: Map([]), }
  let total = reference_walk(root, tree)
  @fs.remove(dir, recursive=true)
  // The fixture itself has 11 regular-file bytes. The independent walk also
  // supplies the platform's symlink size (3 bytes on POSIX, zero on Windows).
  let link_size = tree.files.get("\{root}/link").unwrap()
  assert_eq(total, 11L + link_size)
  assert_eq(report.issues.length(), 0)
  assert_eq(report.store.file_count(), tree.files.length())
  assert_eq(report.store.folder_count(), tree.folders.length())
  assert_eq(report.store.total_size(), total)
  assert_eq(report.store.roots().length(), 1)
  assert_eq(report.store.roots()[0].size, total)
  for id in 0..<report.store.file_count() {
    let path = @utf8.decode_lossy(report.store.file_path(id)[:])
    match tree.files.get(path) {
      Some(size) => assert_eq(report.store.file(id).unwrap().size(), size)
      None => abort("the reference walk did not see file \{path}")
    }
  }
  for id in 0..<report.store.folder_count() {
    let path = @utf8.decode_lossy(report.store.folder_path(id)[:])
    match tree.folders.get(path) {
      Some(size) => assert_eq(report.store.folder(id).unwrap().size(), size)
      None => abort("the reference walk did not see folder \{path}")
    }
  }
}
