///|
/// A store shaped like a scan of `/r`: two folders under the root and one file
/// in each of them.
fn fixture_store() -> @core.Store raise @core.NamePoolError {
  let names = @core.NamePool::new()
  let root = names.add(b"/r"[:])
  let sub = names.add(b"sub"[:])
  let deep = names.add(b"deep"[:])
  let first = names.add(b"a.txt"[:])
  let second = names.add(b"b.bin"[:])
  let folders = [
    @core.Entry::folder(parent=@core.NO_PARENT, name=root, mtime=10L),
    @core.Entry::folder(parent=0, name=sub, mtime=11L),
    @core.Entry::folder(parent=1, name=deep, mtime=12L),
  ]
  let files = [
    @core.Entry::file(parent=0, name=first, size=3L, mtime=20L),
    @core.Entry::file(parent=2, name=second, size=4L, mtime=21L),
  ]
  @core.Store::new(
    names~,
    folders~,
    files~,
    roots=[
      {
        path: "/r",
        one_file_system: false,
        folder: 0,
        files: 2U,
        folders: 2U,
        size: 7L,
      },
    ],
    built_at=99L,
  )
}

///|
/// A store whose root is `/`, so path joining must not double the separator.
fn slash_root_store() -> @core.Store raise @core.NamePoolError {
  let names = @core.NamePool::new()
  let root = names.add(b"/"[:])
  let tmp = names.add(b"tmp"[:])
  let file = names.add(b"x"[:])
  @core.Store::new(
    names~,
    folders=[
      @core.Entry::folder(parent=@core.NO_PARENT, name=root, mtime=0L),
      @core.Entry::folder(parent=0, name=tmp, mtime=0L),
    ],
    files=[@core.Entry::file(parent=1, name=file, size=1L, mtime=0L)],
    roots=[],
    built_at=0L,
  )
}

///|
test "a store reports its counts and build time" {
  let store = fixture_store()
  assert_eq(store.folder_count(), 3)
  assert_eq(store.file_count(), 2)
  assert_eq(store.entry_count(), 5)
  assert_eq(store.built_at(), 99L)
  assert_eq(store.name_count(), 5)
  assert_eq(store.name_bytes(), 2 + 3 + 4 + 5 + 5)
  assert_eq(store.roots().length(), 1)
  assert_eq(store.roots()[0].path, "/r")
  assert_eq(store.roots()[0].folder, 0)
}

///|
test "entries resolve through their ids" {
  let store = fixture_store()
  let root = store.folder(0).unwrap()
  assert_true(root.is_root())
  assert_eq(root.mtime(), 10L)
  let deep = store.folder(2).unwrap()
  assert_eq(deep.parent(), 1)
  assert_eq(deep.mtime(), 12L)
  let second = store.file(1).unwrap()
  assert_eq(second.parent(), 2)
  assert_eq(second.size(), 4L)
  assert_eq(second.mtime(), 21L)
}

///|
test "out-of-range ids yield None or empty paths" {
  let store = fixture_store()
  assert_true(store.folder(-1) is None)
  assert_true(store.folder(3) is None)
  assert_true(store.file(-1) is None)
  assert_true(store.file(2) is None)
  assert_eq(store.folder_path(-1), b"")
  assert_eq(store.folder_path(3), b"")
  assert_eq(store.file_path(-1), b"")
  assert_eq(store.file_path(2), b"")
}

///|
test "paths are reconstructed through the parent chain" {
  let store = fixture_store()
  assert_eq(store.folder_path(0), b"/r")
  assert_eq(store.folder_path(1), b"/r/sub")
  assert_eq(store.folder_path(2), b"/r/sub/deep")
  assert_eq(store.file_path(0), b"/r/a.txt")
  assert_eq(store.file_path(1), b"/r/sub/deep/b.bin")
}

///|
test "a root of / does not produce a doubled separator" {
  let store = slash_root_store()
  assert_eq(store.folder_path(0), b"/")
  assert_eq(store.folder_path(1), b"/tmp")
  assert_eq(store.file_path(0), b"/tmp/x")
}

///|
test "a root with a trailing separator joins once" {
  let names = @core.NamePool::new()
  let root = names.add(b"/r/"[:])
  let child = names.add(b"a"[:])
  let grandchild = names.add(b"b"[:])
  let store = @core.Store::new(
    names~,
    folders=[
      @core.Entry::folder(parent=@core.NO_PARENT, name=root, mtime=0L),
      @core.Entry::folder(parent=0, name=child, mtime=0L),
    ],
    files=[@core.Entry::file(parent=1, name=grandchild, size=0L, mtime=0L)],
    roots=[],
    built_at=0L,
  )
  assert_eq(store.folder_path(1), b"/r/a")
  assert_eq(store.file_path(0), b"/r/a/b")
}

