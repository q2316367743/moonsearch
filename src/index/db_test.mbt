///|
/// Build a small index with duplicate names, a unicode name, a hidden entry,
/// two roots worth of statistics, and every range field.
fn sample_index() -> @index.Index raise @index.IndexError {
  let builder = @index.Builder::new()
  let data = builder.add_root(b"/data", false, 100L)
  let sub = builder.add_folder(data, b"sub", 200L)
  ignore(builder.add_file(data, b"a.txt", 5L, 300L))
  ignore(builder.add_file(data, b"same.txt", 7L, 301L))
  ignore(builder.add_file(sub, b"same.txt", 9L, 302L))
  ignore(builder.add_file(sub, b"报告.pdf", 11L, 303L))
  ignore(
    builder.add_file(sub, b".env", 13L, 304L, flags=@core.ENTRY_FLAG_HIDDEN),
  )
  builder.set_child_counts(data, 2U, 1U)
  builder.set_child_counts(sub, 3U, 0U)
  builder.set_root_stats(0, 2U, 1U, 12L)
  @index.Index::build(builder.finish(built_at=42L))
}

///|
/// Serialize an index or abort the test with the encoder's message.
fn encoded(index : @index.Index) -> Bytes {
  index.to_bytes() catch {
    err => abort(err.message())
  }
}

///|
/// Decode bytes or abort the test with the decoder's message.
fn decoded(bytes : Bytes, verify~ : Bool = true) -> @index.Index {
  @index.Index::from_bytes(bytes[:], verify~) catch {
    err => abort(err.message())
  }
}

///|
/// Stable key of an entry reference for order comparisons.
fn ref_key(entry : @core.EntryRef) -> Int32 {
  if entry.is_folder() {
    entry.id
  } else {
    1000000 + entry.id
  }
}

///|
/// Compare every observable part of two stores.
fn assert_stores_equal(left : @core.Store, right : @core.Store) -> Unit raise {
  assert_eq(left.built_at(), right.built_at())
  assert_eq(left.folder_count(), right.folder_count())
  assert_eq(left.file_count(), right.file_count())
  assert_eq(left.total_size(), right.total_size())
  let left_roots = left.roots()
  let right_roots = right.roots()
  assert_eq(left_roots.length(), right_roots.length())
  for index in 0..<left_roots.length() {
    assert_eq(left_roots[index].path, right_roots[index].path)
    assert_eq(
      left_roots[index].one_file_system,
      right_roots[index].one_file_system,
    )
    assert_eq(left_roots[index].folder, right_roots[index].folder)
    assert_eq(left_roots[index].files, right_roots[index].files)
    assert_eq(left_roots[index].folders, right_roots[index].folders)
    assert_eq(left_roots[index].size, right_roots[index].size)
  }
  for id in 0..<left.folder_count() {
    let a = left.folder(id).unwrap()
    let b = right.folder(id).unwrap()
    assert_eq(left.name(a.name()), right.name(b.name()))
    assert_eq(left.folder_path(id), right.folder_path(id))
    assert_eq(a.parent(), b.parent())
    assert_eq(a.flags(), b.flags())
    assert_eq(a.size(), b.size())
    assert_eq(a.mtime(), b.mtime())
    assert_eq(a.num_files(), b.num_files())
    assert_eq(a.num_folders(), b.num_folders())
  }
  for id in 0..<left.file_count() {
    let a = left.file(id).unwrap()
    let b = right.file(id).unwrap()
    assert_eq(left.name(a.name()), right.name(b.name()))
    assert_eq(left.file_path(id), right.file_path(id))
    assert_eq(a.parent(), b.parent())
    assert_eq(a.flags(), b.flags())
    assert_eq(a.size(), b.size())
    assert_eq(a.mtime(), b.mtime())
  }
  let left_order = left.entries_in_order()
  let right_order = right.entries_in_order()
  assert_eq(left_order.length(), right_order.length())
  for index in 0..<left_order.length() {
    assert_eq(ref_key(left_order[index]), ref_key(right_order[index]))
  }
}

