///|
/// Paths of a dictionary set, sorted so the comparison is order-insensitive.
fn dict_sorted_paths(store : @core.Store, ids : @ids.Ids) -> Array[String] {
  let paths : Array[String] = []
  for id in ids.to_sorted_ids() {
    match store.entry_at(id) {
      Some(entry) => paths.push(@utf8.decode_lossy(store.entry_path(entry)))
      None => abort("dictionary returned an out-of-range id \{id}")
    }
  }
  sorted_copy(paths)
}

///|
/// Copy and sort path strings.
fn sorted_copy(paths : Array[String]) -> Array[String] {
  let copy = paths.copy()
  copy.sort_by(fn(left, right) { left.compare(right) })
  copy
}

///|
/// The fixture shared with the scan-engine tests.
fn compat_store() -> @core.Store {
  test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
}

///|
test "kind dictionary sets match the scan engine" {
  let store = compat_store()
  let dict = @index.Dict::build(store)
  assert_eq(
    dict_sorted_paths(store, dict.files_all()),
    sorted_copy(matched("file:")),
  )
  assert_eq(
    dict_sorted_paths(store, dict.folders_all()),
    sorted_copy(matched("folder:")),
  )
  // No entry can be both, and together they cover the empty query.
  assert_eq(dict.files_all().intersect(dict.folders_all()).cardinality(), 0)
  assert_eq(dict_sorted_paths(store, dict.all()), sorted_copy(matched("")))
}

///|
test "hidden and visible dictionary sets match the scan engine" {
  let store = compat_store()
  let dict = @index.Dict::build(store)
  assert_eq(
    dict_sorted_paths(store, dict.hidden()),
    sorted_copy(matched("hidden:")),
  )
  assert_eq(
    dict_sorted_paths(store, dict.visible()),
    sorted_copy(matched("nohidden:")),
  )
  assert_eq(
    dict_sorted_paths(store, dict.hidden().intersect(dict.files_all())),
    sorted_copy(matched("file:hidden:")),
  )
  assert_eq(
    dict_sorted_paths(store, dict.hidden().intersect(dict.folders_all())),
    sorted_copy(matched("folder:hidden:")),
  )
  // The modifiers commute: kind first or visibility first means the same set.
  assert_eq(
    dict_sorted_paths(store, dict.hidden().intersect(dict.files_all())),
    sorted_copy(matched("hidden:file:")),
  )
  assert_eq(
    dict_sorted_paths(store, dict.hidden().intersect(dict.folders_all())),
    sorted_copy(matched("hidden:folder:")),
  )
}

///|
test "extension dictionary sets match the scan engine" {
  let store = compat_store()
  let dict = @index.Dict::build(store)
  for extension in ["pdf", "txt", "md", "jpg", "JPG", ""] {
    let expected = sorted_copy(matched("ext:\{extension}"))
    let key = @utf8.encode(extension)
    let actual = dict_sorted_paths(store, dict.extension(key[:]))
    assert_eq(actual, expected)
  }
  let union = dict.lookup_extensions([b"pdf", b"txt"])
  assert_eq(
    dict_sorted_paths(store, union),
    sorted_copy(matched("ext:pdf;txt")),
  )
  // `ext:` never matches folders, even if a folder name has a dot.
  assert_eq(dict.extension(b"docs"[:]).cardinality(), 0)
}

///|
test "built-in macro dictionary sets match the scan engine" {
  let store = compat_store()
  let dict = @index.Dict::build(store)
  for name in ["app", "archive", "audio", "doc", "pic", "video"] {
    let from_dict = dict.builtin_macro(name).unwrap()
    assert_eq(
      dict_sorted_paths(store, from_dict),
      sorted_copy(matched("\{name}:")),
    )
  }
  // The category terms compile to the same extension sets in both engines.
  assert_eq(
    dict_sorted_paths(store, dict.type_category(@util.TypeCategory::Doc)),
    sorted_copy(matched("doc:")),
  )
  assert_eq(
    dict_sorted_paths(store, dict.type_category(@util.TypeCategory::Pic)),
    sorted_copy(matched("pic:")),
  )
}

///|
test "root dictionary sets partition the entry space" {
  let store = compat_store()
  let dict = @index.Dict::build(store)
  assert_eq(dict.root_count(), store.roots().length())
  let mut union = dict.root(0).unwrap()
  for index in 1..<dict.root_count() {
    union = union.union(dict.root(index).unwrap())
  }
  assert_eq(union.to_sorted_ids(), dict.all().to_sorted_ids())
  // Every root set is a subset of the universe and contains its root folder.
  for index in 0..<dict.root_count() {
    let ids = dict.root(index).unwrap()
    assert_eq(ids.intersect(dict.all()).cardinality(), ids.cardinality())
    let folder = store.roots()[index].folder
    assert_true(
      ids.contains(store.global_id(@core.EntryRef::new(@core.Folder, folder))),
    )
  }
}
