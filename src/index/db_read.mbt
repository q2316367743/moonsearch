///|
/// Decode a whole index from the MSDB v3 byte layout.
///
/// The loader validates the header, the section table, both checksums (the
/// metadata one always, the full one when `verify` is set), and every reference
/// before installing it: name indexes, parent ids, order ids, dictionary ids,
/// range ids, and posting ids all have to stay inside the store-wide id space.
/// Any violation becomes a `DbError`; nothing panics.
pub fn Index::from_bytes(
  bytes : BytesView,
  verify~ : Bool = false,
) -> Index raise DbError {
  let envelope = parse_envelope(bytes, verify~)
  if envelope.folder_count > 2147483647 - envelope.file_count {
    raise DbError::Corrupt("entry count is out of range")
  }
  let total = envelope.folder_count + envelope.file_count
  if total > DB_MAX_ENTRIES {
    raise DbError::Corrupt("entry count exceeds the size limit")
  }
  let roots = parse_roots(bytes, envelope)
  let names = parse_names(bytes, envelope, total)
  let (folders, files) = parse_entries(bytes, envelope, names)
  let order = parse_order(bytes, envelope, total)
  let store = @core.Store::restore(
    names=names.pool,
    folders~,
    files~,
    roots~,
    built_at=envelope.built_at,
    order~,
  )
  validate_canonical_order(store)
  let dict = parse_dict(bytes, envelope, total)
  let ranges = parse_ranges(bytes, envelope, store, total)
  let trigram = parse_postings(bytes, envelope, total)
  Index::restore(store~, dict~, ranges~, trigram~)
}

///|
/// Read header-level information without inflating the index.
pub fn DbInfo::from_bytes(
  bytes : BytesView,
  verify~ : Bool = false,
) -> DbInfo raise DbError {
  let envelope = parse_envelope(bytes, verify~)
  for
    kind in [
      SECTION_ROOTS,
      SECTION_NAMES,
      SECTION_FOLDERS,
      SECTION_FILES,
      SECTION_ORDER,
      SECTION_DICT,
      SECTION_RANGES,
    ] {
    ignore(required_section(envelope.sections, kind))
  }
  let names_section = required_section(envelope.sections, SECTION_NAMES)
  if names_section.length < 4 {
    raise DbError::Truncated
  }
  let names_reader = section_reader(bytes, names_section)
  let name_count = checked_count(names_reader.read_u32(), "name")
  if envelope.folder_count > 2147483647 - envelope.file_count ||
    name_count > envelope.folder_count + envelope.file_count {
    raise DbError::Corrupt("name count exceeds the entry count")
  }
  let sections : Array[DbSectionInfo] = []
  for section in envelope.sections {
    sections.push({
      name: section_name(section.kind),
      length: section.length.to_int64(),
    })
  }
  {
    format_major: DB_VERSION_MAJOR.to_int(),
    format_minor: envelope.minor,
    built_at: envelope.built_at,
    folder_count: envelope.folder_count,
    file_count: envelope.file_count,
    root_count: envelope.root_count,
    name_count,
    trigram_count: envelope.trigram_count,
    file_size: bytes.length().to_int64(),
    sections,
  }
}

///|
/// A name pool rebuilt from the NAMES section plus the reference of every name.
priv struct LoadedNames {
  pool : @core.NamePool
  refs : Array[@core.NameRef]
}

///|
/// Parse the root records.
fn parse_roots(
  bytes : BytesView,
  envelope : DbEnvelope,
) -> Array[@core.RootInfo] raise DbError {
  let section = required_section(envelope.sections, SECTION_ROOTS)
  let reader = section_reader(bytes, section)
  let count = checked_count(reader.read_u32(), "root")
  if count != envelope.root_count {
    raise DbError::Corrupt("root count does not match the header")
  }
  let roots : Array[@core.RootInfo] = []
  for _ in 0..<count {
    let path_length = checked_count(reader.read_u32(), "root path length")
    if path_length == 0 || path_length > @core.MAX_NAME_LEN {
      raise DbError::Corrupt("root path length is out of range")
    }
    let path_bytes = reader.read_bytes(path_length)
    if @util.find_byte(path_bytes, b'\x00') is Some(_) {
      raise DbError::Corrupt("root path contains NUL")
    }
    let flags = reader.read_u32()
    let folder = checked_count(reader.read_u32(), "root folder")
    if folder >= envelope.folder_count {
      raise DbError::Corrupt("root folder id is out of range")
    }
    let files = reader.read_u32()
    let folders = reader.read_u32()
    let size = reader.read_i64()
    roots.push(
      @core.RootInfo::new(
        path=path_bytes,
        one_file_system=(flags & 1U) != 0U,
        folder~,
        files~,
        folders~,
        size~,
      ),
    )
  }
  reader.expect_end()
  roots
}

