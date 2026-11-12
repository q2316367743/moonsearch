///|
/// Two roots with files, folders, hidden entries, mixed-case extensions, names
/// without extensions, and a folder whose name contains dots.
///
/// ```text
/// /r1                     folders 0
///   docs                  1        report.pdf (0), notes.txt (1)
///   dir.with.dot          2
///   .hidden                       2 (hidden)
///   archive.tar.gz                3
///   noext                         4
///   UPPER.JPG                     5
/// /r2                     3
///   sub                   4        photo.jpeg (6)
///   .secret               5 (hidden)
///   file.                         7
///   notes.TXT                     8
/// ```
fn dict_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let r1 = builder.add_root("/r1", false, 1000L)
  let docs = builder.add_folder(r1, "docs", 1001L)
  ignore(builder.add_file(docs, "report.pdf", 10L, 1002L))
  ignore(builder.add_file(docs, "notes.txt", 20L, 1003L))
  ignore(
    builder.add_file(r1, ".hidden", 5L, 1004L, flags=@core.ENTRY_FLAG_HIDDEN),
  )
  ignore(builder.add_file(r1, "archive.tar.gz", 30L, 1005L))
  ignore(builder.add_file(r1, "noext", 1L, 1006L))
  ignore(builder.add_file(r1, "UPPER.JPG", 40L, 1007L))
  let dotted = builder.add_folder(r1, "dir.with.dot", 1008L)
  builder.set_child_counts(docs, 2U, 0U)
  builder.set_child_counts(dotted, 0U, 0U)
  builder.set_child_counts(r1, 4U, 2U)
  let r2 = builder.add_root("/r2", false, 2000L)
  let sub = builder.add_folder(r2, "sub", 2001L)
  ignore(builder.add_file(sub, "photo.jpeg", 50L, 2002L))
  let secret = builder.add_folder(
    r2,
    ".secret",
    2003L,
    flags=@core.ENTRY_FLAG_HIDDEN,
  )
  ignore(builder.add_file(r2, "file.", 2L, 2004L))
  ignore(builder.add_file(r2, "notes.TXT", 21L, 2005L))
  builder.set_child_counts(sub, 1U, 0U)
  builder.set_child_counts(secret, 0U, 0U)
  builder.set_child_counts(r2, 2U, 2U)
  builder.finish(built_at=0L)
}

///|
/// Paths of a dictionary set, in ascending global id order.
fn dict_paths(store : @core.Store, ids : @ids.Ids) -> Array[String] {
  let paths : Array[String] = []
  for id in ids.to_sorted_ids() {
    match store.entry_at(id) {
      Some(entry) => paths.push(@utf8.decode_lossy(store.entry_path(entry)))
      None => abort("dictionary returned an out-of-range id \{id}")
    }
  }
  paths
}

///|
/// Build the fixture dictionary.
fn fixture_dict() -> (@core.Store, @index.Dict) raise @index.IndexError {
  let store = dict_store()
  (store, @index.Dict::build(store))
}

///|
test "the dictionary covers every entry exactly once" {
  let (store, dict) = fixture_dict()
  assert_eq(dict.entry_count(), 15)
  assert_eq(dict.all().cardinality(), 15)
  assert_eq(dict.files_all().cardinality(), 9)
  assert_eq(dict.folders_all().cardinality(), 6)
  assert_eq(dict.all().to_sorted_ids(), Array::makei(15, fn(id) { id }))
  assert_eq(
    dict.files_all().to_sorted_ids(),
    Array::makei(9, fn(id) { id + 6 }),
  )
  assert_eq(dict.folders_all().to_sorted_ids(), Array::makei(6, fn(id) { id }))
  assert_eq(dict.files_all().intersect(dict.folders_all()).cardinality(), 0)
  assert_eq(store.entry_count(), dict.entry_count())
}