///|
test "multiple roots keep their order and paths" {
  let names = @core.NamePool::new()
  let first_root = names.add(b"/a"[:])
  let first_file = names.add(b"one"[:])
  let second_root = names.add(b"/b"[:])
  let second_folder = names.add(b"sub"[:])
  let second_file = names.add(b"two"[:])
  let store = @core.Store::new(
    names~,
    folders=[
      @core.Entry::folder(parent=@core.NO_PARENT, name=first_root, mtime=0L),
      @core.Entry::folder(parent=@core.NO_PARENT, name=second_root, mtime=0L),
      @core.Entry::folder(parent=1, name=second_folder, mtime=0L),
    ],
    files=[
      @core.Entry::file(parent=0, name=first_file, size=2L, mtime=0L),
      @core.Entry::file(parent=2, name=second_file, size=5L, mtime=0L),
    ],
    roots=[
      {
        path: "/a",
        one_file_system: false,
        folder: 0,
        files: 1U,
        folders: 0U,
        size: 2L,
      },
      {
        path: "/b",
        one_file_system: true,
        folder: 1,
        files: 1U,
        folders: 1U,
        size: 5L,
      },
    ],
    built_at=1L,
  )
  assert_eq(store.roots().length(), 2)
  assert_eq(store.roots()[0].path, "/a")
  assert_eq(store.roots()[1].path, "/b")
  assert_true(store.roots()[1].one_file_system)
  assert_eq(store.file_path(0), b"/a/one")
  assert_eq(store.file_path(1), b"/b/sub/two")
  assert_eq(store.folder_path(2), b"/b/sub")
}

///|
test "a file without a parent uses its own name as path" {
  let names = @core.NamePool::new()
  let orphan = names.add(b"orphan"[:])
  let store = @core.Store::new(
    names~,
    folders=[],
    files=[
      @core.Entry::file(parent=@core.NO_PARENT, name=orphan, size=0L, mtime=0L),
    ],
    roots=[],
    built_at=0L,
  )
  assert_eq(store.file_path(0), b"orphan")
}

///|
test "a broken parent chain truncates the path instead of failing" {
  let names = @core.NamePool::new()
  let orphan = names.add(b"orphan"[:])
  let store = @core.Store::new(
    names~,
    folders=[],
    files=[@core.Entry::file(parent=99, name=orphan, size=0L, mtime=0L)],
    roots=[],
    built_at=0L,
  )
  assert_eq(store.file_path(0), b"orphan")
}

///|
test "total_size sums files only" {
  let store = fixture_store()
  // Folder sizes are subtree totals, so adding them would double count.
  assert_eq(store.total_size(), 7L)
  let empty = @core.Store::new(
    names=@core.NamePool::new(),
    folders=[],
    files=[],
    roots=[],
    built_at=0L,
  )
  assert_eq(empty.total_size(), 0L)
  assert_eq(empty.entry_count(), 0)
}

///|
test "names are readable through the references entries store" {
  let store = fixture_store()
  let first = store.file(0).unwrap()
  assert_eq(store.name(first.name()), b"a.txt"[:])
  let root = store.folder(0).unwrap()
  assert_eq(store.name(root.name()), b"/r"[:])
  // Same bytes, same name pool entry; the pool does not deduplicate names.
  let deep = store.folder(2).unwrap()
  assert_eq(store.name(deep.name()), b"deep"[:])
}

///|
test "entries follow the canonical name then path order" {
  let store = fixture_store()
  let entries = store.entries_in_order()
  assert_eq(entries.length(), 5)
  // Names: "/r", "a.txt", "b.bin", "deep", "sub".
  assert_true(entries[0].kind is @core.Folder)
  assert_eq(entries[0].id, 0)
  assert_true(entries[1].kind is @core.File)
  assert_eq(entries[1].id, 0)
  assert_true(entries[2].kind is @core.File)
  assert_eq(entries[2].id, 1)
  assert_true(entries[3].kind is @core.Folder)
  assert_eq(entries[3].id, 2)
  assert_true(entries[4].kind is @core.Folder)
  assert_eq(entries[4].id, 1)
  assert_eq(store.entry_name(entries[1]), b"a.txt"[:])
  assert_eq(store.entry_path(entries[2]), b"/r/sub/deep/b.bin")
  assert_eq(store.entry_size(entries[2]), Some(4L))
  assert_eq(store.entry_mtime(entries[2]), Some(21L))
}

///|
test "equal names are ordered by full path" {
  let names = @core.NamePool::new()
  let root_name = names.add(b"/r"[:])
  let sub_name = names.add(b"sub"[:])
  let a_root = names.add(b"a.txt"[:])
  let a_sub = names.add(b"a.txt"[:])
  let store = @core.Store::new(
    names~,
    folders=[
      @core.Entry::folder(parent=@core.NO_PARENT, name=root_name, mtime=0L),
      @core.Entry::folder(parent=0, name=sub_name, mtime=0L),
    ],
    files=[
      @core.Entry::file(parent=1, name=a_sub, size=1L, mtime=0L),
      @core.Entry::file(parent=0, name=a_root, size=1L, mtime=0L),
    ],
    roots=[],
    built_at=0L,
  )
  let entries = store.entries_in_order()
  assert_eq(entries.length(), 4)
  assert_eq(store.entry_path(entries[0]), b"/r")
  assert_eq(store.entry_path(entries[1]), b"/r/a.txt")
  assert_eq(store.entry_path(entries[2]), b"/r/sub/a.txt")
  assert_eq(store.entry_path(entries[3]), b"/r/sub")
}