///|
/// Parse the front-coded name table and rebuild a name pool.
fn parse_names(
  bytes : BytesView,
  envelope : DbEnvelope,
  total : Int32,
) -> LoadedNames raise DbError {
  let section = required_section(envelope.sections, SECTION_NAMES)
  let reader = section_reader(bytes, section)
  let count = checked_count(reader.read_u32(), "name")
  if count > total {
    raise DbError::Corrupt("name count exceeds the entry count")
  }
  let pool = @core.NamePool::new()
  let refs : Array[@core.NameRef] = []
  let mut previous = b""[:]
  let mut total_bytes = 0L
  for position in 0..<count {
    let prefix = reader.read_u16().to_int()
    let suffix = reader.read_u16().to_int()
    if prefix > previous.length() {
      raise DbError::Corrupt("name prefix exceeds the previous name")
    }
    if prefix + suffix > @core.MAX_NAME_LEN {
      raise DbError::Corrupt("name is too long")
    }
    let suffix_bytes = reader.read_bytes(suffix)
    let buffer = @buffer.Buffer(capacity=prefix + suffix)
    buffer.write_bytes(previous.exact_view(start=0, end=prefix))
    buffer.write_bytes(suffix_bytes)
    let name = buffer.to_bytes()
    if position > 0 && previous.lexical_compare(name[:]) >= 0 {
      raise DbError::Corrupt("name table is not strictly ascending")
    }
    total_bytes = total_bytes + name.length().to_int64()
    if total_bytes > DB_MAX_NAME_BYTES {
      raise DbError::Corrupt("name table exceeds the size limit")
    }
    let reference = pool.add(name[:]) catch {
      NameTooLong(length) =>
        raise DbError::Corrupt("name is too long (\{length} bytes)")
      PoolFull => raise DbError::Corrupt("name pool is full")
    }
    refs.push(reference)
    previous = name[:]
  }
  reader.expect_end()
  { pool, refs, }
}

///|
/// Parse the folder and file record arrays.
fn parse_entries(
  bytes : BytesView,
  envelope : DbEnvelope,
  names : LoadedNames,
) -> (Array[@core.Entry], Array[@core.Entry]) raise DbError {
  let folder_section = required_section(envelope.sections, SECTION_FOLDERS)
  let expected_folders = envelope.folder_count.to_int64() *
    DB_FOLDER_RECORD_SIZE.to_int64()
  if folder_section.length.to_int64() != expected_folders {
    raise DbError::Corrupt("folder section has the wrong size")
  }
  let folder_reader = section_reader(bytes, folder_section)
  let folders : Array[@core.Entry] = []
  for _ in 0..<envelope.folder_count {
    let parent = read_parent(folder_reader, envelope.folder_count, true)
    let name_index = checked_count(folder_reader.read_u32(), "name index")
    if name_index >= names.refs.length() {
      raise DbError::Corrupt("folder name index is out of range")
    }
    let flags = folder_reader.read_u16()
    let size = folder_reader.read_i64()
    let mtime = folder_reader.read_i64()
    let files = folder_reader.read_u32()
    let child_folders = folder_reader.read_u32()
    let entry = @core.Entry::folder(
      parent~,
      name=names.refs[name_index],
      mtime~,
      flags~,
    )
    entry.add_size(size)
    entry.set_child_counts(files, child_folders)
    folders.push(entry)
  }
  folder_reader.expect_end()
  validate_parent_chains(folders)
  let file_section = required_section(envelope.sections, SECTION_FILES)
  let expected_files = envelope.file_count.to_int64() *
    DB_FILE_RECORD_SIZE.to_int64()
  if file_section.length.to_int64() != expected_files {
    raise DbError::Corrupt("file section has the wrong size")
  }
  let file_reader = section_reader(bytes, file_section)
  let files : Array[@core.Entry] = []
  for _ in 0..<envelope.file_count {
    let parent = read_parent(file_reader, envelope.folder_count, false)
    let name_index = checked_count(file_reader.read_u32(), "name index")
    if name_index >= names.refs.length() {
      raise DbError::Corrupt("file name index is out of range")
    }
    let flags = file_reader.read_u16()
    let size = file_reader.read_i64()
    let mtime = file_reader.read_i64()
    files.push(
      @core.Entry::file(
        parent~,
        name=names.refs[name_index],
        size~,
        mtime~,
        flags~,
      ),
    )
  }
  file_reader.expect_end()
  (folders, files)
}