///|
/// Compare every dictionary set, including extension order.
fn assert_dicts_equal(left : @index.Dict, right : @index.Dict) -> Unit raise {
  assert_eq(left.entry_count(), right.entry_count())
  assert_eq(left.all().to_sorted_ids(), right.all().to_sorted_ids())
  assert_eq(left.files_all().to_sorted_ids(), right.files_all().to_sorted_ids())
  assert_eq(
    left.folders_all().to_sorted_ids(),
    right.folders_all().to_sorted_ids(),
  )
  assert_eq(left.hidden().to_sorted_ids(), right.hidden().to_sorted_ids())
  assert_eq(left.visible().to_sorted_ids(), right.visible().to_sorted_ids())
  assert_eq(left.extension_count(), right.extension_count())
  for index in 0..<left.extension_count() {
    let a = left.extensions()[index]
    let b = right.extensions()[index]
    assert_eq(a.extension(), b.extension())
    assert_eq(a.ids().to_sorted_ids(), b.ids().to_sorted_ids())
  }
  assert_eq(left.type_category_count(), right.type_category_count())
  for category in @util.TypeCategory::all() {
    assert_eq(
      left.type_category(category).to_sorted_ids(),
      right.type_category(category).to_sorted_ids(),
    )
  }
  assert_eq(left.root_count(), right.root_count())
  for index in 0..<left.root_count() {
    assert_eq(
      left.root(index).unwrap().to_sorted_ids(),
      right.root(index).unwrap().to_sorted_ids(),
    )
  }
}

///|
/// Compare one range index by its two parallel arrays.
fn assert_ranges_equal(
  left : @index.RangeIndex,
  right : @index.RangeIndex,
) -> Unit raise {
  assert_eq(left.len(), right.len())
  assert_eq(left.values()[:].to_owned(), right.values()[:].to_owned())
  assert_eq(left.ids()[:].to_owned(), right.ids()[:].to_owned())
}

///|
/// Compare every loaded range field and the set of loaded fields.
fn assert_range_sets_equal(
  left : @index.Ranges,
  right : @index.Ranges,
) -> Unit raise {
  for field in @index.RangeField::all() {
    assert_eq(left.is_loaded(field), right.is_loaded(field))
    if left.is_loaded(field) {
      assert_ranges_equal(left.field(field), right.field(field))
    }
  }
}

///|
/// Compare every trigram key and posting.
fn assert_trigrams_equal(
  left : @index.TrigramIndex,
  right : @index.TrigramIndex,
) -> Unit raise {
  assert_eq(left.entry_count(), right.entry_count())
  assert_eq(left.key_count(), right.key_count())
  assert_eq(left.posting_count(), right.posting_count())
  assert_eq(left.short_name_count(), right.short_name_count())
  assert_eq(left.stop_gram_count(), right.stop_gram_count())
  for position in 0..<left.key_count() {
    assert_eq(left.key_at(position), right.key_at(position))
    assert_eq(
      left.posting_at(position).unwrap().ids()[:].to_owned(),
      right.posting_at(position).unwrap().ids()[:].to_owned(),
    )
  }
}

///|
test "database round-trips every part of the index" {
  let original = sample_index()
  let loaded = decoded(encoded(original))
  assert_stores_equal(original.store(), loaded.store())
  assert_dicts_equal(original.dict(), loaded.dict())
  assert_range_sets_equal(original.ranges(), loaded.ranges())
  assert_true(original.trigram() is Some(_))
  assert_trigrams_equal(original.trigram().unwrap(), loaded.trigram().unwrap())
}

///|
test "database round-trips invalid UTF-8 roots and distinct names byte-exactly" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/raw-\xff", false, 10L)
  ignore(builder.add_file(root, b"bad-\xff", 1L, 11L))
  ignore(builder.add_file(root, b"bad-\xfe", 2L, 12L))
  builder.set_child_counts(root, 2U, 0U)
  builder.set_root_stats(0, 2U, 0U, 3L)
  let original = @index.Index::build(builder.finish(built_at=42L))
  let bytes = encoded(original)
  assert_eq(bytes, encoded(original))
  let loaded = decoded(bytes)
  assert_stores_equal(original.store(), loaded.store())
  assert_eq(loaded.store().roots()[0].path, b"/raw-\xff")
  assert_eq(
    loaded.store().entry_name(@core.EntryRef::new(@core.File, 0)),
    b"bad-\xfe"[:],
  )
  assert_eq(
    loaded.store().entry_name(@core.EntryRef::new(@core.File, 1)),
    b"bad-\xff"[:],
  )
  assert_eq(loaded.store().file_path(0), b"/raw-\xff/bad-\xfe")
  assert_eq(loaded.store().file_path(1), b"/raw-\xff/bad-\xff")
  assert_eq(loaded.to_bytes() catch { err => abort(err.message()) }, bytes)
}

