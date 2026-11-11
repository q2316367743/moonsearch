///|
/// Build a name reference without involving a pool.
fn name_ref(length : UInt16) -> @core.NameRef {
  @core.NameRef::new(0U, length)
}

///|
test "file entry keeps its metadata" {
  let file = @core.Entry::file(
    parent=7,
    name=name_ref(5),
    size=12345L,
    mtime=1700000000L,
  )
  assert_eq(file.parent(), 7)
  assert_eq(file.name().byte_len(), 5)
  assert_eq(file.size(), 12345L)
  assert_eq(file.mtime(), 1700000000L)
  assert_eq(file.flags(), 0)
  assert_eq(file.num_files(), 0U)
  assert_eq(file.num_folders(), 0U)
  assert_eq(file.child_count(), 0U)
  assert_false(file.is_root())
  assert_false(file.is_hidden())
  assert_false(file.is_symlink())
}

///|
test "folder entry starts empty and is a root until reparented" {
  let folder = @core.Entry::folder(
    parent=@core.NO_PARENT,
    name=name_ref(1),
    mtime=42L,
  )
  assert_true(folder.is_root())
  assert_eq(folder.size(), 0L)
  assert_eq(folder.child_count(), 0U)
  folder.set_parent(3)
  assert_eq(folder.parent(), 3)
  assert_false(folder.is_root())
}

///|
test "child counts and child_count track direct children" {
  let folder = @core.Entry::folder(
    parent=@core.NO_PARENT,
    name=name_ref(1),
    mtime=0L,
  )
  folder.add_child(@core.EntryKind::File)
  folder.add_child(@core.EntryKind::File)
  folder.add_child(@core.EntryKind::Folder)
  assert_eq(folder.num_files(), 2U)
  assert_eq(folder.num_folders(), 1U)
  assert_eq(folder.child_count(), 3U)
  folder.set_child_counts(10U, 4U)
  assert_eq(folder.num_files(), 10U)
  assert_eq(folder.num_folders(), 4U)
  assert_eq(folder.child_count(), 14U)
}

///|
test "flags report hidden and symlink entries" {
  let both = @core.Entry::file(
    parent=0,
    name=name_ref(4),
    size=0L,
    mtime=0L,
    flags=@core.ENTRY_FLAG_HIDDEN | @core.ENTRY_FLAG_SYMLINK,
  )
  assert_true(both.is_hidden())
  assert_true(both.is_symlink())
  let plain = @core.Entry::file(parent=0, name=name_ref(4), size=0L, mtime=0L)
  assert_false(plain.is_hidden())
  assert_false(plain.is_symlink())
}

///|
test "folder size accumulation saturates instead of overflowing" {
  let folder = @core.Entry::folder(
    parent=@core.NO_PARENT,
    name=name_ref(1),
    mtime=0L,
  )
  folder.add_size(9223372036854775800L)
  folder.add_size(100L)
  assert_eq(folder.size(), 9223372036854775807L)
  // Once saturated, further positive deltas keep the entry at the maximum.
  folder.add_size(1L)
  assert_eq(folder.size(), 9223372036854775807L)
}