///|
/// Read a parent id, accepting the root marker only for folders.
fn read_parent(
  reader : DbReader,
  folder_count : Int32,
  allow_root : Bool,
) -> @core.FolderId raise DbError {
  let raw = reader.read_u32()
  if raw == DB_NO_PARENT {
    if allow_root {
      -1
    } else {
      raise DbError::Corrupt("file record has no parent")
    }
  } else {
    let parent = checked_count(raw, "parent")
    if parent >= folder_count {
      raise DbError::Corrupt("parent id is out of range")
    }
    parent
  }
}

///|
/// Reject parent cycles so path reconstruction can never loop forever.
fn validate_parent_chains(folders : Array[@core.Entry]) -> Unit raise DbError {
  let count = folders.length()
  let colors : Array[Byte] = Array::makei(count, fn(_) { b'\x00' })
  for start in 0..<count {
    if colors[start] == b'\x00' {
      let chain : Array[Int32] = []
      let mut current = start
      while current >= 0 && colors[current] == b'\x00' {
        colors[current] = b'\x01'
        chain.push(current)
        current = folders[current].parent()
      }
      if current >= 0 && colors[current] == b'\x01' {
        raise DbError::Corrupt("folder parents form a cycle")
      }
      for node in chain {
        colors[node] = b'\x02'
      }
    }
  }
}

///|
/// Parse the canonical order and convert every global id back to an entry ref.
fn parse_order(
  bytes : BytesView,
  envelope : DbEnvelope,
  total : Int32,
) -> Array[@core.EntryRef] raise DbError {
  let section = required_section(envelope.sections, SECTION_ORDER)
  if section.length.to_int64() != total.to_int64() * 4L {
    raise DbError::Corrupt("order section has the wrong size")
  }
  let reader = section_reader(bytes, section)
  let seen : Array[Bool] = Array::makei(total, fn(_) { false })
  let refs : Array[@core.EntryRef] = []
  for _ in 0..<total {
    let id = checked_count(reader.read_u32(), "order id")
    if id >= total {
      raise DbError::Corrupt("order id is out of range")
    }
    if seen[id] {
      raise DbError::Corrupt("order is not a permutation")
    }
    seen[id] = true
    if id < envelope.folder_count {
      refs.push(@core.EntryRef::new(@core.Folder, id))
    } else {
      refs.push(@core.EntryRef::new(@core.File, id - envelope.folder_count))
    }
  }
  reader.expect_end()
  refs
}

///|
/// Validate that ORDER is still the canonical `(name, path)` sequence.
///
/// Comparing adjacent names is free for the common case; a full path is only
/// materialized when the names tie. Exact name/path ties use the persisted
/// store-wide id, which puts folders before files and matches `Store::new`'s
/// linear merge of the two physically sorted arrays.
fn validate_canonical_order(store : @core.Store) -> Unit raise DbError {
  let order = store.entries_in_order()
  for position in 1..<order.length() {
    let left = order[position - 1]
    let right = order[position]
    let name_order = @util.cmp_paths(
      store.entry_name(left),
      store.entry_name(right),
    )
    if name_order > 0 {
      raise DbError::Corrupt("order is not sorted by name")
    }
    if name_order == 0 {
      let left_path = store.entry_path(left)
      let right_path = store.entry_path(right)
      let path_order = @util.cmp_paths(left_path[:], right_path[:])
      if path_order > 0 {
        raise DbError::Corrupt("order is not sorted by path")
      }
      if path_order == 0 && store.global_id(left) > store.global_id(right) {
        raise DbError::Corrupt("order has an invalid duplicate-path tie-break")
      }
    }
  }
}

