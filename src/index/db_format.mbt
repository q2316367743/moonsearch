///|
/// File signature of the moonsearch database.
const DB_MAGIC : Bytes = b"MSDB"

///|
/// Major format version. A reader refuses any other major version because the
/// section payloads are not guaranteed to be interpretable.
const DB_VERSION_MAJOR : UInt16 = 3

///|
/// Minor format version. A reader accepts any minor version at or above zero
/// and skips section kinds it does not know, so a newer writer can add
/// sections without breaking older readers.
const DB_VERSION_MINOR : UInt16 = 0

///|
/// Fixed header size in bytes.
///
/// The field list in the migration plan reaches 72 bytes when every reserved
/// word is kept; the two optional reserved words are dropped here so the header
/// fits the documented 64-byte envelope:
///
/// ```text
/// magic 4 | version 4 | endian+reserved 4 | flags 4 | built_at 8
/// folder/file/root/exclude/dict/range/trigram counts 28
/// section_table_off 8 | section_count 4
/// ```
const DB_HEADER_SIZE : Int32 = 64

///|
/// Largest database the byte-buffer based reader accepts (2 GiB - 1 byte).
/// File paths are stat'ed against this limit before any whole-file allocation.
const DB_MAX_FILE_BYTES : Int64 = 2147483647L

///|
/// Size of one section table entry: kind `u32`, offset `u64`, length `u64`.
const DB_SECTION_ENTRY_SIZE : Int32 = 20

///|
/// Upper bound on the section count. The current writer emits nine sections;
/// the spare room allows future additions without a huge table allocation.
const DB_MAX_SECTIONS : Int32 = 32

///|
/// Header flag bit 0: the POSTINGS section is present.
const DB_FLAG_TRIGRAM : UInt32 = 0x1

///|
/// Byte value that encodes `NO_PARENT` in a folder or file record.
const DB_NO_PARENT : UInt32 = 0xFFFFFFFF

///|
/// Section kind of the root configuration records.
const SECTION_ROOTS : Int32 = 1

///|
/// Section kind reserved for exclude rules. S12 does not persist them: they are
/// configuration, not derived index state.
const SECTION_EXCLUDES : Int32 = 2

///|
/// Section kind of the front-coded name table.
const SECTION_NAMES : Int32 = 3

///|
/// Section kind of the folder records.
const SECTION_FOLDERS : Int32 = 4

///|
/// Section kind of the file records.
const SECTION_FILES : Int32 = 5

///|
/// Section kind of the canonical order.
const SECTION_ORDER : Int32 = 6

///|
/// Section kind of the field dictionary.
const SECTION_DICT : Int32 = 7

///|
/// Section kind of the range indexes.
const SECTION_RANGES : Int32 = 8

///|
/// Section kind of the trigram postings.
const SECTION_POSTINGS : Int32 = 9

///|
/// Section kind of the checksum trailer.
const SECTION_CHECKSUM : Int32 = 10

///|
/// Dictionary key kind: one extension bucket.
const DICT_EXTENSION : Int32 = 0

///|
/// Dictionary key kind: every entry.
const DICT_ALL : Int32 = 1

///|
/// Dictionary key kind: every file.
const DICT_FILES : Int32 = 2

///|
/// Dictionary key kind: every folder.
const DICT_FOLDERS : Int32 = 3

///|
/// Dictionary key kind: names that start with a dot.
const DICT_HIDDEN : Int32 = 4

///|
/// Dictionary key kind: names that do not start with a dot.
const DICT_VISIBLE : Int32 = 5

///|
/// Dictionary key kind: one built-in category, payload is the category index.
const DICT_CATEGORY : Int32 = 6

///|
/// Dictionary key kind: one configured root, payload is the root index.
const DICT_ROOT : Int32 = 7

///|
/// On-disk tag of `RangeField::Size`.
const RANGE_SIZE : Int32 = 1

///|
/// On-disk tag of `RangeField::MTime`.
const RANGE_MTIME : Int32 = 2

