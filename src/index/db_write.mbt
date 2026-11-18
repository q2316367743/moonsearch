///|
/// One section payload waiting to be placed in the file.
priv struct PendingSection {
  kind : Int32
  data : Bytes
  offset : Int32
}

///|
/// Serialize the whole index into the MSDB v2 byte layout.
///
/// The writer is deterministic: names are sorted, dictionary keys follow the
/// fixed basic-key order followed by extensions, categories, and roots, and
/// range fields follow `RangeField::all`. Two runs over the same index therefore
/// produce identical bytes, which is what makes golden and corruption tests
/// meaningful.
pub fn Index::to_bytes(self : Index) -> Bytes raise DbError {
  let store = self.store
  let folder_count = store.folder_count()
  let file_count = store.file_count()
  let total = folder_count + file_count
  if total > DB_MAX_ENTRIES {
    raise DbError::TooLarge("the entry count exceeds the format limit")
  }
  let (names, name_index) = collect_names(store)
  let names_bytes = names_section(names)
  let roots = roots_section(store)
  let folders = folders_section(store, name_index)
  let files = files_section(store, name_index)
  let order = order_section(store, total)
  let (dict, dict_count) = dict_section(self.dict)
  if dict_count > DB_MAX_DICT_KEYS {
    raise DbError::TooLarge("the dictionary key count exceeds the format limit")
  }
  let (ranges, range_count) = ranges_section(self.ranges)
  let (postings, trigram_count, has_trigram) = match self.trigram {
    Some(trigram) => {
      let count = trigram.key_count()
      if count > DB_MAX_TRIGRAM_KEYS {
        raise DbError::TooLarge(
          "the trigram key count exceeds the format limit",
        )
      }
      (postings_section(trigram), count, true)
    }
    None => (b"", 0, false)
  }
  let sections : Array[(Int32, Bytes)] = [
    (SECTION_ROOTS, roots),
    (SECTION_NAMES, names_bytes),
    (SECTION_FOLDERS, folders),
    (SECTION_FILES, files),
    (SECTION_ORDER, order),
    (SECTION_DICT, dict),
    (SECTION_RANGES, ranges),
  ]
  if has_trigram {
    sections.push((SECTION_POSTINGS, postings))
  }
  let pending : Array[PendingSection] = []
  let section_count = sections.length() + 1
  let table_size = DB_HEADER_SIZE + section_count * DB_SECTION_ENTRY_SIZE
  let mut offset = table_size
  for pair in sections {
    if offset.to_int64() + pair.1.length().to_int64() > 2147483647L {
      raise DbError::TooLarge("the index exceeds the 2 GiB byte-buffer limit")
    }
    pending.push({ kind: pair.0, data: pair.1, offset, })
    offset = offset + pair.1.length()
  }
  let checksum_offset = offset
  if checksum_offset.to_int64() + 8L > 2147483647L {
    raise DbError::TooLarge("the checksum does not fit in the byte buffer")
  }
  let prefix = @buffer.Buffer(size_hint=table_size)
  write_header(
    prefix,
    folder_count~,
    file_count~,
    root_count=store.roots().length(),
    dict_count~,
    range_count~,
    trigram_count~,
    built_at=store.built_at(),
    has_trigram~,
    section_count~,
  )
  for section in pending {
    prefix.write_uint_le(section.kind.reinterpret_as_uint())
    prefix.write_uint64_le(section.offset.to_uint64())
    prefix.write_uint64_le(section.data.length().to_uint64())
  }
  prefix.write_uint_le(SECTION_CHECKSUM.reinterpret_as_uint())
  prefix.write_uint64_le(checksum_offset.to_uint64())
  prefix.write_uint64_le(8UL)
  let prefix_bytes = prefix.to_bytes()
  let crc = Crc32::new()
  crc.update(prefix_bytes.exact_view())
  let metadata_crc = crc.finish()
  let out = @buffer.Buffer(size_hint=offset + 8)
  out.write_bytes(prefix_bytes.exact_view())
  for section in pending {
    out.write_bytes(section.data.exact_view())
    crc.update(section.data.exact_view())
  }
  let full_crc = crc.finish()
  out.write_uint_le(metadata_crc)
  out.write_uint_le(full_crc)
  out.to_bytes()
}