///|
/// Validate that an id set stays inside the store-wide id space.
fn validate_ids(ids : @ids.Ids, total : Int32) -> Unit raise DbError {
  for id in ids.to_sorted_ids() {
    if id < 0 || id >= total {
      raise DbError::Corrupt("dictionary id is out of range")
    }
  }
}

///|
/// Parse the field dictionary.
fn parse_dict(
  bytes : BytesView,
  envelope : DbEnvelope,
  total : Int32,
) -> Dict raise DbError {
  let section = required_section(envelope.sections, SECTION_DICT)
  let reader = section_reader(bytes, section)
  let key_count = checked_count(reader.read_u32(), "dictionary")
  if key_count != envelope.dict_count {
    raise DbError::Corrupt("dictionary key count does not match the header")
  }
  if key_count > DB_MAX_DICT_KEYS {
    raise DbError::Corrupt("dictionary key count is out of range")
  }
  let category_count = @util.TypeCategory::all().length()
  let categories : Array[@ids.Ids] = Array::makei(category_count, fn(_) {
    @ids.Ids::empty()
  })
  let categories_seen : Array[Bool] = Array::makei(category_count, fn(_) {
    false
  })
  let roots : Array[@ids.Ids] = Array::makei(envelope.root_count, fn(_) {
    @ids.Ids::empty()
  })
  let roots_seen : Array[Bool] = Array::makei(envelope.root_count, fn(_) {
    false
  })
  let extensions : Array[ExtensionEntry] = []
  let basics_seen : Array[Bool] = Array::makei(8, fn(_) { false })
  let mut all = @ids.Ids::empty()
  let mut files_all = @ids.Ids::empty()
  let mut folders_all = @ids.Ids::empty()
  let mut hidden = @ids.Ids::empty()
  let mut visible = @ids.Ids::empty()
  let mut previous_extension = b""[:]
  let mut has_extension = false
  for _ in 0..<key_count {
    let kind = reader.read_byte().to_int()
    let payload_length = reader.read_u16().to_int()
    let payload = reader.read_bytes(payload_length)
    let ids_length = checked_count(reader.read_u32(), "id set size")
    let ids_bytes = reader.read_bytes(ids_length)
    let ids = @ids.Ids::from_bytes(ids_bytes) catch {
      err => raise DbError::Corrupt(err.message())
    }
    validate_ids(ids, total)
    if kind < 0 || kind >= basics_seen.length() {
      raise DbError::Corrupt("unknown dictionary key kind \{kind}")
    }
    if basics_seen[kind] && kind <= DICT_VISIBLE {
      raise DbError::Corrupt("duplicate dictionary key")
    }
    match kind {
      DICT_EXTENSION => {
        if has_extension && previous_extension.lexical_compare(payload) >= 0 {
          raise DbError::Corrupt("extensions are not strictly ascending")
        }
        previous_extension = payload
        has_extension = true
        extensions.push(ExtensionEntry::new(payload.to_owned(), ids))
      }
      DICT_ALL => {
        basics_seen[kind] = true
        all = ids
      }
      DICT_FILES => {
        basics_seen[kind] = true
        files_all = ids
      }
      DICT_FOLDERS => {
        basics_seen[kind] = true
        folders_all = ids
      }
      DICT_HIDDEN => {
        basics_seen[kind] = true
        hidden = ids
      }
      DICT_VISIBLE => {
        basics_seen[kind] = true
        visible = ids
      }
      DICT_CATEGORY => {
        if payload_length != 1 {
          raise DbError::Corrupt("category payload has the wrong size")
        }
        let index = payload[0].to_int()
        if index < 0 || index >= category_count {
          raise DbError::Corrupt("category index is out of range")
        }
        if categories_seen[index] {
          raise DbError::Corrupt("duplicate category key")
        }
        categories_seen[index] = true
        categories[index] = ids
      }
      DICT_ROOT => {
        if payload_length != 4 {
          raise DbError::Corrupt("root payload has the wrong size")
        }
        let root_reader = DbReader::new(payload)
        let index = checked_count(root_reader.read_u32(), "root index")
        if index < 0 || index >= envelope.root_count {
          raise DbError::Corrupt("root index is out of range")
        }
        if roots_seen[index] {
          raise DbError::Corrupt("duplicate root key")
        }
        roots_seen[index] = true
        roots[index] = ids
      }
      _ => raise DbError::Corrupt("unknown dictionary key kind")
    }
  }
  reader.expect_end()
  for kind in [DICT_ALL, DICT_FILES, DICT_FOLDERS, DICT_HIDDEN, DICT_VISIBLE] {
    if !basics_seen[kind] {
      raise DbError::Corrupt("dictionary is missing a basic key")
    }
  }
  for seen in categories_seen {
    if !seen {
      raise DbError::Corrupt("dictionary is missing a category key")
    }
  }
  for seen in roots_seen {
    if !seen {
      raise DbError::Corrupt("dictionary is missing a root key")
    }
  }
  if all.cardinality() != total ||
    folders_all.cardinality() != envelope.folder_count ||
    files_all.cardinality() != envelope.file_count {
    raise DbError::Corrupt("dictionary counts do not match the header")
  }
  let union = hidden.union(visible)
  if !union.is_empty() && union.cardinality() != total {
    raise DbError::Corrupt("hidden and visible do not cover the index")
  }
  if !hidden.intersect(visible).is_empty() {
    raise DbError::Corrupt("hidden and visible overlap")
  }
  Dict::restore(
    total~,
    all~,
    files_all~,
    folders_all~,
    hidden~,
    visible~,
    extensions~,
    categories~,
    roots~,
  )
}

