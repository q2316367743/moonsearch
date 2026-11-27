///|
/// Build a store with both direct child files and direct child folders.
fn restored_range_store() -> @core.Store raise IndexError {
  let builder = Builder::new()
  let root = builder.add_root(b"/r", false, 10L)
  ignore(builder.add_file(root, b"a.txt", 1L, 20L))
  let sub = builder.add_folder(root, b"sub", 30L)
  ignore(builder.add_file(sub, b"b.txt", 2L, 40L))
  builder.set_child_counts(root, 1U, 1U)
  builder.set_child_counts(sub, 1U, 0U)
  builder.add_folder_size(sub, 2L)
  builder.add_folder_size(root, 3L)
  builder.set_root_stats(0, 2U, 1U, 3L)
  builder.finish(built_at=0L)
}

///|
test "restored ranges decode persisted slices without store-side builders" {
  let original = Index::build(
    restored_range_store(),
    eager=RangeFieldSet::all(),
    trigram=false,
  )
  let bytes = original.to_bytes() catch { err => abort(err.message()) }
  let loaded = Index::from_bytes(
    bytes[:],
    verify=false,
    eager=RangeFieldSet::default(),
  ) catch {
    err => abort(err.message())
  }
  let ranges = loaded.ranges()
  assert_eq(ranges.store_builds, 0)
  assert_eq(ranges.db_decodes, 2)
  assert_true(ranges.is_loaded(Size))
  assert_true(ranges.is_loaded(MTime))
  assert_false(ranges.is_loaded(Depth))
  for field in RangeField::all() {
    assert_true(ranges.is_available(field))
    ignore(ranges.field(field))
  }
  assert_eq(ranges.store_builds, 0)
  assert_eq(ranges.db_decodes, 7)
  assert_eq(ranges.parent_of(b"/r/sub"[:]), Some(1))
  assert_eq(ranges.parent_ids(b"/r"[:]).to_sorted_ids(), [1, 2])
  assert_eq(ranges.store_builds, 0)
  let saved = loaded.to_bytes() catch { err => abort(err.message()) }
  assert_eq(saved, bytes)
}

///|
test "unpersisted optional ranges stay unavailable after loading" {
  let original = Index::build(
    restored_range_store(),
    eager=RangeFieldSet::core(),
    trigram=false,
  )
  let bytes = original.to_bytes() catch { err => abort(err.message()) }
  let loaded = Index::from_bytes(
    bytes[:],
    verify=false,
    eager=RangeFieldSet::default(),
  ) catch {
    err => abort(err.message())
  }
  let ranges = loaded.ranges()
  assert_false(ranges.is_available(ChildFileCount))
  assert_false(ranges.is_available(ChildFolderCount))
  assert_true(ranges.child_file_count().is_empty())
  assert_true(ranges.child_folder_count().is_empty())
  assert_false(ranges.is_loaded(ChildFileCount))
  assert_false(ranges.is_loaded(ChildFolderCount))
  assert_eq(ranges.store_builds, 0)
}