///|
test "hidden and visible split the entry set" {
  let (store, dict) = fixture_dict()
  assert_eq(dict.hidden().to_sorted_ids(), [5, 8])
  assert_eq(dict_paths(store, dict.hidden()), ["/r2/.secret", "/r1/.hidden"])
  assert_eq(dict.visible().cardinality(), 13)
  assert_eq(
    dict.hidden().union(dict.visible()).to_sorted_ids(),
    dict.all().to_sorted_ids(),
  )
  assert_eq(dict.hidden().intersect(dict.visible()).cardinality(), 0)
}

///|
test "extensions are ASCII-folded, sorted, and exclude folders" {
  let (store, dict) = fixture_dict()
  assert_eq(dict.extension_count(), 6)
  let names : Array[String] = []
  for entry in dict.extensions() {
    names.push(@utf8.decode_lossy(entry.extension()))
  }
  assert_eq(names, ["", "gz", "jpeg", "jpg", "pdf", "txt"])
  assert_eq(dict_paths(store, dict.extension(b"pdf"[:])), [
    "/r1/docs/report.pdf",
  ])
  assert_eq(dict_paths(store, dict.extension(b"PDF"[:])), [
    "/r1/docs/report.pdf",
  ])
  assert_eq(dict_paths(store, dict.extension(b"txt"[:])), [
    "/r1/docs/notes.txt", "/r2/notes.TXT",
  ])
  assert_eq(dict_paths(store, dict.extension(b"jpg"[:])), ["/r1/UPPER.JPG"])
  assert_eq(dict_paths(store, dict.extension(b"jpeg"[:])), [
    "/r2/sub/photo.jpeg",
  ])
  assert_eq(dict_paths(store, dict.extension(b"gz"[:])), ["/r1/archive.tar.gz"])
  // The empty extension holds every file without a dot extension.
  assert_eq(dict_paths(store, dict.extension(b""[0:0])), [
    "/r1/.hidden", "/r1/noext", "/r2/file.",
  ])
  // A folder named with dots never contributes an extension bucket.
  assert_eq(dict.extension(b"dot"[:]).cardinality(), 0)
  assert_eq(dict.extension(b"rs"[:]).cardinality(), 0)
}

///|
test "extension lookups union like ext:a;b" {
  let (store, dict) = fixture_dict()
  let ids = dict.lookup_extensions([b"pdf", b"txt"])
  assert_eq(dict_paths(store, ids), [
    "/r1/docs/report.pdf", "/r1/docs/notes.txt", "/r2/notes.TXT",
  ])
  let duplicated = dict.lookup_extensions([b"txt", b"TXT"])
  assert_eq(duplicated.cardinality(), 2)
  assert_eq(dict.lookup_extensions([]).cardinality(), 0)
  assert_eq(dict.lookup_extensions([b"missing"]).cardinality(), 0)
}

///|
test "type categories are materialized from their extension lists" {
  let (store, dict) = fixture_dict()
  assert_eq(dict.type_category_count(), 6)
  assert_eq(dict_paths(store, dict.type_category(@util.TypeCategory::Doc)), [
    "/r1/docs/report.pdf", "/r1/docs/notes.txt", "/r2/notes.TXT",
  ])
  assert_eq(dict_paths(store, dict.type_category(@util.TypeCategory::Pic)), [
    "/r1/UPPER.JPG", "/r2/sub/photo.jpeg",
  ])
  assert_eq(
    dict_paths(store, dict.type_category(@util.TypeCategory::Archive)),
    ["/r1/archive.tar.gz"],
  )
  assert_eq(dict.type_category(@util.TypeCategory::Audio).cardinality(), 0)
  assert_eq(dict.type_category(@util.TypeCategory::Video).cardinality(), 0)
  assert_eq(dict.type_category(@util.TypeCategory::App).cardinality(), 0)
}

///|
test "built-in macro names resolve to category sets" {
  let (store, dict) = fixture_dict()
  let pic = dict.builtin_macro("PIC").unwrap()
  assert_eq(
    pic.to_sorted_ids(),
    dict.type_category(@util.TypeCategory::Pic).to_sorted_ids(),
  )
  assert_eq(dict_paths(store, pic), ["/r1/UPPER.JPG", "/r2/sub/photo.jpeg"])
  assert_true(dict.builtin_macro("doc") is Some(_))
  assert_true(dict.builtin_macro("nope") is None)
  assert_true(dict.builtin_macro("") is None)
}