///|
/// On-disk tag of `RangeField::Depth`.
const RANGE_DEPTH : Int32 = 3

///|
/// On-disk tag of `RangeField::ChildCount`.
const RANGE_CHILD_COUNT : Int32 = 4

///|
/// On-disk tag of `RangeField::Parent`.
const RANGE_PARENT : Int32 = 5

///|
/// Largest trigram key: three bytes packed into 24 bits.
const DB_MAX_TRIGRAM_KEY : UInt32 = 0xFFFFFF

///|
/// Maximum number of trigram keys a file may declare. Every key needs at least
/// nine bytes of section data, so this also bounds the allocation a corrupt
/// header can request.
const DB_MAX_TRIGRAM_KEYS : Int32 = 16777216

///|
/// Maximum total name bytes a file may declare (1 GiB). Real indexes stay far
/// below this; the limit exists so a hostile file cannot ask for an arbitrary
/// allocation before its sections have been validated.
const DB_MAX_NAME_BYTES : Int64 = 1073741824L

///|
/// Maximum number of entries a database may declare.
///
/// The loader allocates a few temporary arrays proportional to `total` (order
/// and range validation); 16.7 million entries keeps those under a few hundred
/// megabytes while staying far above the 1M-entry target.
const DB_MAX_ENTRIES : Int32 = 16777216

///|
/// Maximum number of dictionary keys. Extensions are unbounded in principle, so
/// the cap is generous; it only prevents a corrupt count from driving a huge
/// allocation.
const DB_MAX_DICT_KEYS : Int32 = 1000000

///|
/// Size of one folder record.
const DB_FOLDER_RECORD_SIZE : Int32 = 34

///|
/// Size of one file record.
const DB_FILE_RECORD_SIZE : Int32 = 26

///|
/// Human-readable name of a section kind, used by `info`.
fn section_name(kind : Int32) -> String {
  match kind {
    SECTION_ROOTS => "roots"
    SECTION_EXCLUDES => "excludes"
    SECTION_NAMES => "names"
    SECTION_FOLDERS => "folders"
    SECTION_FILES => "files"
    SECTION_ORDER => "order"
    SECTION_DICT => "dict"
    SECTION_RANGES => "ranges"
    SECTION_POSTINGS => "postings"
    SECTION_CHECKSUM => "checksum"
    other => "unknown(\{other})"
  }
}

///|
/// One entry of the section table after bounds validation.
priv struct DbSection {
  kind : Int32
  offset : Int32
  length : Int32
}

///|
/// Parsed header and validated section table.
priv struct DbEnvelope {
  minor : Int32
  flags : UInt32
  built_at : Int64
  folder_count : Int32
  file_count : Int32
  root_count : Int32
  dict_count : Int32
  range_count : Int32
  trigram_count : Int32
  sections : Array[DbSection]
}

///|
/// Sequential, bounds-checked reader over one section or the whole file.
///
/// Every read validates the remaining length before touching a byte, so a
/// truncated or length-mangled file surfaces as a `DbError` instead of a panic.
priv struct DbReader {
  view : BytesView
  mut pos : Int32
}

///|
/// Create a reader positioned at the start of `view`.
fn DbReader::new(view : BytesView) -> DbReader {
  { view, pos: 0, }
}

///|
/// Bytes left before the end of the view.
fn DbReader::remaining(self : DbReader) -> Int32 {
  self.view.length() - self.pos
}

///|
/// Require `count` readable bytes.
fn DbReader::ensure(self : DbReader, count : Int32) -> Unit raise DbError {
  if count < 0 || count > self.view.length() - self.pos {
    raise DbError::Truncated
  }
}

///|
/// Read one byte.
fn DbReader::read_byte(self : DbReader) -> Byte raise DbError {
  self.ensure(1)
  let byte = self.view[self.pos]
  self.pos = self.pos + 1
  byte
}