///|
test "database round-trips symlink sizes and saturated folder totals" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/r", false, 10L)
  ignore(
    builder.add_file(root, b"link", 7L, 11L, flags=@core.ENTRY_FLAG_SYMLINK),
  )
  ignore(builder.add_file(root, b"large", 9223372036854775800L, 12L))
  builder.set_child_counts(root, 2U, 0U)
  builder.add_folder_size(root, 7L)
  builder.add_folder_size(root, 9223372036854775800L)
  builder.add_folder_size(root, 1L)
  builder.set_root_stats(root, 2U, 0U, 9223372036854775807L)
  let original = @index.Index::build(builder.finish(built_at=42L))
  let bytes = encoded(original)
  let loaded = decoded(bytes)
  assert_stores_equal(original.store(), loaded.store())
  let link = loaded.store().file(1).unwrap()
  assert_true(link.is_symlink())
  assert_eq(link.size(), 7L)
  assert_eq(loaded.store().folder(0).unwrap().size(), 9223372036854775807L)
  assert_eq(loaded.store().roots()[0].size, 9223372036854775807L)
  assert_eq(loaded.store().total_size(), 9223372036854775807L)
  assert_eq(loaded.ranges().size().equal(9223372036854775807L).cardinality(), 1)
  assert_eq(loaded.to_bytes() catch { err => abort(err.message()) }, bytes)
}

///|
test "database rejects a NUL in a root path" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/raw\x00root", false, 0L)
  ignore(builder.add_file(root, b"x", 1L, 0L))
  let bytes = encoded(@index.Index::build(builder.finish(built_at=0L)))
  let outcome = try @index.Index::from_bytes(bytes[:]) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(@index.DbError::Corrupt(message)) =>
      assert_true(message.contains("root path contains NUL"))
    _ => abort("expected a corrupt root path")
  }
}

///|
test "database round-trips an empty index" {
  let original = @index.Index::build(@index.Builder::new().finish(built_at=0L))
  let loaded = decoded(encoded(original))
  assert_stores_equal(original.store(), loaded.store())
  assert_eq(loaded.store().entry_count(), 0)
  assert_dicts_equal(original.dict(), loaded.dict())
  assert_range_sets_equal(original.ranges(), loaded.ranges())
  assert_trigrams_equal(original.trigram().unwrap(), loaded.trigram().unwrap())
}

///|
test "database records a missing trigram index" {
  let original = @index.Index::build(
    @index.Builder::new().finish(built_at=1L),
    trigram=false,
  )
  let loaded = decoded(encoded(original))
  assert_true(original.trigram() is None)
  assert_true(loaded.trigram() is None)
}

///|
test "lazy range fields stay lazy across a round trip" {
  let original = @index.Index::build(
    sample_index().store(),
    eager=@index.RangeFieldSet::of([@index.Size]),
  )
  let loaded = decoded(encoded(original))
  assert_true(loaded.ranges().is_loaded(@index.Size))
  assert_false(loaded.ranges().is_loaded(@index.MTime))
  assert_false(loaded.ranges().is_loaded(@index.Depth))
  assert_ranges_equal(loaded.ranges().size(), original.ranges().size())
  assert_ranges_equal(loaded.ranges().depth(), original.ranges().depth())
  assert_true(loaded.ranges().is_loaded(@index.Depth))
}

///|
test "header follows the documented layout" {
  let bytes = encoded(sample_index())
  assert_eq(bytes.exact_view(start=0, end=4), b"MSDB"[:])
  assert_eq(bytes[4], b'\x03')
  assert_eq(bytes[5], b'\x00')
  assert_eq(bytes[8], b'\x01')
  assert_eq(bytes[60].to_int() | (bytes[61].to_int() << 8), 9)
  assert_eq(
    bytes[52].to_int() |
    (bytes[53].to_int() << 8) |
    (bytes[54].to_int() << 16) |
    (bytes[55].to_int() << 24),
    64,
  )
}

///|
test "the UTF-8-only v2 database format is rejected" {
  let bytes = encoded(sample_index())
  let old = Bytes::makei(bytes.length(), fn(index) {
    if index == 4 {
      b'\x02'
    } else {
      bytes[index]
    }
  })
  let outcome = try @index.Index::from_bytes(old[:]) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(err) =>
      match err {
        @index.DbError::UnsupportedVersion(major~, minor~) => {
          assert_eq(major, 2)
          assert_eq(minor, 0)
        }
        _ => abort("expected UnsupportedVersion(2, 0)")
      }
    _ => abort("expected the v2 database to be rejected")
  }
}

///|
test "a database without trigram has one fewer section" {
  let bytes = encoded(
    @index.Index::build(sample_index().store(), trigram=false),
  )
  assert_eq(bytes[60], b'\x08')
}