///|
test "roots cover their whole subtree in configuration order" {
  let (store, dict) = fixture_dict()
  assert_eq(dict.root_count(), 2)
  assert_eq(store.roots().length(), 2)
  assert_eq(dict_paths(store, dict.root(0).unwrap()), [
    "/r1", "/r1/docs", "/r1/dir.with.dot", "/r1/docs/report.pdf", "/r1/docs/notes.txt",
    "/r1/.hidden", "/r1/archive.tar.gz", "/r1/noext", "/r1/UPPER.JPG",
  ])
  assert_eq(dict_paths(store, dict.root(1).unwrap()), [
    "/r2", "/r2/sub", "/r2/.secret", "/r2/sub/photo.jpeg", "/r2/file.", "/r2/notes.TXT",
  ])
  assert_eq(dict.roots().length(), 2)
  assert_true(dict.root(-1) is None)
  assert_true(dict.root(2) is None)
  assert_eq(
    dict.root(0).unwrap().union(dict.root(1).unwrap()).to_sorted_ids(),
    dict.all().to_sorted_ids(),
  )
}

///|
test "root assignment tolerates a parent stored after its child" {
  // The builder always assigns parents first, but Store::new accepts any array
  // order; the root resolver must still find the chain.
  let names = @core.NamePool::new()
  let root_name = names.add(b"/late"[:])
  let child_name = names.add(b"c"[:])
  let file_name = names.add(b"f.txt"[:])
  let store = @core.Store::new(
    names~,
    folders=[
      @core.Entry::folder(parent=1, name=child_name, mtime=0L),
      @core.Entry::folder(parent=@core.NO_PARENT, name=root_name, mtime=0L),
    ],
    files=[@core.Entry::file(parent=0, name=file_name, size=1L, mtime=0L)],
    roots=[
      {
        path: "/late",
        one_file_system: false,
        folder: 1,
        files: 1U,
        folders: 1U,
        size: 1L,
      },
    ],
    built_at=0L,
  )
  let dict = @index.Dict::build(store)
  assert_eq(dict.root_count(), 1)
  assert_eq(dict.root(0).unwrap().to_sorted_ids(), [0, 1, 2])
  assert_eq(dict.extension(b"txt"[:]).to_sorted_ids(), [2])
}

///|
test "the dictionary is deterministic across builds" {
  let (_, first) = fixture_dict()
  let (_, second) = fixture_dict()
  assert_eq(first.extension_count(), second.extension_count())
  for index in 0..<first.extension_count() {
    let left = first.extensions()[index]
    let right = second.extensions()[index]
    assert_eq(left.extension(), right.extension())
    assert_eq(left.ids().to_sorted_ids(), right.ids().to_sorted_ids())
  }
  for index in 0..<first.root_count() {
    assert_eq(
      first.root(index).unwrap().to_sorted_ids(),
      second.root(index).unwrap().to_sorted_ids(),
    )
  }
}

///|
test "an empty store produces empty dictionary sets" {
  let store = @index.Builder::new().finish(built_at=0L)
  let dict = @index.Dict::build(store)
  assert_eq(dict.entry_count(), 0)
  assert_eq(dict.all().cardinality(), 0)
  assert_eq(dict.files_all().cardinality(), 0)
  assert_eq(dict.folders_all().cardinality(), 0)
  assert_eq(dict.hidden().cardinality(), 0)
  assert_eq(dict.visible().cardinality(), 0)
  assert_eq(dict.extension_count(), 0)
  assert_eq(dict.type_category_count(), 6)
  for category in @util.TypeCategory::all() {
    assert_eq(dict.type_category(category).cardinality(), 0)
  }
  assert_eq(dict.root_count(), 0)
}