///|
/// Map a persisted range tag back to its field.
fn range_field_of_tag(tag : Int32) -> RangeField? {
  match tag {
    RANGE_SIZE => Some(Size)
    RANGE_MTIME => Some(MTime)
    RANGE_DEPTH => Some(Depth)
    RANGE_CHILD_COUNT => Some(ChildCount)
    RANGE_PARENT => Some(Parent)
    _ => None
  }
}

///|
/// Parse the range indexes that were saved and leave the rest lazy.
fn parse_ranges(
  bytes : BytesView,
  envelope : DbEnvelope,
  store : @core.Store,
  total : Int32,
) -> Ranges raise DbError {
  let section = required_section(envelope.sections, SECTION_RANGES)
  let reader = section_reader(bytes, section)
  let field_count = checked_count(reader.read_u32(), "range field")
  if field_count != envelope.range_count {
    raise DbError::Corrupt("range field count does not match the header")
  }
  if field_count > 5 {
    raise DbError::Corrupt("range field count is out of range")
  }
  let mut size_index : RangeIndex? = None
  let mut mtime_index : RangeIndex? = None
  let mut depth_index : RangeIndex? = None
  let mut child_count_index : RangeIndex? = None
  let mut parent_index : RangeIndex? = None
  for _ in 0..<field_count {
    let tag = reader.read_byte().to_int()
    let field = match range_field_of_tag(tag) {
      Some(field) => field
      None => raise DbError::Corrupt("unknown range field tag \{tag}")
    }
    if loaded_range(
        field,
        size_index~,
        mtime_index~,
        depth_index~,
        child_count_index~,
        parent_index~,
      ) {
      raise DbError::Corrupt("duplicate range field")
    }
    let length = checked_count(reader.read_u32(), "range length")
    if length > total {
      raise DbError::Corrupt("range length exceeds the entry count")
    }
    if reader.remaining().to_int64() < length.to_int64() * 12L {
      raise DbError::Truncated
    }
    let values : Array[Int64] = []
    for _ in 0..<length {
      values.push(reader.read_i64())
    }
    let ids : Array[Int32] = []
    for _ in 0..<length {
      ids.push(checked_count(reader.read_u32(), "range id"))
    }
    let seen : Array[Bool] = Array::makei(total, fn(_) { false })
    for position in 0..<length {
      let id = ids[position]
      if id < 0 || id >= total {
        raise DbError::Corrupt("range id is out of range")
      }
      if seen[id] {
        raise DbError::Corrupt("range contains a duplicate id")
      }
      seen[id] = true
      if position > 0 {
        let previous = values[position - 1]
        let value = values[position]
        if value < previous || (value == previous && id <= ids[position - 1]) {
          raise DbError::Corrupt("range is not sorted by value and id")
        }
      }
    }
    let index = RangeIndex::restore(values~, ids~, total~)
    match field {
      Size => size_index = Some(index)
      MTime => mtime_index = Some(index)
      Depth => depth_index = Some(index)
      ChildCount => child_count_index = Some(index)
      Parent => parent_index = Some(index)
    }
  }
  reader.expect_end()
  Ranges::restore(
    store,
    size_index~,
    mtime_index~,
    depth_index~,
    child_count_index~,
    parent_index~,
  )
}