///|
/// Read one little-endian 16-bit value.
fn DbReader::read_u16(self : DbReader) -> UInt16 raise DbError {
  self.ensure(2)
  let value = self.view[self.pos].to_uint() |
    (self.view[self.pos + 1].to_uint() << 8)
  self.pos = self.pos + 2
  value.to_uint16()
}

///|
/// Read one little-endian 32-bit value.
fn DbReader::read_u32(self : DbReader) -> UInt32 raise DbError {
  self.ensure(4)
  let value = self.view[self.pos].to_uint() |
    (self.view[self.pos + 1].to_uint() << 8) |
    (self.view[self.pos + 2].to_uint() << 16) |
    (self.view[self.pos + 3].to_uint() << 24)
  self.pos = self.pos + 4
  value
}

///|
/// Read one little-endian 64-bit value.
fn DbReader::read_u64(self : DbReader) -> UInt64 raise DbError {
  self.ensure(8)
  let mut value = 0UL
  for index in 0..<8 {
    value = value | (self.view[self.pos + index].to_uint64() << (index * 8))
  }
  self.pos = self.pos + 8
  value
}

///|
/// Read one little-endian signed 64-bit value.
fn DbReader::read_i64(self : DbReader) -> Int64 raise DbError {
  self.read_u64().reinterpret_as_int64()
}

///|
/// Read `count` bytes as a zero-copy view.
fn DbReader::read_bytes(
  self : DbReader,
  count : Int32,
) -> BytesView raise DbError {
  self.ensure(count)
  let view = self.view.exact_view(start=self.pos, end=self.pos + count)
  self.pos = self.pos + count
  view
}

///|
/// Read one unsigned LEB128 value that must fit in 32 bits.
fn DbReader::read_varint(self : DbReader) -> UInt32 raise DbError {
  let mut result = 0U
  let mut shift = 0
  while true {
    let byte = self.read_byte()
    let part = byte.to_uint() & 0x7FU
    if shift == 28 && part > 0x0FU {
      raise DbError::Corrupt("varint does not fit in 32 bits")
    }
    result = result | (part << shift)
    if (byte.to_uint() & 0x80U) == 0U {
      return result
    }
    shift = shift + 7
    if shift > 28 {
      raise DbError::Corrupt("varint is too long")
    }
  }
  abort("unreachable")
}

///|
/// Require the view to be fully consumed.
fn DbReader::expect_end(self : DbReader) -> Unit raise DbError {
  if self.pos != self.view.length() {
    raise DbError::Corrupt("trailing bytes at the end of a section")
  }
}

///|
/// Build the CRC-32 (IEEE) lookup table.
fn crc32_table() -> Array[UInt32] {
  let table : Array[UInt32] = []
  for index in 0..<256 {
    let mut value = index.reinterpret_as_uint()
    for _ in 0..<8 {
      if (value & 1U) != 0U {
        value = 0xEDB88320U ^ (value >> 1)
      } else {
        value = value >> 1
      }
    }
    table.push(value)
  }
  table
}

///|
/// Incremental CRC-32 (IEEE, reflected).
///
/// The writer snapshots the value after the header and section table to record
/// the metadata checksum, keeps feeding section payloads, and snapshots again
/// before the checksum trailer. Computing both checksums in one pass avoids
/// copying the finished byte buffer.
priv struct Crc32 {
  table : Array[UInt32]
  mut value : UInt32
}

///|
/// Start a fresh CRC-32 computation.
fn Crc32::new() -> Crc32 {
  { table: crc32_table(), value: 0xFFFFFFFFU, }
}

///|
/// Feed bytes into the running checksum.
fn Crc32::update(self : Crc32, view : BytesView) -> Unit {
  let mut crc = self.value
  for byte in view {
    let index = ((crc ^ byte.to_uint()) & 0xFFU).reinterpret_as_int()
    crc = (crc >> 8) ^ self.table[index]
  }
  self.value = crc
}

