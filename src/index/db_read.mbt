///|
/// Decode a whole index from the MSDB v3 byte layout.
///
/// The loader validates the header, the section table, both checksums (the
/// metadata one always, the full one when `verify` is set), and every reference
/// before installing it: name indexes, parent ids, order ids, dictionary ids,
/// range ids, and posting ids all have to stay inside the store-wide id space.
/// Ids and posting decoding share a bounded, caller-overridable resource budget.
/// Any violation becomes a `DbError`; nothing panics.
pub fn Index::from_bytes(
  bytes : BytesView,
  verify~ : Bool = false,
  budget~ : @ids.IdsDecodeBudget? = None,
  eager~ : RangeFieldSet = RangeFieldSet::all(),
) -> Index raise DbError {
  decode_index(bytes, verify~, budget~, eager~).0
}

///|
/// Decode once and retain the validated envelope for `DbInfo::from_bytes`.
/// Sharing this path lets `info --verify` perform deep semantic validation
/// without checking the full-file CRC or parsing the section table twice.
fn decode_index(
  bytes : BytesView,
  verify~ : Bool,
  budget~ : @ids.IdsDecodeBudget?,
  eager~ : RangeFieldSet,
) -> (Index, DbEnvelope) raise DbError {
  let envelope = parse_envelope(bytes, verify~)
  let total = envelope.folder_count + envelope.file_count
  let decode_budget = match budget {
    Some(value) => value
    None => @ids.IdsDecodeBudget::new()
  }
  let roots = parse_roots(bytes, envelope)
  let excludes = parse_excludes(bytes, envelope)
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
  let dict = parse_dict(bytes, envelope, total, decode_budget)
  let load_eager = if verify { RangeFieldSet::all() } else { eager }
  let ranges = parse_ranges(bytes, envelope, store, total, load_eager)
  let trigram = parse_postings(bytes, envelope, total, decode_budget)
  let index = Index::restore(store~, dict~, ranges~, trigram~, excludes~)
  if verify {
    validate_semantics(index)
  }
  (index, envelope)
}

