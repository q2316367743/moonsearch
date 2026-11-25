///|
/// Build an ASCII name of exactly `length` bytes.
fn builder_long_name(length : Int32) -> Bytes {
  Bytes::make(length, b'b')
}

///|
test "the builder tracks entries and root statistics" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/r", false, 10L)
  assert_eq(root, 0)
  assert_eq(builder.root_count(), 1)
  assert_eq(builder.folder_count(), 1)
  let sub = builder.add_folder(root, b"sub", 11L, flags=@core.ENTRY_FLAG_HIDDEN)
  assert_eq(sub, 1)
  let file = builder.add_file(sub, b"a.txt", 7L, 12L)
  assert_eq(file, 0)
  assert_eq(builder.folder_count(), 2)
  assert_eq(builder.file_count(), 1)
  builder.set_child_counts(sub, 1U, 0U)
  builder.add_folder_size(sub, 7L)
  builder.add_folder_size(root, 7L)
  builder.set_root_stats(0, 1U, 1U, 7L)
  let store = builder.finish(built_at=99L)
  assert_eq(store.built_at(), 99L)
  assert_eq(store.folder_count(), 2)
  assert_eq(store.file_count(), 1)
  assert_eq(store.folder(1).unwrap().num_files(), 1U)
  assert_eq(store.folder(1).unwrap().size(), 7L)
  assert_eq(store.roots()[0].files, 1U)
  assert_eq(store.roots()[0].folders, 1U)
  assert_eq(store.roots()[0].size, 7L)
  assert_eq(store.file_path(0), b"/r/sub/a.txt")
}

///|
test "finish without an explicit timestamp uses the current time" {
  let builder = @index.Builder::new()
  ignore(builder.add_root(b"/r", false, 0L))
  let store = builder.finish()
  assert_true(store.built_at() > 0L)
}

///|
test "builder folder size accumulation saturates" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/r", false, 0L)
  builder.add_folder_size(root, 9223372036854775800L)
  builder.add_folder_size(root, 100L)
  builder.add_folder_size(root, 1L)
  let store = builder.finish(built_at=0L)
  assert_eq(store.folder(0).unwrap().size(), 9223372036854775807L)
}

///|
test "the builder translates an over-long name into an index error" {
  let builder = @index.Builder::new()
  let name = builder_long_name(@core.MAX_NAME_LEN + 1)
  let err = try {
    let _ = builder.add_file(0, name, 1L, 0L)
    ()
  } catch {
    err => err
  } noraise {
    _ => abort("expected the name to be rejected")
  }
  match err {
    @index.NameTooLong(length) => {
      assert_eq(length, @core.MAX_NAME_LEN + 1)
      assert_true(err.message().contains("too long"))
    }
    _ => abort("expected NameTooLong, got \{err.message()}")
  }
  // The rejected name did not add an entry.
  assert_eq(builder.file_count(), 0)
}

///|
/// Build the same logical tree with two different insertion orders.
fn canonical_builder(reverse : Bool) -> @index.Builder raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/r", false, 10L)
  let (a2, a10) = if reverse {
    let a10 = builder.add_folder(root, b"a10", 11L)
    let a2 = builder.add_folder(root, b"a2", 13L)
    (a2, a10)
  } else {
    let a2 = builder.add_folder(root, b"a2", 13L)
    let a10 = builder.add_folder(root, b"a10", 11L)
    (a2, a10)
  }
  let z10 = builder.add_folder(root, b"z10", 12L)
  if reverse {
    ignore(builder.add_file(a10, b"same.txt", 4L, 20L))
    ignore(builder.add_file(a2, b"same.txt", 3L, 20L))
    ignore(builder.add_file(root, b"file2", 2L, 20L))
    ignore(builder.add_file(root, b"file10", 1L, 20L))
  } else {
    ignore(builder.add_file(root, b"file10", 1L, 20L))
    ignore(builder.add_file(root, b"file2", 2L, 20L))
    ignore(builder.add_file(a2, b"same.txt", 3L, 20L))
    ignore(builder.add_file(a10, b"same.txt", 4L, 20L))
  }
  builder.set_child_counts(a2, 1U, 0U)
  builder.set_child_counts(a10, 1U, 0U)
  builder.set_child_counts(z10, 0U, 0U)
  builder.set_child_counts(root, 2U, 3U)
  builder.add_folder_size(a2, 3L)
  builder.add_folder_size(a10, 4L)
  builder.add_folder_size(root, 10L)
  builder.set_root_stats(0, 4U, 3U, 10L)
  builder
}

///|
/// Serialize an index for a deterministic builder assertion.
fn canonical_bytes(store : @core.Store) -> Bytes {
  @index.Index::build(store).to_bytes() catch {
    err => abort(err.message())
  }
}

