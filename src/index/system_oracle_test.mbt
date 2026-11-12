///|
/// Reference metadata collected by an independent recursive walk.
struct RefTree {
  files : Map[String, Int64]
  folders : Map[String, Int64]
}

///|
/// Walk `path` with plain `readdir`/`lstat` calls and record every entry.
///
/// This deliberately does not share code with the scanner: it spells paths
/// with `@util.join_path`, treats symlinks as zero-sized files, and sums
/// subtree sizes on the way out.
async fn reference_walk(path : String, tree : RefTree) -> Int64 {
  let names = @fs.readdir(
    path,
    include_hidden=true,
    include_special=false,
    sort=false,
  )
  let mut total = 0L
  for name in names {
    let child = @util.join_path(path, name)
    let kind = @fs.kind(child, follow_symlink=false)
    if kind is @fs.Directory {
      total = total + reference_walk(child, tree)
    } else {
      let size = if kind is @fs.Regular { @fs.file_size(child) } else { 0L }
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
  @fs.symlink(target="\{dir}/sub", "\{dir}/link")
  let root = @fs.realpath(dir)
  let config = @index.ScanConfig::new(
    roots=[@index.RootSpec::new(path=root)],
    default_excludes=false,
  )
  let report = @index.scan(config, @platform.system_source()) catch {
    err => abort(err.message())
  }
  let tree : RefTree = { files: Map([]), folders: Map([]), }
  let total = reference_walk(root, tree)
  @fs.rmdir(dir, recursive=true)
  // The fixture itself: 5 + 2 + 3 + 1 bytes; the symlink contributes zero.
  assert_eq(total, 11L)
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