///|
test "every truncation is rejected without a panic" {
  let bytes = encoded(sample_index())
  for length in 0..<bytes.length() {
    let outcome = try
      @index.Index::from_bytes(bytes.exact_view(start=0, end=length))
    catch {
      _ => Err(())
    } noraise {
      _ => Ok(())
    }
    assert_true(outcome is Err(_))
  }
}

///|
test "every single-byte flip fails full verification" {
  let bytes = encoded(sample_index())
  for offset in 0..<bytes.length() {
    let flipped : Array[Byte] = []
    for index in 0..<bytes.length() {
      flipped.push(bytes[index])
    }
    flipped[offset] = (flipped[offset].to_int() ^ 0x5A).to_byte()
    let mutated = Bytes::from_array(flipped[:])
    let outcome = try @index.Index::from_bytes(mutated[:], verify=true) catch {
      _ => Err(())
    } noraise {
      _ => Ok(())
    }
    assert_true(outcome is Err(_))
  }
}

///|
test "garbage input is rejected without a panic" {
  let samples : Array[Bytes] = [
    b"",
    b"MSDB",
    b"not a database at all",
    Bytes::make(64, b'\x00'),
    Bytes::make(256, b'\x7f'),
  ]
  for sample in samples {
    let outcome = try @index.Index::from_bytes(sample[:], verify=true) catch {
      _ => Err(())
    } noraise {
      _ => Ok(())
    }
    assert_true(outcome is Err(_))
  }
}

///|
test "database info reads the header without loading the store" {
  let bytes = encoded(sample_index())
  let info = @index.DbInfo::from_bytes(bytes[:], verify=true) catch {
    err => abort(err.message())
  }
  assert_eq(info.format_major, 3)
  assert_eq(info.format_minor, 0)
  assert_eq(info.folder_count, 2)
  assert_eq(info.file_count, 5)
  assert_eq(info.entry_count(), 7)
  assert_eq(info.root_count, 1)
  assert_eq(info.name_count, 6)
  assert_eq(info.file_size, bytes.length().to_int64())
  assert_true(info.trigram_count > 0)
  assert_eq(info.sections.length(), 9)
}

///|
test "database persists physical canonical ids, parents, roots, and order" {
  let store = canonical_builder(false).finish(built_at=125L) catch {
    err => abort(err.message())
  }
  let original = @index.Index::build(store)
  let bytes = encoded(original)
  let loaded = decoded(bytes)
  let restored = loaded.store()
  let folder_paths = [b"/r", b"/r/a2", b"/r/a10", b"/r/z10"]
  let file_paths = [
    b"/r/file2", b"/r/file10", b"/r/a2/same.txt", b"/r/a10/same.txt",
  ]
  for id in 0..<restored.folder_count() {
    assert_eq(restored.folder_path(id), folder_paths[id])
  }
  for id in 0..<restored.file_count() {
    assert_eq(restored.file_path(id), file_paths[id])
  }
  assert_eq(restored.roots()[0].folder, 0)
  assert_eq(restored.file(2).unwrap().parent(), 1)
  assert_eq(restored.file(3).unwrap().parent(), 2)
  assert_eq(restored.global_id(@core.EntryRef::new(@core.File, 0)), 4)
  let order = restored
    .entries_in_order()
    .map(fn(entry) { restored.global_id(entry) })
  assert_eq(order, [0, 1, 2, 4, 5, 6, 7, 3])
  assert_eq(loaded.ranges().parent_ids(b"/r/a2"[:]).to_sorted_ids(), [6])
  assert_eq(loaded.ranges().depth().equal(1L).to_sorted_ids(), [1, 2, 3, 4, 5])
  assert_eq(loaded.dict().root(0).unwrap().cardinality(), 8)
  assert_eq(loaded.to_bytes() catch { err => abort(err.message()) }, bytes)
}

///|
test "database round-trips duplicate nested-root parent buckets" {
  let store = nested_builder(true).finish(built_at=126L) catch {
    err => abort(err.message())
  }
  let loaded = decoded(encoded(@index.Index::build(store)))
  assert_eq(loaded.store().roots()[0].folder, 0)
  assert_eq(loaded.store().roots()[1].folder, 1)
  assert_eq(loaded.store().file(0).unwrap().parent(), 2)
  assert_eq(loaded.store().file(1).unwrap().parent(), 3)
  assert_eq(loaded.store().file(4).unwrap().parent(), 4)
  assert_eq(loaded.store().file(5).unwrap().parent(), 1)
  assert_eq(loaded.ranges().parent_ids(b"/r/sub"[:]).to_sorted_ids(), [
    2, 3, 7, 8, 9, 10,
  ])
}
