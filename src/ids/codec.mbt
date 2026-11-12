///|
/// Representation tag of a bitmap id set.
const REPR_BITMAP : Int32 = 0

///|
/// Representation tag of a sorted id set.
const REPR_SORTED : Int32 = 1

///|
/// Container tag of an array container.
const CONTAINER_ARRAY : Int32 = 0

///|
/// Container tag of a bits container.
const CONTAINER_BITS : Int32 = 1

///|
/// Errors raised while decoding an id set.
///
/// Decoding is total: malformed input yields an error instead of panicking, so
/// a corrupted database can be rejected at the section boundary.
pub suberror IdsError {
  /// The input ended before the declared structure was complete.
  Truncated
  /// The input is well-sized but violates the format.
  Corrupt(String)
}

///|
/// Human-readable text of a decode error.
pub fn IdsError::message(self : IdsError) -> String {
  match self {
    Truncated => "id set data is truncated"
    Corrupt(message) => "corrupt id set: \{message}"
  }
}

///|
/// Serialize an id set.
///
/// The layout is the `IdsRef` format from the migration plan's database
/// appendix:
///
/// ```text
/// repr   u8      0 = bitmap, 1 = sorted
/// len    u32     cardinality
/// bitmap: block_count u32, then per non-empty block
///         block_idx u32, type u8 (0=array/1=bits), len u32, payload
/// sorted: len delta-varint ids, ascending
/// ```
///
/// All integers are little-endian; sorted ids use unsigned LEB128 deltas with
/// the first id stored as its absolute value. The output is deterministic for
/// a given set, which makes round-trip tests and golden files meaningful.
pub fn Ids::to_bytes(self : Ids) -> Bytes {
  let buffer = @buffer.Buffer()
  match self {
    Bitmap(bitmap) => {
      buffer.write_byte(REPR_BITMAP.to_byte())
      buffer.write_uint_le(bitmap.cardinality().reinterpret_as_uint())
      let blocks = bitmap.containers
      let mut block_count = 0
      for block in 0..<blocks.length() {
        if blocks[block] is Some(_) {
          block_count = block_count + 1
        }
      }
      buffer.write_uint_le(block_count.reinterpret_as_uint())
      for block in 0..<blocks.length() {
        match blocks[block] {
          None => ()
          Some(Container::Array(values)) => {
            buffer.write_uint_le(block.reinterpret_as_uint())
            buffer.write_byte(CONTAINER_ARRAY.to_byte())
            buffer.write_uint_le(values.length().reinterpret_as_uint())
            for value in values {
              buffer.write_uint16_le(value)
            }
          }
          Some(Container::Bits(words)) => {
            buffer.write_uint_le(block.reinterpret_as_uint())
            buffer.write_byte(CONTAINER_BITS.to_byte())
            buffer.write_uint_le(BITMAP_WORDS.reinterpret_as_uint())
            for word in words {
              buffer.write_uint64_le(word)
            }
          }
        }
      }
    }
    Sorted(ids) => {
      buffer.write_byte(REPR_SORTED.to_byte())
      buffer.write_uint_le(ids.length().reinterpret_as_uint())
      let mut previous = 0
      for index in 0..<ids.length() {
        let id = ids[index]
        let delta = if index == 0 { id } else { id - previous }
        write_varint(buffer, delta.reinterpret_as_uint())
        previous = id
      }
    }
  }
  buffer.to_bytes()
}

///|
/// Deserialize an id set produced by `Ids::to_bytes`.
///
/// The decoder validates the representation tag, block order, container
/// contents, and the declared cardinality, and rejects trailing bytes. Input
/// that would decode to a set beyond the sorted threshold is normalized to a
/// bitmap, so the result is always a canonical `Ids`.
pub fn Ids::from_bytes(bytes : BytesView) -> Ids raise IdsError {
  let reader = Reader::new(bytes)
  let repr = reader.read_byte()
  match repr.to_int() {
    REPR_BITMAP => Bitmap(decode_bitmap(reader))
    REPR_SORTED => decode_sorted(reader)
    other => raise IdsError::Corrupt("unknown representation tag \{other}")
  }
}

///|
/// Read one bitmap id set.
fn decode_bitmap(reader : Reader) -> Bitmap raise IdsError {
  let declared = reader.read_uint()
  let block_count = reader.read_uint()
  if block_count.to_int64() > 32768L {
    raise IdsError::Corrupt("too many blocks")
  }
  let containers : Array[Container?] = []
  let mut previous_block = -1
  let mut computed = 0
  for _ in 0..<block_count.reinterpret_as_int() {
    let block_index = reader.read_uint()
    if block_index.to_int64() > BITMAP_MAX_BLOCK.to_int64() {
      raise IdsError::Corrupt("block index is out of range")
    }
    let block = block_index.reinterpret_as_int()
    if block <= previous_block {
      raise IdsError::Corrupt("block indexes are not ascending")
    }
    while containers.length() <= block {
      containers.push(None)
    }
    match decode_container(reader) {
      Some(container) => {
        computed = computed + container_cardinality(container)
        containers[block] = Some(container)
      }
      None => raise IdsError::Corrupt("empty block")
    }
    previous_block = block
  }
  if computed.to_int64() != declared.to_int64() {
    raise IdsError::Corrupt("cardinality does not match the containers")
  }
  if reader.remaining() != 0 {
    raise IdsError::Corrupt("trailing bytes after the bitmap")
  }
  { containers, len: computed, }
}