///|
/// Write the fixed 64-byte header.
fn write_header(
  buffer : @buffer.Buffer,
  folder_count~ : Int32,
  file_count~ : Int32,
  root_count~ : Int32,
  dict_count~ : Int32,
  range_count~ : Int32,
  trigram_count~ : Int32,
  built_at~ : Int64,
  has_trigram~ : Bool,
  section_count~ : Int32,
) -> Unit {
  buffer.write_bytes(DB_MAGIC.exact_view())
  buffer.write_uint16_le(DB_VERSION_MAJOR)
  buffer.write_uint16_le(DB_VERSION_MINOR)
  buffer.write_byte(1)
  buffer.write_bytes(b"\x00\x00\x00")
  let flags = if has_trigram { DB_FLAG_TRIGRAM } else { 0U }
  buffer.write_uint_le(flags)
  buffer.write_int64_le(built_at)
  buffer.write_uint_le(folder_count.reinterpret_as_uint())
  buffer.write_uint_le(file_count.reinterpret_as_uint())
  buffer.write_uint_le(root_count.reinterpret_as_uint())
  buffer.write_uint_le(0U)
  buffer.write_uint_le(dict_count.reinterpret_as_uint())
  buffer.write_uint_le(range_count.reinterpret_as_uint())
  buffer.write_uint_le(trigram_count.reinterpret_as_uint())
  buffer.write_uint64_le(DB_HEADER_SIZE.to_uint64())
  buffer.write_uint_le(section_count.reinterpret_as_uint())
}

///|
/// Collect every distinct name once and return the sorted table plus its
/// reverse index.
///
/// Sorting before front coding maximises shared prefixes; deduplicating keeps
/// repeated names (the common case in real trees) from paying twice. Entries
/// refer to names by table index in FOLDERS/FILES, so the loader can append
/// names to a fresh pool in one pass.
fn collect_names(store : @core.Store) -> (Array[Bytes], Map[Bytes, Int32]) {
  let seen : Map[Bytes, Int32] = Map([])
  let unique : Array[Bytes] = []
  for id in 0..<store.folder_count() {
    match store.folder(id) {
      Some(entry) => remember_name(seen, unique, store.name(entry.name()))
      None => ()
    }
  }
  for id in 0..<store.file_count() {
    match store.file(id) {
      Some(entry) => remember_name(seen, unique, store.name(entry.name()))
      None => ()
    }
  }
  unique.sort_by(fn(left, right) { left.lexical_compare(right) })
  let index : Map[Bytes, Int32] = Map([])
  for position in 0..<unique.length() {
    index.set(unique[position], position)
  }
  (unique, index)
}

///|
/// Add a name to the distinct-name accumulator when it is new.
fn remember_name(
  seen : Map[Bytes, Int32],
  unique : Array[Bytes],
  name : BytesView,
) -> Unit {
  match seen.get_from_bytes(name) {
    Some(_) => ()
    None => {
      let copy = name.to_owned()
      seen.set(copy, unique.length())
      unique.push(copy)
    }
  }
}

///|
/// Serialize the root records.
fn roots_section(store : @core.Store) -> Bytes {
  let buffer = @buffer.Buffer()
  let roots = store.roots()
  buffer.write_uint_le(roots.length().reinterpret_as_uint())
  for root in roots {
    let path = @utf8.encode(root.path)
    buffer.write_uint_le(path.length().reinterpret_as_uint())
    buffer.write_bytes(path[:])
    let flags = if root.one_file_system { 1U } else { 0U }
    buffer.write_uint_le(flags)
    buffer.write_uint_le(root.folder.reinterpret_as_uint())
    buffer.write_uint_le(root.files)
    buffer.write_uint_le(root.folders)
    buffer.write_int64_le(root.size)
  }
  buffer.to_bytes()
}

///|
/// Serialize the front-coded name table.
fn names_section(names : Array[Bytes]) -> Bytes raise DbError {
  let buffer = @buffer.Buffer()
  buffer.write_uint_le(names.length().reinterpret_as_uint())
  let mut total_bytes = 0L
  let mut previous = b""[:]
  for name in names {
    let prefix = common_prefix(previous, name[:])
    let suffix = name.length() - prefix
    buffer.write_uint16_le(prefix.to_uint16())
    buffer.write_uint16_le(suffix.to_uint16())
    buffer.write_bytes(name.exact_view(start=prefix, end=name.length()))
    total_bytes = total_bytes + name.length().to_int64()
    if total_bytes > DB_MAX_NAME_BYTES {
      raise DbError::TooLarge("the name table exceeds the size limit")
    }
    previous = name[:]
  }
  buffer.to_bytes()
}

