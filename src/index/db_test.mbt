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
fn decoded(
  bytes : Bytes,
  verify~ : Bool = true,
  eager~ : @index.RangeFieldSet = @index.RangeFieldSet::all(),
) -> @index.Index {
  @index.Index::from_bytes(bytes[:], verify~, eager~) catch {
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
/// Little-endian u32 used by the database test fixture rewriter.
fn put_test_u32(bytes : Array[Byte], offset : Int32, value : UInt32) -> Unit {
  for index in 0..<4 {
    bytes[offset + index] = ((value >> (index * 8)) & 0xFFU).to_byte()
  }
}

///|
/// Little-endian u64 used by the database test fixture rewriter.
fn put_test_u64(bytes : Array[Byte], offset : Int32, value : UInt64) -> Unit {
  for index in 0..<8 {
    bytes[offset + index] = ((value >> (index * 8)) & 0xFFUL).to_byte()
  }
}

///|
/// Little-endian i64 used by the range semantic-tamper fixture.
fn put_test_i64(bytes : Array[Byte], offset : Int32, value : Int64) -> Unit {
  let raw = value.reinterpret_as_uint64()
  for index in 0..<8 {
    bytes[offset + index] = ((raw >> (index * 8)) & 0xFFUL).to_byte()
  }
}

///|
/// Read a little-endian u32 from a test fixture.
fn get_test_u32(bytes : Bytes, offset : Int32) -> UInt32 {
  let mut value = 0U
  for index in 0..<4 {
    value = value | (bytes[offset + index].to_uint() << (index * 8))
  }
  value
}

///|
/// Read a little-endian u16 from a test fixture.
fn get_test_u16(bytes : Bytes, offset : Int32) -> UInt16 {
  (bytes[offset].to_uint() | (bytes[offset + 1].to_uint() << 8)).to_uint16()
}

///|
/// Read a little-endian u64 from a test fixture.
fn get_test_u64(bytes : Bytes, offset : Int32) -> UInt64 {
  let mut value = 0UL
  for index in 0..<8 {
    value = value | (bytes[offset + index].to_uint64() << (index * 8))
  }
  value
}

///|
/// CRC-32 over a mutable test buffer range.
fn test_crc32_range(bytes : Array[Byte], start : Int32, end : Int32) -> UInt32 {
  let mut crc = 0xFFFFFFFFU
  for position in start..<end {
    crc = crc ^ bytes[position].to_uint()
    for _ in 0..<8 {
      if (crc & 1U) != 0U {
        crc = 0xEDB88320U ^ (crc >> 1)
      } else {
        crc = crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
/// Split a database into its header and ordered section payloads.
fn database_parts(bytes : Bytes) -> (Array[Byte], Array[(Int32, Bytes)]) {
  let header : Array[Byte] = []
  for index in 0..<64 {
    header.push(bytes[index])
  }
  let count = get_test_u32(bytes, 60).reinterpret_as_int()
  let sections : Array[(Int32, Bytes)] = []
  for index in 0..<count {
    let entry = 64 + index * 20
    let kind = get_test_u32(bytes, entry).reinterpret_as_int()
    let offset = get_test_u64(bytes, entry + 4).to_int()
    let length = get_test_u64(bytes, entry + 12).to_int()
    sections.push(
      (kind, bytes.exact_view(start=offset, end=offset + length).to_owned()),
    )
  }
  (header, sections)
}

///|
/// Rebuild a database with valid metadata/full CRCs after a structural mutation.
fn rebuild_database(
  header : Array[Byte],
  sections : Array[(Int32, Bytes)],
) -> Bytes {
  let table_end = 64 + sections.length() * 20
  put_test_u32(header, 60, sections.length().reinterpret_as_uint())
  let out : Array[Byte] = []
  for byte in header {
    out.push(byte)
  }
  for _ in 0..<(sections.length() * 20) {
    out.push(b'\x00')
  }
  let mut offset = table_end
  let mut checksum_offset = -1
  for index in 0..<sections.length() {
    let (kind, data) = sections[index]
    let entry = 64 + index * 20
    put_test_u32(out, entry, kind.reinterpret_as_uint())
    put_test_u64(out, entry + 4, offset.to_uint64())
    put_test_u64(out, entry + 12, data.length().to_uint64())
    for byte in data {
      out.push(byte)
    }
    if kind == 10 {
      checksum_offset = offset
    }
    offset = offset + data.length()
  }
  let metadata = test_crc32_range(out, 0, table_end)
  put_test_u32(out, checksum_offset, metadata)
  let full = test_crc32_range(out, 0, checksum_offset)
  put_test_u32(out, checksum_offset + 4, full)
  Bytes::from_array(out[:])
}

///|
/// Insert an unknown section immediately before CHECKSUM.
fn insert_before_checksum(bytes : Bytes, kind : Int32, data : Bytes) -> Bytes {
  let (header, sections) = database_parts(bytes)
  let inserted : Array[(Int32, Bytes)] = []
  for pair in sections {
    if pair.0 == 10 {
      inserted.push((kind, data))
    }
    inserted.push(pair)
  }
  rebuild_database(header, inserted)
}

///|
/// Patch one header u32 and repair the checksums.
fn patch_database_header(
  bytes : Bytes,
  offset : Int32,
  value : UInt32,
) -> Bytes {
  let (header, sections) = database_parts(bytes)
  put_test_u32(header, offset, value)
  rebuild_database(header, sections)
}

///|
/// Replace one section payload and repair both checksums.
fn replace_section(
  bytes : Bytes,
  wanted_kind : Int32,
  payload : Bytes,
) -> Bytes {
  let (header, sections) = database_parts(bytes)
  let replaced : Array[(Int32, Bytes)] = []
  for (kind, data) in sections {
    if kind == wanted_kind {
      replaced.push((kind, payload))
    } else {
      replaced.push((kind, data))
    }
  }
  rebuild_database(header, replaced)
}

///|
/// Replace one dictionary key's Ids blob, preserving every other key.
fn replace_dict_ids(bytes : Bytes, key_index : Int32, ids : Bytes) -> Bytes {
  let (header, sections) = database_parts(bytes)
  let replaced : Array[(Int32, Bytes)] = []
  for (kind, data) in sections {
    if kind != 7 {
      replaced.push((kind, data))
      continue
    }
    let mut offset = 4
    for _ in 0..<key_index {
      let payload_length = get_test_u16(data, offset + 1).to_int()
      let length_offset = offset + 3 + payload_length
      let old_ids_length = get_test_u32(data, length_offset).reinterpret_as_int()
      offset = length_offset + 4 + old_ids_length
    }
    let payload_length = get_test_u16(data, offset + 1).to_int()
    let length_offset = offset + 3 + payload_length
    let old_ids_length = get_test_u32(data, length_offset).reinterpret_as_int()
    let old_ids_end = length_offset + 4 + old_ids_length
    let dict : Array[Byte] = []
    for index in 0..<(length_offset + 4) {
      dict.push(data[index])
    }
    put_test_u32(dict, length_offset, ids.length().reinterpret_as_uint())
    for byte in ids {
      dict.push(byte)
    }
    for index in old_ids_end..<data.length() {
      dict.push(data[index])
    }
    replaced.push((kind, Bytes::from_array(dict[:])))
  }
  rebuild_database(header, replaced)
}

///|
/// Replace the first dictionary key's Ids blob, preserving its key header.
fn replace_first_dict_ids(bytes : Bytes, ids : Bytes) -> Bytes {
  replace_dict_ids(bytes, 0, ids)
}

///|
/// Read one unsigned LEB128 value from a posting fixture.
fn get_test_varint(bytes : Bytes, offset : Int32) -> (UInt32, Int32) {
  let mut value = 0U
  let mut shift = 0
  let mut position = offset
  while true {
    let byte = bytes[position].to_uint()
    value = value | ((byte & 0x7FU) << shift)
    position = position + 1
    if (byte & 0x80U) == 0U {
      return (value, position - offset)
    }
    shift = shift + 7
  }
  abort("unreachable")
}

///|
/// Write one unsigned LEB128 value to a posting fixture.
fn put_test_varint(out : Array[Byte], value : UInt32) -> Unit {
  let mut rest = value
  while rest >= 0x80U {
    out.push(((rest & 0x7FU) | 0x80U).to_byte())
    rest = rest >> 7
  }
  out.push(rest.to_byte())
}

///|
/// Replace the first trigram posting while preserving its key and all later
/// postings. The replacement remains structurally valid but may name an entry
/// whose name does not contain the trigram.
fn replace_first_posting_ids(bytes : Bytes, ids : Array[Int32]) -> Bytes {
  let (header, sections) = database_parts(bytes)
  let replaced : Array[(Int32, Bytes)] = []
  for (kind, data) in sections {
    if kind != 9 {
      replaced.push((kind, data))
      continue
    }
    let old_length = get_test_u32(data, 12).reinterpret_as_int()
    let mut position = 16
    for _ in 0..<old_length {
      let (_, used) = get_test_varint(data, position)
      position = position + used
    }
    let postings : Array[Byte] = []
    for index in 0..<16 {
      postings.push(data[index])
    }
    put_test_u32(postings, 12, ids.length().reinterpret_as_uint())
    let mut previous = 0
    for index in 0..<ids.length() {
      let id = ids[index]
      let delta = if index == 0 { id } else { id - previous }
      put_test_varint(postings, delta.reinterpret_as_uint())
      previous = id
    }
    for index in position..<data.length() {
      postings.push(data[index])
    }
    replaced.push((kind, Bytes::from_array(postings[:])))
  }
  rebuild_database(header, replaced)
}

///|
/// Return a decoder error for a database fixture.
fn database_error(bytes : Bytes, verify~ : Bool = true) -> @index.DbError {
  try @index.Index::from_bytes(bytes[:], verify~) catch {
    err => err
  } noraise {
    _ => abort("expected the database to be rejected")
  }
}

///|
/// A semantic mutation must remain structurally loadable without full
/// verification, then fail once derived structures are recomputed from Store.
fn assert_semantic_tamper(bytes : Bytes, message : String) -> Unit {
  ignore(decoded(bytes, verify=false))
  match database_error(bytes, verify=true) {
    @index.DbError::Corrupt(actual) =>
      if !actual.contains(message) {
        abort("expected semantic corruption '\{message}', got '\{actual}'")
      }
    other =>
      abort("expected semantic corruption '\{message}', got \{other.message()}")
  }
  match database_info_error(bytes, verify=true) {
    @index.DbError::Corrupt(actual) =>
      if !actual.contains(message) {
        abort("expected verified info to reject '\{message}', got '\{actual}'")
      }
    other =>
      abort(
        "expected verified info to reject '\{message}', got \{other.message()}",
      )
  }
}

///|
/// Return an info-decoder error for a database fixture.
fn database_info_error(bytes : Bytes, verify~ : Bool = true) -> @index.DbError {
  try @index.DbInfo::from_bytes(bytes[:], verify~) catch {
    err => err
  } noraise {
    _ => abort("expected database info to be rejected")
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
test "database round-trips every exclude rule field and behavior" {
  let rules : Array[@index.ExcludeRule] = [
    @index.ExcludeRule::new(
      kind=@index.Fixed,
      pattern="/data/sub",
      scope=@index.FullPath,
      target=@index.Folders,
    ),
    @index.ExcludeRule::new(
      kind=@index.Glob,
      pattern="*.tmp",
      scope=@index.Basename,
      target=@index.Files,
    ),
    @index.ExcludeRule::new(
      kind=@index.Regex,
      pattern="^/data/.*",
      scope=@index.FullPath,
      target=@index.Both,
      active=false,
    ),
    @index.ExcludeRule::new(
      kind=@index.Fixed,
      pattern=".env",
      scope=@index.Basename,
      target=@index.Both,
    ),
  ]
  let original = @index.Index::build(sample_index().store(), excludes=rules)
  let bytes = encoded(original)
  assert_eq(get_test_u32(bytes, 36), 4U)
  let loaded = decoded(bytes)
  assert_eq(loaded.excludes().length(), 4)
  for position in 0..<rules.length() {
    let actual = loaded.excludes()[position]
    let expected = rules[position]
    assert_eq(actual.pattern(), expected.pattern())
    assert_eq(actual.is_active(), expected.is_active())
    assert_true(
      (actual.kind() is @index.Fixed && expected.kind() is @index.Fixed) ||
      (actual.kind() is @index.Glob && expected.kind() is @index.Glob) ||
      (actual.kind() is @index.Regex && expected.kind() is @index.Regex),
    )
    assert_true(
      (actual.scope() is @index.FullPath && expected.scope() is @index.FullPath) ||
      (actual.scope() is @index.Basename && expected.scope() is @index.Basename),
    )
    assert_true(
      (actual.target() is @index.Folders && expected.target() is @index.Folders) ||
      (actual.target() is @index.Files && expected.target() is @index.Files) ||
      (actual.target() is @index.Both && expected.target() is @index.Both),
    )
  }
  assert_true(loaded.excludes()[0].matches(b"/data/sub"[:], b"sub"[:], true))
  assert_false(loaded.excludes()[0].matches(b"/data/sub"[:], b"sub"[:], false))
  assert_true(
    loaded.excludes()[1].matches(b"/data/x.tmp"[:], b"x.tmp"[:], false),
  )
  assert_false(
    loaded.excludes()[1].matches(b"/data/x.tmp"[:], b"x.tmp"[:], true),
  )
  assert_false(
    loaded.excludes()[2].matches(b"/data/a.txt"[:], b"a.txt"[:], false),
  )
  assert_true(loaded.excludes()[3].matches(b"/data/.env"[:], b".env"[:], false))
  assert_eq(loaded.to_bytes() catch { err => abort(err.message()) }, bytes)
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
test "exclude section validates tags, UTF-8, regexes, counts, and boundaries" {
  let rule = @index.ExcludeRule::parse("glob:*.tmp")
  let original = encoded(
    @index.Index::build(sample_index().store(), excludes=[rule]),
  )
  let (_, sections) = database_parts(original)
  let payload = sections[1].1

  let bad_kind = fuzz_copy(payload)
  bad_kind[4] = b'\x63'
  assert_true(
    database_error(replace_section(original, 2, Bytes::from_array(bad_kind[:])))
    is @index.DbError::Corrupt(_),
  )
  let bad_active = fuzz_copy(payload)
  bad_active[7] = b'\x02'
  assert_true(
    database_error(
      replace_section(original, 2, Bytes::from_array(bad_active[:])),
    )
    is @index.DbError::Corrupt(_),
  )
  let bad_utf8 = fuzz_copy(payload)
  bad_utf8[12] = b'\xff'
  assert_true(
    database_error(replace_section(original, 2, Bytes::from_array(bad_utf8[:])))
    is @index.DbError::Corrupt(_),
  )
  let trailing = fuzz_copy(payload)
  trailing.push(b'\x00')
  assert_true(
    database_error(replace_section(original, 2, Bytes::from_array(trailing[:])))
    is @index.DbError::Corrupt(_),
  )
  assert_true(
    database_error(patch_database_header(original, 36, 2U))
    is @index.DbError::Corrupt(_),
  )

  let invalid_regex : Array[Byte] = [
    b'\x01', b'\x00', b'\x00', b'\x00', b'\x02', b'\x00', b'\x00', b'\x01', b'\x01',
    b'\x00', b'\x00', b'\x00', b'[',
  ]
  assert_true(
    database_error(
      replace_section(original, 2, Bytes::from_array(invalid_regex[:])),
    )
    is @index.DbError::Corrupt(_),
  )
}

///|
test "v3.1 requires excludes while legacy v3.0 loads with an empty snapshot" {
  let original = encoded(sample_index())
  let (header, sections) = database_parts(original)
  let legacy_sections : Array[(Int32, Bytes)] = []
  for pair in sections {
    if pair.0 != 2 {
      legacy_sections.push(pair)
    }
  }
  put_test_u32(header, 36, 0U)
  let missing = rebuild_database(header, legacy_sections)
  match database_error(missing) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("missing excludes section"))
    other => abort("expected a missing EXCLUDES error, got \{other.message()}")
  }
  header[6] = b'\x00'
  header[7] = b'\x00'
  let legacy = rebuild_database(header, legacy_sections)
  let loaded = decoded(legacy)
  assert_eq(loaded.excludes().length(), 0)
  assert_eq(loaded.entry_count(), 7)
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
test "persisted range fields decode lazily without dropping the core" {
  let original = @index.Index::build(
    sample_index().store(),
    eager=@index.RangeFieldSet::of([@index.Size]),
  )
  let loaded = decoded(
    encoded(original),
    verify=false,
    eager=@index.RangeFieldSet::of([@index.Size]),
  )
  assert_true(loaded.ranges().is_loaded(@index.Size))
  assert_false(loaded.ranges().is_loaded(@index.MTime))
  assert_false(loaded.ranges().is_loaded(@index.Depth))
  assert_true(loaded.ranges().is_available(@index.Depth))
  assert_false(loaded.ranges().is_available(@index.ChildFileCount))
  assert_false(loaded.ranges().is_available(@index.ChildFolderCount))
  assert_ranges_equal(loaded.ranges().size(), original.ranges().size())
  assert_ranges_equal(loaded.ranges().depth(), original.ranges().depth())
  assert_true(loaded.ranges().is_loaded(@index.Depth))
  assert_eq(
    loaded.ranges().parent_ids(b"/data/sub"[:]).to_sorted_ids(),
    original.ranges().parent_ids(b"/data/sub"[:]).to_sorted_ids(),
  )
}

///|
test "databases always persist the core ranges and optional child counts on request" {
  let store = sample_index().store()
  let core = @index.Index::build(
    store,
    eager=@index.RangeFieldSet::default(),
    trigram=false,
  )
  let core_bytes = encoded(core)
  assert_eq(get_test_u32(core_bytes, 44), 5U)
  let core_loaded = decoded(core_bytes)
  for field in @index.RangeField::core() {
    assert_true(core_loaded.ranges().is_loaded(field))
  }
  assert_false(core_loaded.ranges().is_available(@index.ChildFileCount))
  assert_false(core_loaded.ranges().is_available(@index.ChildFolderCount))

  let selected = @index.Index::build(
    store,
    eager=@index.RangeFieldSet::of([@index.ChildFileCount]),
    trigram=false,
  )
  let selected_bytes = encoded(selected)
  assert_eq(get_test_u32(selected_bytes, 44), 6U)
  let selected_loaded = decoded(selected_bytes)
  assert_true(selected_loaded.ranges().is_available(@index.ChildFileCount))
  assert_false(selected_loaded.ranges().is_available(@index.ChildFolderCount))
  assert_ranges_equal(
    selected_loaded.ranges().child_file_count(),
    selected.ranges().child_file_count(),
  )
}

///|
test "header follows the documented layout" {
  let bytes = encoded(sample_index())
  assert_eq(bytes.exact_view(start=0, end=4), b"MSDB"[:])
  assert_eq(bytes[4], b'\x03')
  assert_eq(bytes[5], b'\x00')
  assert_eq(bytes[6], b'\x02')
  assert_eq(bytes[8], b'\x01')
  assert_eq(get_test_u32(bytes, 36), 0U)
  assert_eq(get_test_u32(bytes, 44), 7U)
  assert_eq(bytes[60].to_int() | (bytes[61].to_int() << 8), 11)
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
    } else if index == 6 {
      b'\x00'
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
  assert_eq(bytes[60], b'\x0a')
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
  assert_eq(info.format_minor, 2)
  assert_eq(info.folder_count, 2)
  assert_eq(info.file_count, 5)
  assert_eq(info.entry_count(), 7)
  assert_eq(info.root_count, 1)
  assert_eq(info.name_count, 6)
  assert_eq(info.file_size, bytes.length().to_int64())
  assert_true(info.trigram_count > 0)
  assert_eq(info.sections.length(), 11)
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

///|
test "full verification rejects self-consistent dictionary semantic tampering" {
  let original = sample_index()
  let bytes = encoded(original)
  let total = original.entry_count()

  let wrong_files = @ids.Ids::from_sorted([0, 2, 3, 4, 5], total~).to_bytes()
  assert_semantic_tamper(
    replace_dict_ids(bytes, 1, wrong_files),
    "dictionary files set",
  )
  let wrong_folders = @ids.Ids::from_sorted([0, 6], total~).to_bytes()
  assert_semantic_tamper(
    replace_dict_ids(bytes, 2, wrong_folders),
    "dictionary folders set",
  )

  let hidden_id = original.dict().hidden().to_sorted_ids()[0]
  let visible_id = original.dict().visible().to_sorted_ids()[0]
  let wrong_hidden = @ids.Ids::from_sorted([visible_id], total~).to_bytes()
  let visible_ids : Array[Int32] = []
  for id in original.dict().all().to_sorted_ids() {
    if id != visible_id {
      visible_ids.push(id)
    }
  }
  let wrong_visible = @ids.Ids::from_sorted(visible_ids, total~).to_bytes()
  let swapped = replace_dict_ids(bytes, 3, wrong_hidden)
  let swapped = replace_dict_ids(swapped, 4, wrong_visible)
  assert_semantic_tamper(swapped, "dictionary hidden set")
  assert_true(hidden_id >= 0)

  let dict = original.dict()
  let mut txt_position = -1
  let mut pdf_position = -1
  for position in 0..<dict.extension_count() {
    let extension = dict.extensions()[position].extension()
    if @util.eq_bytes(extension, b"txt"[:], false) {
      txt_position = position
    }
    if @util.eq_bytes(extension, b"pdf"[:], false) {
      pdf_position = position
    }
  }
  assert_true(txt_position >= 0 && pdf_position >= 0)
  let txt_ids = dict.extensions()[txt_position].ids().to_sorted_ids()
  let moved = txt_ids[txt_ids.length() - 1]
  let wrong_txt = txt_ids
  ignore(wrong_txt.pop())
  let wrong_pdf = dict.extensions()[pdf_position].ids().to_sorted_ids()
  wrong_pdf.push(moved)
  let extensions = replace_dict_ids(
    bytes,
    5 + txt_position,
    @ids.Ids::from_sorted(wrong_txt, total~).to_bytes(),
  )
  let extensions = replace_dict_ids(
    extensions,
    5 + pdf_position,
    @ids.Ids::from_sorted(wrong_pdf, total~).to_bytes(),
  )
  assert_semantic_tamper(extensions, "dictionary extension set")

  let category_position = 5 +
    dict.extension_count() +
    @util.TypeCategory::Doc.index()
  assert_semantic_tamper(
    replace_dict_ids(bytes, category_position, @ids.Ids::empty().to_bytes()),
    "dictionary doc category",
  )
  let root_position = 5 + dict.extension_count() + dict.type_category_count()
  assert_semantic_tamper(
    replace_dict_ids(bytes, root_position, @ids.Ids::empty().to_bytes()),
    "dictionary root set",
  )
}

///|
test "full verification rejects range values that no longer match Store" {
  let bytes = encoded(sample_index())
  let (_, sections) = database_parts(bytes)
  let mut payload = b""[:]
  for (kind, data) in sections {
    if kind == 8 {
      payload = data
    }
  }
  let ranges = fuzz_copy(payload.to_owned())
  // RANGES starts with count, tag, length, then the first i64 value. Moving the
  // first zero-sized folder to -1 preserves structural ordering.
  put_test_i64(ranges, 9, -1L)
  assert_semantic_tamper(
    replace_section(bytes, 8, Bytes::from_array(ranges[:])),
    "size range values",
  )
}

///|
test "parent paths are required, structurally checked, and semantically verified" {
  let original = encoded(sample_index())
  let (header, sections) = database_parts(original)
  let without_paths : Array[(Int32, Bytes)] = []
  for pair in sections {
    if pair.0 != 11 {
      without_paths.push(pair)
    }
  }
  match database_error(rebuild_database(header, without_paths)) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("missing parent-paths section"))
    other =>
      abort("expected a missing PARENT_PATHS error, got \{other.message()}")
  }

  let mut payload = b""
  for pair in sections {
    if pair.0 == 11 {
      payload = pair.1
    }
  }
  let bad_count = fuzz_copy(payload)
  put_test_u32(bad_count, 0, 3U)
  assert_true(
    database_error(
      replace_section(original, 11, Bytes::from_array(bad_count[:])),
    )
    is @index.DbError::Corrupt(_),
  )

  let duplicate_id = fuzz_copy(payload)
  let duplicate_bytes = Bytes::from_array(duplicate_id[:])
  let first_length = get_test_u32(duplicate_bytes, 4).reinterpret_as_int()
  let first_id = get_test_u32(duplicate_bytes, 8 + first_length)
  let second = 12 + first_length
  let second_length = get_test_u32(duplicate_bytes, second).reinterpret_as_int()
  put_test_u32(duplicate_id, second + 4 + second_length, first_id)
  assert_true(
    database_error(
      replace_section(original, 11, Bytes::from_array(duplicate_id[:])),
    )
    is @index.DbError::Corrupt(_),
  )

  let changed_path = fuzz_copy(payload)
  let path_byte = second + 4 + second_length - 1
  changed_path[path_byte] = (changed_path[path_byte].to_uint() ^ 1U).to_byte()
  assert_semantic_tamper(
    replace_section(original, 11, Bytes::from_array(changed_path[:])),
    "parent paths do not match the store",
  )
}

///|
test "full verification rejects a trigram posting that names a nonmatching entry" {
  let original = sample_index()
  let trigram = original.trigram().unwrap()
  let key = trigram.key_at(0).unwrap()
  let posting = trigram.posting_at(0).unwrap().ids()[:].to_owned()
  let mut false_id = -1
  for id in 0..<original.entry_count() {
    let entry = original.store().entry_at(id).unwrap()
    if !posting.contains(id) &&
      !name_contains_trigram(original.store().entry_name(entry), key) {
      false_id = id
      break
    }
  }
  assert_true(false_id >= 0)
  // Swap rather than append so total coverage counters stay structurally
  // plausible and validation reaches the per-name posting comparison.
  ignore(posting.pop())
  posting.push(false_id)
  posting.sort()
  assert_semantic_tamper(
    replace_first_posting_ids(encoded(original), posting),
    "trigram postings",
  )
}

///|
/// Whether a raw name contains one ASCII-folded trigram key.
fn name_contains_trigram(name : BytesView, key : UInt32) -> Bool {
  if name.length() < 3 {
    return false
  }
  let first = ((key >> 16) & 0xFFU).to_byte()
  let second = ((key >> 8) & 0xFFU).to_byte()
  let third = (key & 0xFFU).to_byte()
  for position in 0..<(name.length() - 2) {
    if @util.ascii_lower(name[position]) == first &&
      @util.ascii_lower(name[position + 1]) == second &&
      @util.ascii_lower(name[position + 2]) == third {
      return true
    }
  }
  false
}

///|
test "checksum must be the last section and end exactly at EOF" {
  let original = encoded(sample_index())
  for tail in [b"\x00", b"appended garbage"] {
    let appended : Array[Byte] = []
    for byte in original {
      appended.push(byte)
    }
    for byte in tail {
      appended.push(byte)
    }
    let bytes = Bytes::from_array(appended[:])
    for verify in [false, true] {
      match database_error(bytes, verify~) {
        @index.DbError::Corrupt(message) =>
          assert_true(message.contains("does not end at EOF"))
        other => abort("expected an EOF error, got \{other.message()}")
      }
      match database_info_error(bytes, verify~) {
        @index.DbError::Corrupt(message) =>
          assert_true(message.contains("does not end at EOF"))
        other => abort("expected an info EOF error, got \{other.message()}")
      }
    }
  }

  let (header, sections) = database_parts(original)
  let checksum = sections[sections.length() - 1]
  let last_payload = sections[sections.length() - 2]
  let reordered : Array[(Int32, Bytes)] = []
  for index in 0..<(sections.length() - 2) {
    reordered.push(sections[index])
  }
  reordered.push(checksum)
  reordered.push(last_payload)
  let middle = rebuild_database(header, reordered)
  match database_error(middle) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("checksum section must be last"))
    other => abort("expected a checksum-order error, got \{other.message()}")
  }
  assert_true(database_info_error(middle) is @index.DbError::Corrupt(_))

  let (header, sections) = database_parts(original)
  let trailing : Array[(Int32, Bytes)] = []
  for section in sections {
    trailing.push(section)
  }
  trailing.push((99, b"unknown after checksum"))
  let after = rebuild_database(header, trailing)
  match database_error(after) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("checksum section must be last"))
    other => abort("expected a trailing-section error, got \{other.message()}")
  }
  assert_true(database_info_error(after) is @index.DbError::Corrupt(_))
}

///|
test "unknown sections before checksum are skipped and covered by full verification" {
  let original = encoded(sample_index())
  let extended = insert_before_checksum(original, 99, b"future-section")
  let loaded = decoded(extended)
  assert_eq(loaded.entry_count(), 7)
  let info = @index.DbInfo::from_bytes(extended[:], verify=true) catch {
    err => abort(err.message())
  }
  assert_eq(info.sections.length(), 12)
  assert_eq(info.sections[10].name, "unknown(99)")
  assert_eq(info.sections[10].length, 14L)

  let (_, sections) = database_parts(extended)
  let unknown_index = sections.length() - 2
  let entry = 64 + unknown_index * 20
  let unknown_offset = get_test_u64(extended, entry + 4).to_int()
  let mutated = fuzz_copy(extended)
  mutated[unknown_offset] = (mutated[unknown_offset].to_int() ^ 1).to_byte()
  let bytes = Bytes::from_array(mutated[:])
  match database_error(bytes) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("file checksum mismatch"))
    other => abort("expected a full-checksum error, got \{other.message()}")
  }
  assert_true(database_info_error(bytes) is @index.DbError::Corrupt(_))
  // Metadata still covers the unchanged table, so a normal load may skip the
  // unknown payload; full verification is what authenticates its contents.
  assert_eq(decoded(bytes, verify=false).entry_count(), 7)
}

///|
test "hostile header counts are rejected before section decoding" {
  let original = encoded(sample_index())
  let cases : Array[(Int32, UInt32)] = [
    (24, 16_777_217U),
    (32, 3U),
    (36, 1_000_001U),
    (40, 1_000_001U),
    (44, 8U),
    (48, 16_777_217U),
  ]
  for (offset, value) in cases {
    let bytes = patch_database_header(original, offset, value)
    assert_true(database_error(bytes) is @index.DbError::Corrupt(_))
    assert_true(database_info_error(bytes) is @index.DbError::Corrupt(_))
  }

  // Patching section_count cannot use the regular rewriter because the table no
  // longer describes the payloads. Repair the CRCs directly to prove the count
  // itself is rejected before a huge table allocation.
  let raw = fuzz_copy(original)
  put_test_u32(raw, 60, 33U)
  let section_count = get_test_u32(original, 60).reinterpret_as_int()
  let table_end = 64 + section_count * 20
  let checksum_offset = get_test_u64(
    original,
    64 + (section_count - 1) * 20 + 4,
  ).to_int()
  put_test_u32(raw, checksum_offset, test_crc32_range(raw, 0, table_end))
  put_test_u32(
    raw,
    checksum_offset + 4,
    test_crc32_range(raw, 0, checksum_offset),
  )
  let bytes = Bytes::from_array(raw[:])
  assert_true(database_error(bytes) is @index.DbError::Corrupt(_))
  assert_true(database_info_error(bytes) is @index.DbError::Corrupt(_))
}

///|
test "ids outside the store are rejected before expansion" {
  let original = encoded(sample_index())

  let empty = encoded(
    @index.Index::build(@index.Builder::new().finish(built_at=0L)),
  )
  let huge_empty = Array::make(5, b'\x00')
  huge_empty[0] = b'\x01'
  put_test_u32(huge_empty, 1, 100_000_000U)
  let invalid_empty = replace_first_dict_ids(
    empty,
    Bytes::from_array(huge_empty[:]),
  )
  match database_error(invalid_empty) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("cardinality exceeds the entry count"))
    other =>
      abort("expected an empty-store cardinality error, got \{other.message()}")
  }

  let sorted = Array::make(13, b'\x00')
  sorted[0] = b'\x01'
  put_test_u32(sorted, 1, 8U)
  for index in 0..<8 {
    sorted[5 + index] = index.to_byte()
  }
  let too_many = replace_first_dict_ids(original, Bytes::from_array(sorted[:]))
  match database_error(too_many) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("cardinality exceeds the entry count"))
    other => abort("expected a cardinality error, got \{other.message()}")
  }

  let bitmap = Array::make(18, b'\x00')
  put_test_u32(bitmap, 1, 1U)
  put_test_u32(bitmap, 5, 1U)
  put_test_u32(bitmap, 9, 1U)
  put_test_u32(bitmap, 14, 1U)
  let wrong_block = replace_first_dict_ids(
    original,
    Bytes::from_array(bitmap[:]),
  )
  match database_error(wrong_block) {
    @index.DbError::Corrupt(message) =>
      assert_true(message.contains("block index is out of range"))
    other => abort("expected a block error, got \{other.message()}")
  }
}