///|
/// Read one block container.
fn decode_container(reader : Reader) -> Container? raise IdsError {
  let kind = reader.read_byte()
  let length = reader.read_uint()
  match kind.to_int() {
    CONTAINER_ARRAY => {
      if length.to_int64() > BITMAP_BLOCK_SIZE.to_int64() {
        raise IdsError::Corrupt("array container is larger than a block")
      }
      if length == 0U {
        raise IdsError::Corrupt("empty array container")
      }
      let values : Array[UInt16] = []
      let mut previous = -1
      for _ in 0..<length.reinterpret_as_int() {
        let value = reader.read_uint16()
        if value.to_int() <= previous {
          raise IdsError::Corrupt("array container is not ascending")
        }
        values.push(value)
        previous = value.to_int()
      }
      normalize_array_container(values)
    }
    CONTAINER_BITS => {
      if length.to_int64() != BITMAP_WORDS.to_int64() {
        raise IdsError::Corrupt("bits container has the wrong word count")
      }
      let words : Array[UInt64] = []
      for _ in 0..<BITMAP_WORDS {
        words.push(reader.read_uint64())
      }
      normalize_bits_container(words)
    }
    other => raise IdsError::Corrupt("unknown container tag \{other}")
  }
}

///|
/// Read one sorted id set.
fn decode_sorted(reader : Reader) -> Ids raise IdsError {
  let declared = reader.read_uint()
  if declared.to_int64() > reader.remaining().to_int64() {
    raise IdsError::Truncated
  }
  let ids : Array[Int32] = []
  let mut previous = -1L
  for index in 0..<declared.reinterpret_as_int() {
    let delta = reader.read_varint()
    if index > 0 && delta == 0U {
      raise IdsError::Corrupt("sorted ids are not strictly ascending")
    }
    let value = if index == 0 {
      delta.to_int64()
    } else {
      previous + delta.to_int64()
    }
    if value > 2147483647L {
      raise IdsError::Corrupt("id is outside the Int32 range")
    }
    ids.push(value.to_int())
    previous = value
  }
  if reader.remaining() != 0 {
    raise IdsError::Corrupt("trailing bytes after the sorted set")
  }
  canonical_sorted(ids, 0)
}

///|
/// Write an unsigned LEB128 value.
fn write_varint(buffer : @buffer.Buffer, value : UInt32) -> Unit {
  let mut rest = value
  while rest >= 0x80U {
    buffer.write_byte(((rest & 0x7FU) | 0x80U).to_byte())
    rest = rest >> 7
  }
  buffer.write_byte(rest.to_byte())
}

///|
/// Sequential, bounds-checked reader over the encoded bytes.
priv struct Reader {
  view : BytesView
  mut pos : Int32
}

///|
/// Create a reader at offset zero.
fn Reader::new(view : BytesView) -> Reader {
  { view, pos: 0, }
}

///|
/// Bytes not consumed yet.
fn Reader::remaining(self : Reader) -> Int32 {
  self.view.length() - self.pos
}

///|
/// Read one byte.
fn Reader::read_byte(self : Reader) -> Byte raise IdsError {
  self.ensure(1)
  let byte = self.view[self.pos]
  self.pos = self.pos + 1
  byte
}

///|
/// Read one little-endian 16-bit value.
fn Reader::read_uint16(self : Reader) -> UInt16 raise IdsError {
  self.ensure(2)
  let value = self.view[self.pos].to_uint() |
    (self.view[self.pos + 1].to_uint() << 8)
  self.pos = self.pos + 2
  value.to_uint16()
}

///|
/// Read one little-endian 32-bit value.
fn Reader::read_uint(self : Reader) -> UInt32 raise IdsError {
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
fn Reader::read_uint64(self : Reader) -> UInt64 raise IdsError {
  self.ensure(8)
  let mut value = 0UL
  for index in 0..<8 {
    value = value | (self.view[self.pos + index].to_uint64() << (index * 8))
  }
  self.pos = self.pos + 8
  value
}

///|
/// Read one unsigned LEB128 value.
fn Reader::read_varint(self : Reader) -> UInt32 raise IdsError {
  let mut result = 0U
  let mut shift = 0
  while true {
    let byte = self.read_byte()
    let part = byte.to_uint() & 0x7FU
    if shift == 28 && part > 0x0FU {
      raise IdsError::Corrupt("varint does not fit in 32 bits")
    }
    result = result | (part << shift)
    if (byte.to_uint() & 0x80U) == 0U {
      return result
    }
    shift = shift + 7
    if shift >= 35 {
      raise IdsError::Corrupt("varint is too long")
    }
  }
  abort("unreachable")
}

///|
/// Require `count` readable bytes.
fn Reader::ensure(self : Reader, count : Int32) -> Unit raise IdsError {
  if count < 0 || self.pos + count > self.view.length() {
    raise IdsError::Truncated
  }
}