///|
/// Final checksum value.
fn Crc32::finish(self : Crc32) -> UInt32 {
  self.value ^ 0xFFFFFFFFU
}

///|
/// CRC-32 (IEEE, reflected) over a byte view.
///
/// The format only requires a deterministic integrity check; CRC-32 is used
/// instead of SHA-256 because it is enough to detect torn writes and accidental
/// corruption and costs a fraction of the time on a large index.
fn crc32(view : BytesView) -> UInt32 {
  let crc = Crc32::new()
  crc.update(view)
  crc.finish()
}

///|
/// Convert a persisted `u32` count into an array-friendly `Int32`.
fn checked_count(value : UInt32, what : String) -> Int32 raise DbError {
  if value > 0x7FFFFFFFU {
    raise DbError::Corrupt("\{what} count is out of range")
  }
  value.reinterpret_as_int()
}

///|
/// Reject impossible or resource-excessive header counts before any section is
/// decoded. Both the full loader and `info` pass through this check.
fn validate_header_counts(
  folder_count~ : Int32,
  file_count~ : Int32,
  root_count~ : Int32,
  dict_count~ : Int32,
  range_count~ : Int32,
  trigram_count~ : Int32,
) -> Unit raise DbError {
  if folder_count > 2147483647 - file_count {
    raise DbError::Corrupt("entry count is out of range")
  }
  let total = folder_count + file_count
  if total > DB_MAX_ENTRIES {
    raise DbError::Corrupt("entry count exceeds the size limit")
  }
  if root_count > folder_count {
    raise DbError::Corrupt("root count exceeds the folder count")
  }
  if dict_count > DB_MAX_DICT_KEYS {
    raise DbError::Corrupt("dictionary key count is out of range")
  }
  if range_count > 5 {
    raise DbError::Corrupt("range field count is out of range")
  }
  if trigram_count > DB_MAX_TRIGRAM_KEYS {
    raise DbError::Corrupt("trigram key count is out of range")
  }
}

///|
/// Find a section by kind, or `None` when the file does not contain it.
fn find_section(sections : Array[DbSection], kind : Int32) -> DbSection? {
  for section in sections {
    if section.kind == kind {
      return Some(section)
    }
  }
  None
}

///|
/// Return a required section or fail.
fn required_section(
  sections : Array[DbSection],
  kind : Int32,
) -> DbSection raise DbError {
  match find_section(sections, kind) {
    Some(section) => section
    None => raise DbError::Corrupt("missing \{section_name(kind)} section")
  }
}

///|
/// Open a bounds-checked reader over one section.
fn section_reader(bytes : BytesView, section : DbSection) -> DbReader {
  DbReader::new(
    bytes.exact_view(start=section.offset, end=section.offset + section.length),
  )
}