///|
test "database decoding honors caller-provided operation and memory budgets" {
  let bytes = encoded(sample_index())
  let operations = @ids.IdsDecodeBudget::with_limits(
    max_operations=1L,
    max_memory_bytes=1_048_576L,
  )
  let outcome = try
    @index.Index::from_bytes(bytes[:], budget=Some(operations))
  catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(@index.DbError::TooLarge(message)) =>
      assert_true(message.contains("operation budget"))
    _ => abort("expected the operation budget to reject the database")
  }

  let memory = @ids.IdsDecodeBudget::with_limits(
    max_operations=1_000_000L,
    max_memory_bytes=1L,
  )
  let outcome = try
    @index.Index::from_bytes(bytes[:], budget=Some(memory))
  catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(@index.DbError::TooLarge(message)) =>
      assert_true(message.contains("memory budget"))
    _ => abort("expected the memory budget to reject the database")
  }
}

///|
/// Build one of two distinct databases for the concurrent replacement test.
fn atomic_fixture(seed : Int64) -> @index.Index raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/atomic", false, seed)
  ignore(builder.add_file(root, b"value.txt", seed, seed + 1L))
  builder.set_child_counts(root, 1U, 0U)
  builder.add_folder_size(root, seed)
  builder.set_root_stats(0, 1U, 0U, seed)
  @index.Index::build(builder.finish(built_at=seed))
}