///|
/// Whether a field is already present in one of the loader's slots.
fn loaded_range(
  field : RangeField,
  size_index~ : RangeIndex?,
  mtime_index~ : RangeIndex?,
  depth_index~ : RangeIndex?,
  child_count_index~ : RangeIndex?,
  parent_index~ : RangeIndex?,
) -> Bool {
  match field {
    Size => size_index is Some(_)
    MTime => mtime_index is Some(_)
    Depth => depth_index is Some(_)
    ChildCount => child_count_index is Some(_)
    Parent => parent_index is Some(_)
  }
}

///|
/// Parse the trigram postings, or return `None` when the index was written
/// without them.
fn parse_postings(
  bytes : BytesView,
  envelope : DbEnvelope,
  total : Int32,
) -> TrigramIndex? raise DbError {
  let has_trigram = (envelope.flags & DB_FLAG_TRIGRAM) != 0U
  if !has_trigram {
    if envelope.trigram_count != 0 {
      raise DbError::Corrupt("trigram count is set without a postings section")
    }
    return None
  }
  let section = required_section(envelope.sections, SECTION_POSTINGS)
  let reader = section_reader(bytes, section)
  let key_count = checked_count(reader.read_u32(), "trigram")
  if key_count != envelope.trigram_count {
    raise DbError::Corrupt("trigram key count does not match the header")
  }
  if key_count > DB_MAX_TRIGRAM_KEYS {
    raise DbError::Corrupt("trigram key count is out of range")
  }
  let short_names = checked_count(reader.read_u32(), "short name")
  if short_names > total {
    raise DbError::Corrupt("short name count exceeds the entry count")
  }
  let keys : Array[UInt32] = []
  let postings : Array[TrigramPosting] = []
  let mut previous_key = -1L
  for _ in 0..<key_count {
    let key = reader.read_u32()
    if key > DB_MAX_TRIGRAM_KEY {
      raise DbError::Corrupt("trigram key is out of range")
    }
    if key.to_int64() <= previous_key {
      raise DbError::Corrupt("trigram keys are not strictly ascending")
    }
    previous_key = key.to_int64()
    let length = checked_count(reader.read_u32(), "posting length")
    if length <= 0 || length > total {
      raise DbError::Corrupt("posting length is out of range")
    }
    if reader.remaining() < length {
      raise DbError::Truncated
    }
    let ids : Array[Int32] = []
    let mut previous = -1
    for position in 0..<length {
      let delta = reader.read_varint()
      let value = if position == 0 {
        delta.to_int64()
      } else {
        previous.to_int64() + delta.to_int64()
      }
      if value > 2147483647L {
        raise DbError::Corrupt("posting id is outside the Int32 range")
      }
      let id = value.to_int()
      if position > 0 && id <= previous {
        raise DbError::Corrupt("posting ids are not strictly ascending")
      }
      if id >= total {
        raise DbError::Corrupt("posting id is out of range")
      }
      ids.push(id)
      previous = id
    }
    keys.push(key)
    postings.push(TrigramPosting::from_sorted(ids))
  }
  reader.expect_end()
  Some(TrigramIndex::restore(total~, keys~, postings~, short_names~))
}