///|
/// Validate the header and section table, then return them.
///
/// `verify=false` checks the metadata CRC (header + section table), which is
/// what a normal load pays. `verify=true` additionally checks every byte before
/// the checksum trailer, including unknown sections and padding. CHECKSUM must
/// be the final section and must end exactly at EOF in both modes.
fn parse_envelope(
  bytes : BytesView,
  verify~ : Bool,
) -> DbEnvelope raise DbError {
  let file_len = bytes.length()
  if file_len < DB_HEADER_SIZE {
    raise DbError::Truncated
  }
  let header = DbReader::new(bytes.exact_view(start=0, end=DB_HEADER_SIZE))
  let magic = header.read_bytes(4)
  if !magic.equal(DB_MAGIC.exact_view()) {
    raise DbError::Corrupt("bad magic; not a moonsearch database")
  }
  let major = header.read_u16().to_int()
  let minor = header.read_u16().to_int()
  if major != DB_VERSION_MAJOR.to_int() {
    raise DbError::UnsupportedVersion(major~, minor~)
  }
  let endian = header.read_byte().to_int()
  if endian != 1 {
    raise DbError::Corrupt("unsupported byte order")
  }
  ignore(header.read_bytes(3))
  let flags = header.read_u32()
  let built_at = header.read_i64()
  let folder_count = checked_count(header.read_u32(), "folder")
  let file_count = checked_count(header.read_u32(), "file")
  let root_count = checked_count(header.read_u32(), "root")
  ignore(header.read_u32())
  let dict_count = checked_count(header.read_u32(), "dictionary")
  let range_count = checked_count(header.read_u32(), "range")
  let trigram_count = checked_count(header.read_u32(), "trigram")
  let table_offset = header.read_u64()
  let section_count = checked_count(header.read_u32(), "section")
  if table_offset != DB_HEADER_SIZE.to_uint64() {
    raise DbError::Corrupt("section table is not at the documented offset")
  }
  if section_count <= 0 || section_count > DB_MAX_SECTIONS {
    raise DbError::Corrupt("section count is out of range")
  }
  validate_header_counts(
    folder_count~,
    file_count~,
    root_count~,
    dict_count~,
    range_count~,
    trigram_count~,
  )
  let table_size = section_count * DB_SECTION_ENTRY_SIZE
  if DB_HEADER_SIZE + table_size > file_len {
    raise DbError::Truncated
  }
  let table_end = DB_HEADER_SIZE + table_size
  let table = DbReader::new(
    bytes.exact_view(start=DB_HEADER_SIZE, end=table_end),
  )
  let sections : Array[DbSection] = []
  let mut previous_end = table_end
  for index in 0..<section_count {
    let kind = checked_count(table.read_u32(), "section kind")
    let last = index == section_count - 1
    if kind == SECTION_CHECKSUM && !last {
      raise DbError::Corrupt("checksum section must be last")
    }
    if last && kind != SECTION_CHECKSUM {
      raise DbError::Corrupt("checksum section must be last")
    }
    let offset = table.read_u64()
    let length = table.read_u64()
    if offset.reinterpret_as_int64() < previous_end.to_int64() ||
      length.reinterpret_as_int64() < 0L {
      raise DbError::Corrupt("section table is not in ascending order")
    }
    let end = offset + length
    if end < offset || end > file_len.to_uint64() {
      raise DbError::Corrupt("section lies outside the file")
    }
    let section : DbSection = {
      kind,
      offset: offset.to_int(),
      length: length.to_int(),
    }
    for existing in sections {
      if existing.kind == kind {
        raise DbError::Corrupt("duplicate \{section_name(kind)} section")
      }
    }
    sections.push(section)
    previous_end = end.to_int()
  }
  if (flags & DB_FLAG_TRIGRAM) == 0U && trigram_count != 0 {
    raise DbError::Corrupt("trigram count is set without the trigram flag")
  }
  let checksum = required_section(sections, SECTION_CHECKSUM)
  if checksum.length != 8 {
    raise DbError::Corrupt("checksum section has the wrong size")
  }
  if checksum.offset + checksum.length != file_len {
    raise DbError::Corrupt("checksum section does not end at EOF")
  }
  let has_postings = find_section(sections, SECTION_POSTINGS) is Some(_)
  if has_postings != ((flags & DB_FLAG_TRIGRAM) != 0U) {
    raise DbError::Corrupt("trigram flag does not match the postings section")
  }
  let checksum_reader = section_reader(bytes, checksum)
  let recorded_meta = checksum_reader.read_u32()
  let recorded_full = checksum_reader.read_u32()
  let computed_meta = crc32(bytes.exact_view(start=0, end=table_end))
  if recorded_meta != computed_meta {
    raise DbError::Corrupt("metadata checksum mismatch")
  }
  if verify {
    let computed_full = crc32(bytes.exact_view(start=0, end=checksum.offset))
    if recorded_full != computed_full {
      raise DbError::Corrupt("file checksum mismatch")
    }
  }
  {
    minor,
    flags,
    built_at,
    folder_count,
    file_count,
    root_count,
    dict_count,
    range_count,
    trigram_count,
    sections,
  }
}