///|
/// Length of the common byte prefix of two names.
fn common_prefix(left : BytesView, right : BytesView) -> Int32 {
  let limit = if left.length() < right.length() {
    left.length()
  } else {
    right.length()
  }
  let mut index = 0
  while index < limit && left[index] == right[index] {
    index = index + 1
  }
  index
}

///|
/// Serialize the folder records in id order.
fn folders_section(
  store : @core.Store,
  name_index : Map[Bytes, Int32],
) -> Bytes raise DbError {
  let buffer = @buffer.Buffer()
  for id in 0..<store.folder_count() {
    match store.folder(id) {
      Some(entry) => {
        write_parent(buffer, entry.parent())
        buffer.write_uint_le(
          name_index_of(name_index, store, entry.name()).reinterpret_as_uint(),
        )
        buffer.write_uint16_le(entry.flags())
        buffer.write_int64_le(entry.size())
        buffer.write_int64_le(entry.mtime())
        buffer.write_uint_le(entry.num_files())
        buffer.write_uint_le(entry.num_folders())
      }
      None => raise DbError::Corrupt("folder id is out of range")
    }
  }
  buffer.to_bytes()
}

///|
/// Serialize the file records in id order.
fn files_section(
  store : @core.Store,
  name_index : Map[Bytes, Int32],
) -> Bytes raise DbError {
  let buffer = @buffer.Buffer()
  for id in 0..<store.file_count() {
    match store.file(id) {
      Some(entry) => {
        write_parent(buffer, entry.parent())
        buffer.write_uint_le(
          name_index_of(name_index, store, entry.name()).reinterpret_as_uint(),
        )
        buffer.write_uint16_le(entry.flags())
        buffer.write_int64_le(entry.size())
        buffer.write_int64_le(entry.mtime())
      }
      None => raise DbError::Corrupt("file id is out of range")
    }
  }
  buffer.to_bytes()
}

///|
/// Encode a parent id, using `DB_NO_PARENT` for the root marker.
fn write_parent(buffer : @buffer.Buffer, parent : @core.FolderId) -> Unit {
  if parent < 0 {
    buffer.write_uint_le(DB_NO_PARENT)
  } else {
    buffer.write_uint_le(parent.reinterpret_as_uint())
  }
}

///|
/// Resolve an entry's name to its index in the name table.
fn name_index_of(
  name_index : Map[Bytes, Int32],
  store : @core.Store,
  name : @core.NameRef,
) -> Int32 raise DbError {
  match name_index.get_from_bytes(store.name(name)) {
    Some(position) => position
    None => raise DbError::Corrupt("name is missing from the name table")
  }
}

///|
/// Serialize the canonical order as store-wide ids.
fn order_section(store : @core.Store, total : Int32) -> Bytes {
  let buffer = @buffer.Buffer(size_hint=total * 4)
  for entry in store.entries_in_order() {
    buffer.write_uint_le(store.global_id(entry).reinterpret_as_uint())
  }
  buffer.to_bytes()
}

///|
/// Serialize the field dictionary and return its key count.
///
/// Key order is fixed so the bytes are deterministic: the five whole-index
/// sets, then extension buckets in ascending order, then categories by index,
/// then roots by index. Each value is an `Ids` blob prefixed with its byte
/// length, because `Ids::from_bytes` consumes exactly one blob.
fn dict_section(dict : Dict) -> (Bytes, Int32) {
  let buffer = @buffer.Buffer()
  let extension_count = dict.extension_count()
  let category_count = dict.type_category_count()
  let root_count = dict.root_count()
  let key_count = 5 + extension_count + category_count + root_count
  buffer.write_uint_le(key_count.reinterpret_as_uint())
  write_dict_key(buffer, DICT_ALL, b""[:], dict.all())
  write_dict_key(buffer, DICT_FILES, b""[:], dict.files_all())
  write_dict_key(buffer, DICT_FOLDERS, b""[:], dict.folders_all())
  write_dict_key(buffer, DICT_HIDDEN, b""[:], dict.hidden())
  write_dict_key(buffer, DICT_VISIBLE, b""[:], dict.visible())
  for extension in dict.extensions() {
    write_dict_key(
      buffer,
      DICT_EXTENSION,
      extension.extension(),
      extension.ids(),
    )
  }
  for category in @util.TypeCategory::all() {
    write_dict_key(
      buffer,
      DICT_CATEGORY,
      small_payload(category.index().to_byte()),
      dict.type_category(category),
    )
  }
  let roots = dict.roots()
  for position in 0..<roots.length() {
    write_dict_key(
      buffer,
      DICT_ROOT,
      u32_payload(position.reinterpret_as_uint()),
      roots[position],
    )
  }
  (buffer.to_bytes(), key_count)
}