///|
/// Read header-level information. The default stays lightweight; `verify=true`
/// fully decodes the index and recomputes every derived structure before the
/// command is allowed to report the database as verified.
pub fn DbInfo::from_bytes(
  bytes : BytesView,
  verify~ : Bool = false,
) -> DbInfo raise DbError {
  let envelope = if verify {
    decode_index(bytes, verify=true, budget=None, eager=RangeFieldSet::all()).1
  } else {
    parse_envelope(bytes, verify=false)
  }
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
  if envelope.minor >= DB_VERSION_MINOR.to_int() {
    ignore(required_section(envelope.sections, SECTION_PARENT_PATHS))
  }
  match find_section(envelope.sections, SECTION_EXCLUDES) {
    Some(section) => {
      if section.length < 4 {
        raise DbError::Truncated
      }
      let reader = section_reader(bytes, section)
      let count = checked_count(reader.read_u32(), "exclude")
      if count != envelope.exclude_count {
        raise DbError::Corrupt("exclude rule count does not match the header")
      }
    }
    None =>
      if envelope.exclude_count != 0 {
        raise DbError::Corrupt(
          "exclude count is set without an excludes section",
        )
      }
  }
  let names_section = required_section(envelope.sections, SECTION_NAMES)
  if names_section.length < 4 {
    raise DbError::Truncated
  }
  let names_reader = section_reader(bytes, names_section)
  let name_count = checked_count(names_reader.read_u32(), "name")
  if name_count > envelope.folder_count + envelope.file_count {
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
  if count.to_int64() * 29L > reader.remaining().to_int64() {
    raise DbError::Truncated
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
/// Parse the persisted exclude rules, accepting the empty implicit rule set of
/// legacy v3.0 files that predate this section.
fn parse_excludes(
  bytes : BytesView,
  envelope : DbEnvelope,
) -> Array[ExcludeRule] raise DbError {
  match find_section(envelope.sections, SECTION_EXCLUDES) {
    None =>
      if envelope.exclude_count != 0 {
        raise DbError::Corrupt(
          "exclude count is set without an excludes section",
        )
      } else {
        []
      }
    Some(section) => {
      let reader = section_reader(bytes, section)
      let count = checked_count(reader.read_u32(), "exclude")
      if count != envelope.exclude_count {
        raise DbError::Corrupt("exclude rule count does not match the header")
      }
      if count > DB_MAX_EXCLUDES {
        raise DbError::Corrupt("exclude rule count is out of range")
      }
      if count.to_int64() * 8L > reader.remaining().to_int64() {
        raise DbError::Truncated
      }
      let rules : Array[ExcludeRule] = []
      for _ in 0..<count {
        let kind = match reader.read_byte().to_int() {
          EXCLUDE_FIXED => Fixed
          EXCLUDE_GLOB => Glob
          EXCLUDE_REGEX => Regex
          other => raise DbError::Corrupt("unknown exclude kind \{other}")
        }
        let scope = match reader.read_byte().to_int() {
          EXCLUDE_FULL_PATH => FullPath
          EXCLUDE_BASENAME => Basename
          other => raise DbError::Corrupt("unknown exclude scope \{other}")
        }
        let target = match reader.read_byte().to_int() {
          EXCLUDE_BOTH => Both
          EXCLUDE_FILES => Files
          EXCLUDE_FOLDERS => Folders
          other => raise DbError::Corrupt("unknown exclude target \{other}")
        }
        let active = match reader.read_byte() {
          b'\x00' => false
          b'\x01' => true
          _ => raise DbError::Corrupt("exclude active flag is out of range")
        }
        let pattern_length = checked_count(
          reader.read_u32(),
          "exclude pattern length",
        )
        if pattern_length > DB_MAX_EXCLUDE_PATTERN_BYTES {
          raise DbError::Corrupt("exclude pattern is too long")
        }
        let pattern_bytes = reader.read_bytes(pattern_length)
        let pattern = @utf8.decode(pattern_bytes) catch {
          _ => raise DbError::Corrupt("exclude pattern is not valid UTF-8")
        }
        let rule = ExcludeRule::new(kind~, pattern~, scope~, target~, active~) catch {
          err =>
            raise DbError::Corrupt("invalid exclude rule: \{err.message()}")
        }
        rules.push(rule)
      }
      reader.expect_end()
      rules
    }
  }
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
  if count.to_int64() * 4L > reader.remaining().to_int64() {
    raise DbError::Truncated
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
    buffer.write_bytesview(previous.exact_view(start=0, end=prefix))
    buffer.write_bytesview(suffix_bytes)
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
/// Validate an id set against the store-wide id space without expanding a
/// bitmap into a sorted array. Cardinality and the maximum occupied block are
/// checked first; the maximum id then rejects sparse out-of-range tails.
fn validate_ids(ids : @ids.Ids, total : Int32) -> Unit raise DbError {
  if ids.cardinality() > total {
    raise DbError::Corrupt("dictionary id set exceeds the entry count")
  }
  let max_block = if total > 0 {
    (total - 1) >> @ids.BITMAP_BLOCK_SHIFT
  } else {
    -1
  }
  if ids.max_block() > max_block {
    raise DbError::Corrupt("dictionary id block is out of range")
  }
  if ids.max_id() >= total {
    raise DbError::Corrupt("dictionary id is out of range")
  }
}

///|
/// Charge a shared decoder budget and translate exhaustion into `DbError`.
fn charge_decode_budget(
  budget : @ids.IdsDecodeBudget,
  operations~ : Int64,
  memory_bytes~ : Int64,
) -> Unit raise DbError {
  budget.charge(operations~, memory_bytes~) catch {
    @ids.IdsError::LimitExceeded(message) => raise DbError::TooLarge(message)
    err => raise DbError::Corrupt(err.message())
  }
}

///|
/// Parse the field dictionary.
fn parse_dict(
  bytes : BytesView,
  envelope : DbEnvelope,
  total : Int32,
  budget : @ids.IdsDecodeBudget,
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
  if key_count.to_int64() * 12L > reader.remaining().to_int64() {
    raise DbError::Truncated
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
    let ids = @ids.Ids::from_bytes_with_budget(
      ids_bytes,
      budget,
      total=Some(total),
    ) catch {
      @ids.IdsError::LimitExceeded(message) => raise DbError::TooLarge(message)
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
    RANGE_CHILD_FILE_COUNT => Some(ChildFileCount)
    RANGE_CHILD_FOLDER_COUNT => Some(ChildFolderCount)
    _ => None
  }
}

///|
/// Parse every persisted range field. Selected fields are materialized now;
/// unselected fields are structurally validated and retained as owned byte
/// slices for lazy decoding. No range accessor rebuilds from the Store.
fn parse_ranges(
  bytes : BytesView,
  envelope : DbEnvelope,
  store : @core.Store,
  total : Int32,
  eager : RangeFieldSet,
) -> Ranges raise DbError {
  let section = required_section(envelope.sections, SECTION_RANGES)
  let reader = section_reader(bytes, section)
  let field_count = checked_count(reader.read_u32(), "range field")
  if field_count != envelope.range_count {
    raise DbError::Corrupt("range field count does not match the header")
  }
  if field_count > DB_MAX_RANGE_FIELDS {
    raise DbError::Corrupt("range field count is out of range")
  }
  if field_count.to_int64() * 5L > reader.remaining().to_int64() {
    raise DbError::Truncated
  }
  let mut size_index : RangeIndex? = None
  let mut mtime_index : RangeIndex? = None
  let mut depth_index : RangeIndex? = None
  let mut child_count_index : RangeIndex? = None
  let mut parent_index : RangeIndex? = None
  let mut child_file_count_index : RangeIndex? = None
  let mut child_folder_count_index : RangeIndex? = None
  let persisted_ranges : Array[Bytes?] = Array::makei(DB_MAX_RANGE_FIELDS, fn(
    _,
  ) {
    None
  })
  let seen_fields : Array[Bool] = Array::makei(DB_MAX_RANGE_FIELDS, fn(_) {
    false
  })
  let mut decoded_fields = 0
  for _ in 0..<field_count {
    let payload_start = section.offset + reader.pos
    let tag = reader.read_byte().to_int()
    let field = match range_field_of_tag(tag) {
      Some(field) => field
      None => raise DbError::Corrupt("unknown range field tag \{tag}")
    }
    let field_position = range_field_position(field)
    if seen_fields[field_position] {
      raise DbError::Corrupt("duplicate range field")
    }
    seen_fields[field_position] = true
    let length = checked_count(reader.read_u32(), "range length")
    if length > total {
      raise DbError::Corrupt("range length exceeds the entry count")
    }
    let data_length = length * 12
    if reader.remaining() < data_length {
      raise DbError::Truncated
    }
    ignore(reader.read_bytes(data_length))
    let payload_end = payload_start + 5 + data_length
    let payload = bytes.exact_view(start=payload_start, end=payload_end)
    let materialize = eager.contains(field)
    let index = parse_range_payload(payload, field, total, materialize)
    match index {
      Some(index) => {
        decoded_fields = decoded_fields + 1
        match field {
          Size => size_index = Some(index)
          MTime => mtime_index = Some(index)
          Depth => depth_index = Some(index)
          ChildCount => child_count_index = Some(index)
          Parent => parent_index = Some(index)
          ChildFileCount => child_file_count_index = Some(index)
          ChildFolderCount => child_folder_count_index = Some(index)
        }
      }
      None => persisted_ranges[field_position] = Some(payload.to_owned())
    }
  }
  reader.expect_end()
  if envelope.minor >= DB_VERSION_MINOR.to_int() {
    for field in RangeField::core() {
      if !seen_fields[range_field_position(field)] {
        raise DbError::Corrupt("database is missing a core range field")
      }
    }
  }
  let parent_paths = match parse_parent_paths(bytes, envelope) {
    Some(paths) => paths
    None => build_parent_paths(store)
  }
  Ranges::restore_persisted(
    store,
    eager~,
    size_index~,
    mtime_index~,
    depth_index~,
    child_count_index~,
    parent_index~,
    child_file_count_index~,
    child_folder_count_index~,
    parent_paths~,
    persisted_ranges~,
    decoded_fields~,
  )
}

///|
/// Validate one range payload and optionally materialize its arrays. Validation
/// is always performed so a later lazy decode cannot surface structural corruption.
fn parse_range_payload(
  payload : BytesView,
  field : RangeField,
  total : Int32,
  materialize : Bool,
) -> RangeIndex? raise DbError {
  let reader = DbReader::new(payload)
  let tag = reader.read_byte().to_int()
  if tag != range_field_tag(field) {
    raise DbError::Corrupt("range field tag does not match its payload")
  }
  let length = checked_count(reader.read_u32(), "range length")
  if length > total {
    raise DbError::Corrupt("range length exceeds the entry count")
  }
  let data_length = length * 12
  if reader.remaining().to_int64() < data_length.to_int64() {
    raise DbError::Truncated
  }
  ignore(reader.read_bytes(data_length))
  reader.expect_end()
  let values_end = 5 + length * 8
  let values_reader = DbReader::new(payload.exact_view(start=5, end=values_end))
  let ids_reader = DbReader::new(
    payload.exact_view(start=values_end, end=5 + data_length),
  )
  let values : Array[Int64] = []
  let ids : Array[Int32] = []
  let seen : Array[Bool] = Array::makei(total, fn(_) { false })
  let mut previous_value = 0L
  let mut previous_id = -1
  let mut has_previous = false
  for _ in 0..<length {
    let value = values_reader.read_i64()
    let id = checked_count(ids_reader.read_u32(), "range id")
    if id < 0 || id >= total {
      raise DbError::Corrupt(
        "\{field.name()} range id \{id} is out of range for \{total} entries",
      )
    }
    if seen[id] {
      raise DbError::Corrupt(
        "\{field.name()} range contains a duplicate id \{id}",
      )
    }
    seen[id] = true
    if has_previous &&
      (value < previous_value || (value == previous_value && id <= previous_id)) {
      raise DbError::Corrupt("range is not sorted by value and id")
    }
    if materialize {
      values.push(value)
      ids.push(id)
    }
    previous_value = value
    previous_id = id
    has_previous = true
  }
  if materialize {
    Some(RangeIndex::restore(values~, ids~, total~))
  } else {
    None
  }
}

///|
/// Parse the persisted folder-path-to-id table. Legacy v3.0/v3.1 files omit it
/// and derive the table once during load; v3.2 always requires this section.
fn parse_parent_paths(
  bytes : BytesView,
  envelope : DbEnvelope,
) -> ParentPaths? raise DbError {
  match find_section(envelope.sections, SECTION_PARENT_PATHS) {
    None => None
    Some(section) => {
      let reader = section_reader(bytes, section)
      let count = checked_count(reader.read_u32(), "parent path")
      if count != envelope.folder_count {
        raise DbError::Corrupt(
          "parent path count does not match the folder count",
        )
      }
      if count.to_int64() * 8L > reader.remaining().to_int64() {
        raise DbError::Truncated
      }
      let paths : Array[Bytes] = []
      let ids : Array[Int32] = []
      let seen : Array[Bool] = Array::makei(count, fn(_) { false })
      let mut previous_path = b""[:]
      let mut previous_id = -1
      let mut has_previous = false
      let mut total_bytes = 0L
      for _ in 0..<count {
        let path_length = checked_count(reader.read_u32(), "parent path length")
        if path_length == 0 || path_length > @core.MAX_NAME_LEN {
          raise DbError::Corrupt("parent path length is out of range")
        }
        let path_bytes = reader.read_bytes(path_length)
        if @util.find_byte(path_bytes, b'\x00') is Some(_) {
          raise DbError::Corrupt("parent path contains NUL")
        }
        let id = checked_count(reader.read_u32(), "parent folder id")
        if id >= count {
          raise DbError::Corrupt("parent folder id is out of range")
        }
        if seen[id] {
          raise DbError::Corrupt("parent paths contain a duplicate folder id")
        }
        seen[id] = true
        if has_previous {
          let order = previous_path.lexical_compare(path_bytes)
          if order > 0 || (order == 0 && previous_id >= id) {
            raise DbError::Corrupt("parent paths are not sorted by path and id")
          }
        }
        let path = path_bytes.to_owned()
        total_bytes = total_bytes + path.length().to_int64()
        if total_bytes > DB_MAX_NAME_BYTES {
          raise DbError::Corrupt("parent paths exceed the size limit")
        }
        paths.push(path)
        ids.push(id)
        previous_path = paths[paths.length() - 1][:]
        previous_id = id
        has_previous = true
      }
      reader.expect_end()
      Some(ParentPaths::restore(paths~, ids~))
    }
  }
}

///|
/// Parse the trigram postings, or return `None` when the index was written
/// without them.
fn parse_postings(
  bytes : BytesView,
  envelope : DbEnvelope,
  total : Int32,
  budget : @ids.IdsDecodeBudget,
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
  if key_count.to_int64() * 9L > reader.remaining().to_int64() {
    raise DbError::Truncated
  }
  let short_names = checked_count(reader.read_u32(), "short name")
  if short_names > total {
    raise DbError::Corrupt("short name count exceeds the entry count")
  }
  charge_decode_budget(
    budget,
    operations=key_count.to_int64(),
    memory_bytes=key_count.to_int64() * 40L,
  )
  let keys : Array[UInt32] = []
  let postings : Array[TrigramPosting] = []
  let mut previous_key = -1L
  let mut posting_count = 0L
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
    posting_count = posting_count + length.to_int64()
    if posting_count > 2147483647L {
      raise DbError::Corrupt("posting count exceeds the Int32 range")
    }
    charge_decode_budget(
      budget,
      operations=length.to_int64() * 2L,
      memory_bytes=length.to_int64() * 4L,
    )
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

///|
/// Recompute every derived structure from the restored store and compare it
/// with the persisted values.
///
/// This is deliberately behind `verify=true`: normal loading pays only the
/// structural checks needed to keep every accessor in bounds, while full
/// verification proves that the candidate sources still mean the same thing as
/// the entries they came from.
fn validate_semantics(index : Index) -> Unit raise DbError {
  let store = index.store()
  for root in store.roots() {
    if !@util.eq_bytes(store.folder_path(root.folder), root.path, false) {
      raise DbError::Corrupt("root path does not match its folder entry")
    }
  }
  for id in 0..<store.folder_count() {
    let entry = store.folder(id).unwrap()
    validate_hidden_flag(
      store.entry_name(@core.EntryRef::new(@core.Folder, id)),
      entry,
    )
  }
  for id in 0..<store.file_count() {
    let entry = store.file(id).unwrap()
    validate_hidden_flag(
      store.entry_name(@core.EntryRef::new(@core.File, id)),
      entry,
    )
  }
  validate_dictionary_semantics(index.dict(), Dict::build(store))
  let mut eager = RangeFieldSet::empty()
  for field in RangeField::all() {
    if index.ranges().is_loaded(field) {
      eager = eager.union(RangeFieldSet::single(field))
    }
  }
  validate_range_semantics(index.ranges(), Ranges::build(store, eager~))
  validate_parent_path_semantics(index.ranges(), build_parent_paths(store))
  match index.trigram() {
    Some(actual) =>
      validate_trigram_semantics(actual, TrigramIndex::build(store))
    None => ()
  }
}

///|
/// The scanner derives the hidden flag from the raw basename. A database that
/// changes both the flag and the DICT buckets must still fail full verification.
fn validate_hidden_flag(
  name : BytesView,
  entry : @core.Entry,
) -> Unit raise DbError {
  let expected = !name.is_empty() && name[0] == b'.'
  if entry.is_hidden() != expected {
    raise DbError::Corrupt("entry hidden flag does not match its name")
  }
}

///|
/// Compare two id sets without relying on their physical container shape.
fn validate_id_set(
  actual : @ids.Ids,
  expected : @ids.Ids,
  label : String,
) -> Unit raise DbError {
  if actual.cardinality() != expected.cardinality() {
    raise DbError::Corrupt("\{label} cardinality does not match the store")
  }
  for id in expected.to_sorted_ids() {
    if !actual.contains(id) {
      raise DbError::Corrupt("\{label} does not match the store")
    }
  }
}

///|
/// Validate all dictionary buckets against entry kinds, flags, names, and parent
/// chains. Structural loading checks only id bounds and basic set algebra; this
/// pass catches a self-consistent but semantically wrong bucket.
fn validate_dictionary_semantics(
  actual : Dict,
  expected : Dict,
) -> Unit raise DbError {
  validate_id_set(actual.all(), expected.all(), "dictionary all set")
  validate_id_set(
    actual.files_all(),
    expected.files_all(),
    "dictionary files set",
  )
  validate_id_set(
    actual.folders_all(),
    expected.folders_all(),
    "dictionary folders set",
  )
  validate_id_set(actual.hidden(), expected.hidden(), "dictionary hidden set")
  validate_id_set(
    actual.visible(),
    expected.visible(),
    "dictionary visible set",
  )
  if actual.extension_count() != expected.extension_count() {
    raise DbError::Corrupt(
      "dictionary extension coverage does not match the store",
    )
  }
  for position in 0..<expected.extension_count() {
    let actual_entry = actual.extensions()[position]
    let expected_entry = expected.extensions()[position]
    if !@util.eq_bytes(
        actual_entry.extension(),
        expected_entry.extension(),
        false,
      ) {
      raise DbError::Corrupt(
        "dictionary extension key does not match the store",
      )
    }
    validate_id_set(
      actual_entry.ids(),
      expected_entry.ids(),
      "dictionary extension set",
    )
  }
  if actual.type_category_count() != expected.type_category_count() {
    raise DbError::Corrupt(
      "dictionary category coverage does not match the store",
    )
  }
  for category in @util.TypeCategory::all() {
    validate_id_set(
      actual.type_category(category),
      expected.type_category(category),
      "dictionary \{category.name()} category",
    )
  }
  if actual.root_count() != expected.root_count() {
    raise DbError::Corrupt("dictionary root coverage does not match the store")
  }
  for position in 0..<expected.root_count() {
    validate_id_set(
      actual.root(position).unwrap(),
      expected.root(position).unwrap(),
      "dictionary root set",
    )
  }
}

///|
/// Validate the persisted path translation table against every folder path.
fn validate_parent_path_semantics(
  actual : Ranges,
  expected : ParentPaths,
) -> Unit raise DbError {
  let paths = actual.parent_paths()
  if paths.paths.length() != expected.paths.length() {
    raise DbError::Corrupt("parent path coverage does not match the store")
  }
  for position in 0..<expected.paths.length() {
    if paths.ids[position] != expected.ids[position] ||
      !@util.eq_bytes(
        paths.paths[position][:],
        expected.paths[position][:],
        false,
      ) {
      raise DbError::Corrupt("parent paths do not match the store")
    }
  }
}

///|
/// Validate each persisted range field against a fresh build from the Store.
/// Full verification materializes every persisted field; a present field must
/// cover exactly the same `(value, id)` pairs as its source entries.
fn validate_range_semantics(
  actual : Ranges,
  expected : Ranges,
) -> Unit raise DbError {
  for field in RangeField::all() {
    if !actual.is_loaded(field) {
      continue
    }
    let actual_index = actual.field(field)
    let expected_index = expected.field(field)
    if actual_index.len() != expected_index.len() {
      raise DbError::Corrupt(
        "\{field.name()} range coverage does not match the store",
      )
    }
    for position in 0..<expected_index.len() {
      if actual_index.value_at(position) != expected_index.value_at(position) ||
        actual_index.id_at(position) != expected_index.id_at(position) {
        raise DbError::Corrupt(
          "\{field.name()} range values do not match the store",
        )
      }
    }
  }
}

///|
/// Validate every trigram key and posting against the names in the Store.
/// Comparing with a fresh index proves both directions: no posting contains an
/// id whose name lacks the trigram, and no real occurrence is missing.
fn validate_trigram_semantics(
  actual : TrigramIndex,
  expected : TrigramIndex,
) -> Unit raise DbError {
  if actual.entry_count() != expected.entry_count() ||
    actual.key_count() != expected.key_count() ||
    actual.posting_count() != expected.posting_count() ||
    actual.short_name_count() != expected.short_name_count() {
    raise DbError::Corrupt("trigram coverage does not match the store")
  }
  for position in 0..<expected.key_count() {
    if actual.key_at(position) != expected.key_at(position) {
      raise DbError::Corrupt("trigram keys do not match the store")
    }
    let actual_ids = actual.posting_at(position).unwrap().ids()
    let expected_ids = expected.posting_at(position).unwrap().ids()
    if actual_ids.length() != expected_ids.length() {
      raise DbError::Corrupt("trigram postings do not match entry names")
    }
    for offset in 0..<expected_ids.length() {
      if actual_ids[offset] != expected_ids[offset] {
        raise DbError::Corrupt("trigram postings do not match entry names")
      }
    }
  }
}
