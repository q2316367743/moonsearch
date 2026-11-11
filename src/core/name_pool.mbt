///|
/// Maximum number of bytes one name may occupy.
///
/// The wire format stores the length as a `UInt16`, and 65535 bytes is above
/// every common filesystem `NAME_MAX` (255).
pub const MAX_NAME_LEN : Int32 = 65535

///|
/// Location of one name inside a `NamePool`.
pub struct NameRef {
  offset : UInt32
  length : UInt16
}

///|
/// Build a name reference from an explicit offset and byte length.
///
/// The caller is responsible for the reference being in range; `NamePool`
/// validates it when the name is read back.
pub fn NameRef::new(offset : UInt32, length : UInt16) -> NameRef {
  { offset, length, }
}

///|
/// Length of the name in bytes.
pub fn NameRef::byte_len(self : NameRef) -> Int32 {
  self.length.to_int()
}

///|
/// Offset one past the last byte of the name.
pub fn NameRef::end_offset(self : NameRef) -> UInt32 {
  self.offset + self.length.to_uint()
}

///|
/// Errors raised while appending to a `NamePool`.
pub suberror NamePoolError {
  /// The name does not fit in the `UInt16` length field.
  NameTooLong(Int32)
  /// The pool has reached the 32-bit offset limit.
  PoolFull
}

///|
/// Growable byte arena for file names.
///
/// Names are appended as raw bytes, so arbitrary Unix names survive without
/// decoding, and an `Entry` refers to its name with a small `(offset, length)`
/// pair. Bytes are accumulated into fixed-size chunks instead of one allocation
/// per name: appending is amortized O(1), references stay valid while the pool
/// grows, and reading a name is a zero-copy `BytesView` into its chunk.
///
/// The pool is mutable while an index is built. A finished index can call
/// `to_bytes` once and keep the resulting `Bytes` as the immutable name table.
pub struct NamePool {
  priv chunks : Array[Bytes]
  priv chunk_starts : Array[UInt32]
  priv mut sealed_len : UInt64
  priv mut name_count : Int32
  priv chunk_size : Int32
  priv tail : @buffer.Buffer
}

///|
/// Default chunk size: 64 KiB, which also fits the longest permitted name.
const DEFAULT_CHUNK_SIZE : Int32 = 65536

///|
/// Create an empty pool with the default chunk size.
pub fn NamePool::new() -> NamePool {
  NamePool::with_chunk_size(DEFAULT_CHUNK_SIZE)
}

///|
/// Create an empty pool whose chunks target `chunk_size` bytes.
///
/// A value below 1 is clamped to 1. A single name longer than the chunk size
/// is still stored in one chunk, so references never span chunks.
pub fn NamePool::with_chunk_size(chunk_size : Int32) -> NamePool {
  let size = if chunk_size < 1 { 1 } else { chunk_size }
  {
    chunks: [],
    chunk_starts: [],
    sealed_len: 0UL,
    name_count: 0,
    chunk_size: size,
    tail: @buffer.Buffer(size_hint=size),
  }
}

///|
/// Append one name and return its reference.
///
/// Raises `NameTooLong` when the name exceeds `MAX_NAME_LEN`, and `PoolFull`
/// when the 32-bit offset space is exhausted.
pub fn NamePool::add(
  self : NamePool,
  name : BytesView,
) -> NameRef raise NamePoolError {
  let length = name.length()
  if length > MAX_NAME_LEN {
    raise NameTooLong(length)
  }
  if length > 0 && self.tail.length() + length > self.chunk_size {
    self.seal_tail()
  }
  let offset = self.sealed_len + self.tail.length().to_uint64()
  if offset + length.to_uint64() > 4294967295UL {
    raise PoolFull
  }
  self.tail.write_bytes(name)
  self.name_count = self.name_count + 1
  if self.tail.length() >= self.chunk_size {
    self.seal_tail()
  }
  { offset: offset.to_uint(), length: length.to_uint16(), }
}

///|
/// Read a name back as a zero-copy view.
///
/// Panics if the reference is out of range, which can only happen when an
/// invalid `NameRef` is constructed by hand; database readers validate
/// references before installing them into entries.
pub fn NamePool::view(self : NamePool, name_ref : NameRef) -> BytesView {
  let length = name_ref.length.to_int()
  if length == 0 {
    return b""[0:0]
  }
  self.seal_tail()
  let offset = name_ref.offset.to_uint64()
  let end = offset + length.to_uint64()
  if offset >= self.sealed_len || end > self.sealed_len {
    abort("NamePool: name reference is out of range")
  }
  let chunk_index = self.find_chunk(offset)
  let chunk_start = self.chunk_starts[chunk_index].to_uint64()
  let local_start = (offset - chunk_start).to_int()
  let chunk = self.chunks[chunk_index]
  chunk.exact_view(start=local_start, end=local_start + length)
}

///|
/// Compare two names with the natural path ordering from `@util.cmp_paths`.
pub fn NamePool::compare(
  self : NamePool,
  left : NameRef,
  right : NameRef,
) -> Int32 {
  @util.cmp_paths(self.view(left), self.view(right))
}

///|
/// Materialize the whole pool as one contiguous `Bytes`.
///
/// This is the bridge to persistence and to immutable in-memory stores. It
/// seals the active chunk and copies all chunks once; the common single-chunk
/// case returns the chunk without copying.
pub fn NamePool::to_bytes(self : NamePool) -> Bytes {
  self.seal_tail()
  if self.chunks.length() == 1 {
    return self.chunks[0]
  }
  let buffer = @buffer.Buffer(size_hint=self.sealed_len.to_int())
  for chunk in self.chunks {
    buffer.write_bytes(chunk.exact_view())
  }
  buffer.to_bytes()
}

///|
/// Number of names appended so far.
pub fn NamePool::count(self : NamePool) -> Int32 {
  self.name_count
}

///|
/// Total number of name bytes stored.
pub fn NamePool::byte_len(self : NamePool) -> Int32 {
  self.sealed_len.to_int() + self.tail.length()
}

///|
/// Number of sealed chunks. Useful for `--stats` and for tests that check the
/// pool amortizes allocation instead of allocating per name.
pub fn NamePool::chunk_count(self : NamePool) -> Int32 {
  self.chunks.length()
}

///|
/// Whether no names have been appended.
pub fn NamePool::is_empty(self : NamePool) -> Bool {
  self.name_count == 0
}

///|
/// Move the active chunk into `chunks`, making it visible to views.
fn NamePool::seal_tail(self : NamePool) -> Unit {
  let length = self.tail.length()
  if length > 0 {
    self.chunks.push(self.tail.to_bytes())
    self.chunk_starts.push(self.sealed_len.to_uint())
    self.sealed_len = self.sealed_len + length.to_uint64()
    self.tail.reset()
  }
}

///|
/// Index of the chunk containing `offset`.
///
/// The caller guarantees at least one chunk exists and `offset` is inside the
/// sealed region.
fn NamePool::find_chunk(self : NamePool, offset : UInt64) -> Int32 {
  let mut low = 0
  let mut high = self.chunk_starts.length() - 1
  while low < high {
    let mid = (low + high + 1) / 2
    if self.chunk_starts[mid].to_uint64() <= offset {
      low = mid
    } else {
      high = mid - 1
    }
  }
  low
}