///|
/// Write one dictionary key: kind, payload, then a length-prefixed id blob.
fn write_dict_key(
  buffer : @buffer.Buffer,
  kind : Int32,
  payload : BytesView,
  ids : @ids.Ids,
) -> Unit {
  buffer.write_byte(kind.to_byte())
  buffer.write_uint16_le(payload.length().to_uint16())
  buffer.write_bytes(payload)
  let encoded = ids.to_bytes()
  buffer.write_uint_le(encoded.length().reinterpret_as_uint())
  buffer.write_bytes(encoded[:])
}

///|
/// One-byte payload.
fn small_payload(value : Byte) -> Bytes {
  let buffer = @buffer.Buffer(size_hint=1)
  buffer.write_byte(value)
  buffer.to_bytes()
}

///|
/// Four-byte little-endian payload.
fn u32_payload(value : UInt32) -> Bytes {
  let buffer = @buffer.Buffer(size_hint=4)
  buffer.write_uint_le(value)
  buffer.to_bytes()
}

///|
/// Serialize every range index that is already materialized and return the
/// field count.
///
/// Lazy fields are deliberately skipped: the restored store lets the loader
/// rebuild them on first use, so a `--fast-fields size,mtime` index costs the
/// same in the file as it did in memory.
fn ranges_section(ranges : Ranges) -> (Bytes, Int32) {
  let buffer = @buffer.Buffer()
  let mut count = 0
  for field in RangeField::all() {
    if ranges.is_loaded(field) {
      count = count + 1
    }
  }
  buffer.write_uint_le(count.reinterpret_as_uint())
  for field in RangeField::all() {
    if ranges.is_loaded(field) {
      let index = ranges.field(field)
      buffer.write_byte(range_field_tag(field).to_byte())
      let length = index.len()
      buffer.write_uint_le(length.reinterpret_as_uint())
      for value in index.values() {
        buffer.write_int64_le(value)
      }
      for id in index.ids() {
        buffer.write_uint_le(id.reinterpret_as_uint())
      }
    }
  }
  (buffer.to_bytes(), count)
}

///|
/// Stable on-disk tag of a range field.
fn range_field_tag(field : RangeField) -> Int32 {
  match field {
    Size => RANGE_SIZE
    MTime => RANGE_MTIME
    Depth => RANGE_DEPTH
    ChildCount => RANGE_CHILD_COUNT
    Parent => RANGE_PARENT
  }
}

///|
/// Serialize the trigram keys and delta-varint postings.
fn postings_section(trigram : TrigramIndex) -> Bytes raise DbError {
  let buffer = @buffer.Buffer()
  let count = trigram.key_count()
  buffer.write_uint_le(count.reinterpret_as_uint())
  buffer.write_uint_le(trigram.short_name_count().reinterpret_as_uint())
  for position in 0..<count {
    match (trigram.key_at(position), trigram.posting_at(position)) {
      (Some(key), Some(posting)) => {
        let ids = posting.ids()
        buffer.write_uint_le(key)
        buffer.write_uint_le(ids.length().reinterpret_as_uint())
        let mut previous = 0
        for index in 0..<ids.length() {
          let id = ids[index]
          let delta = if index == 0 { id } else { id - previous }
          write_varint(buffer, delta.reinterpret_as_uint())
          previous = id
        }
      }
      _ => raise DbError::Corrupt("trigram index is inconsistent")
    }
  }
  buffer.to_bytes()
}

///|
/// Write one unsigned LEB128 value.
fn write_varint(buffer : @buffer.Buffer, value : UInt32) -> Unit {
  let mut rest = value
  while rest >= 0x80U {
    buffer.write_byte(((rest & 0x7FU) | 0x80U).to_byte())
    rest = rest >> 7
  }
  buffer.write_byte(rest.to_byte())
}