///|
test "finish physically canonicalizes ids and is byte-deterministic" {
  let forward = canonical_builder(false).finish(built_at=123L) catch {
    err => abort(err.message())
  }
  let reverse = canonical_builder(true).finish(built_at=123L) catch {
    err => abort(err.message())
  }
  let folder_paths = [b"/r", b"/r/a2", b"/r/a10", b"/r/z10"]
  let file_paths = [
    b"/r/file2", b"/r/file10", b"/r/a2/same.txt", b"/r/a10/same.txt",
  ]
  for id in 0..<forward.folder_count() {
    assert_eq(forward.folder_path(id), folder_paths[id])
    assert_eq(reverse.folder_path(id), folder_paths[id])
  }
  for id in 0..<forward.file_count() {
    assert_eq(forward.file_path(id), file_paths[id])
    assert_eq(reverse.file_path(id), file_paths[id])
  }
  assert_eq(forward.roots()[0].folder, 0)
  assert_eq(forward.file(0).unwrap().parent(), 0)
  assert_eq(forward.file(1).unwrap().parent(), 0)
  assert_eq(forward.file(2).unwrap().parent(), 1)
  assert_eq(forward.file(3).unwrap().parent(), 2)
  assert_eq(forward.global_id(@core.EntryRef::new(@core.File, 0)), 4)
  let ordered_paths = forward
    .entries_in_order()
    .map(fn(entry) { forward.entry_path(entry) })
  assert_eq(ordered_paths, [
    b"/r", b"/r/a2", b"/r/a10", b"/r/file2", b"/r/file10", b"/r/a2/same.txt", b"/r/a10/same.txt",
    b"/r/z10",
  ])
  assert_eq(canonical_bytes(forward), canonical_bytes(reverse))
}

///|
/// Build nested roots with duplicate paths and shuffled child insertion.
fn nested_builder(reverse : Bool) -> @index.Builder raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/r", false, 10L)
  let outer = builder.add_folder(root, b"sub", 11L)
  let outer_deep = builder.add_folder(outer, b"deep", 12L)
  if reverse {
    ignore(builder.add_file(outer, b"same.txt", 1L, 20L))
    ignore(builder.add_file(outer, b"outer.txt", 3L, 20L))
  } else {
    ignore(builder.add_file(outer, b"outer.txt", 3L, 20L))
    ignore(builder.add_file(outer, b"same.txt", 1L, 20L))
  }
  ignore(builder.add_file(outer_deep, b"deep.txt", 5L, 20L))
  builder.set_child_counts(outer_deep, 1U, 0U)
  builder.add_folder_size(outer_deep, 5L)
  builder.set_child_counts(outer, 2U, 1U)
  builder.add_folder_size(outer, 9L)
  builder.set_root_stats(0, 3U, 2U, 9L)

  let nested = builder.add_root(b"/r/sub", false, 13L)
  let nested_deep = builder.add_folder(nested, b"deep", 14L)
  if reverse {
    ignore(builder.add_file(nested, b"same.txt", 2L, 21L))
    ignore(builder.add_file(nested, b"nested.txt", 4L, 21L))
  } else {
    ignore(builder.add_file(nested, b"nested.txt", 4L, 21L))
    ignore(builder.add_file(nested, b"same.txt", 2L, 21L))
  }
  ignore(builder.add_file(nested_deep, b"deep.txt", 6L, 21L))
  builder.set_child_counts(nested_deep, 1U, 0U)
  builder.add_folder_size(nested_deep, 6L)
  builder.set_child_counts(nested, 2U, 1U)
  builder.add_folder_size(nested, 12L)
  builder.set_root_stats(1, 3U, 1U, 12L)
  builder
}

///|
test "nested roots use deterministic duplicate-path tie-breaks" {
  let forward = nested_builder(false).finish(built_at=124L) catch {
    err => abort(err.message())
  }
  let reverse = nested_builder(true).finish(built_at=124L) catch {
    err => abort(err.message())
  }
  assert_eq(forward.folder_path(0), b"/r")
  assert_eq(forward.folder_path(1), b"/r/sub")
  assert_eq(forward.folder_path(2), b"/r/sub/deep")
  assert_eq(forward.folder_path(3), b"/r/sub/deep")
  assert_eq(forward.folder_path(4), b"/r/sub")
  assert_eq(forward.roots()[0].folder, 0)
  assert_eq(forward.roots()[1].folder, 1)
  assert_eq(forward.file(0).unwrap().parent(), 2)
  assert_eq(forward.file(1).unwrap().parent(), 3)
  assert_eq(forward.file(4).unwrap().parent(), 4)
  assert_eq(forward.file(5).unwrap().parent(), 1)
  let ranges = @index.Ranges::build(forward)
  assert_eq(ranges.parent_of(b"/r/sub"[:]), Some(1))
  assert_eq(ranges.parent_ids(b"/r/sub"[:]).to_sorted_ids(), [2, 3, 7, 8, 9, 10])
  assert_eq(canonical_bytes(forward), canonical_bytes(reverse))
}