///|
async test "concurrent readers see only complete old or new databases" {
  let dir = @fs.tmpdir(prefix="moonsearch-atomic-readers")
  let database = "\{dir}/index.msdb"
  let old = atomic_fixture(1L)
  let new = atomic_fixture(2L)
  let old_bytes = encoded(old)
  let new_bytes = encoded(new)
  old.write_database(database) catch {
    err => abort(err.message())
  }
  @async.with_task_group() <| group => {
    let readers = Array::makei(4, fn(_) {
      group.spawn(() => {
        for _ in 0..<32 {
          let loaded = @index.Index::read_database(database, verify=true) catch {
            err => abort(err.message())
          }
          let bytes = loaded.to_bytes() catch { err => abort(err.message()) }
          assert_true(bytes == old_bytes || bytes == new_bytes)
        }
      })
    })
    let writer = group.spawn(() => {
      for step in 0..<32 {
        let index = if step % 2 == 0 { new } else { old }
        index.write_database(database) catch {
          err => abort(err.message())
        }
      }
    })
    writer.wait()
    for reader in readers {
      reader.wait()
    }
  }
  let names = @fs.readdir(dir, sort=true)
  for name in names {
    assert_false(name.contains(".tmp."))
  }
  @fs.remove(dir, recursive=true)
}

///|
async test "an oversized database is rejected by stat before reading" {
  let dir = @fs.tmpdir(prefix="moonsearch-oversized-db")
  let database = "\{dir}/index.msdb"
  let file = @fs.open(database, mode=WriteOnly, create_mode=CreateOrTruncate) catch {
    _ => abort("cannot open oversized database fixture")
  }
  file.at(2_147_483_648L).write(b"\x00"[:])
  file.close()
  assert_eq(@fs.file_size(database), 2_147_483_649L)
  let outcome = try @index.Index::read_database(database, verify=true) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(@index.DbError::TooLarge(message)) =>
      assert_true(message.contains("2 GiB byte-buffer limit"))
    _ => abort("expected the oversized database to be rejected before reading")
  }
  let info = try @index.read_database_info(database, verify=true) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  assert_true(info is Err(@index.DbError::TooLarge(_)))
  @fs.remove(dir, recursive=true)
}
