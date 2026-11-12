///|
/// Number of ids a bits container covers: one 16-bit block.
pub const BITMAP_BLOCK_SIZE : Int32 = 65536

///|
/// Bit position of the block index inside an id.
pub const BITMAP_BLOCK_SHIFT : Int32 = 16

///|
/// Mask of the within-block offset of an id.
pub const BITMAP_BLOCK_MASK : Int32 = 0xFFFF

///|
/// Number of 64-bit words in a bits container.
pub const BITMAP_WORDS : Int32 = 1024

///|
/// Bits per word in a bits container.
pub const BITMAP_WORD_BITS : Int32 = 64

///|
/// Largest block index an `Int32` id can address.
pub const BITMAP_MAX_BLOCK : Int32 = 32767

///|
/// Cardinality at which a block container flips between the array and bits
/// representations. 4096 array entries occupy the same 8 KiB as a full bits
/// container, so the two forms match in size exactly at this threshold.
pub const CONTAINER_ARRAY_MAX : Int32 = 4096

///|
/// Physical storage of one 65536-id block.
///
/// `Array` keeps the ids present in the block as ascending 16-bit offsets and
/// is used while the block is sparse. `Bits` is a fixed 1024-word bitmap and is
/// used once the array form would be larger. The variant is an implementation
/// detail of `Bitmap`; use `Bitmap`'s methods rather than matching on it.
pub enum Container {
  Array(Array[UInt16])
  Bits(Array[UInt64])
}

///|
/// A compressed bitmap over `Int32` entry ids.
///
/// Ids are split into blocks of 65536 (`id >> 16`), and every block picks the
/// representation that matches its density. Sparse sets therefore stay small
/// (a handful of bytes per occupied block) while dense sets get word-parallel
/// set operations. The container array is indexed by block number; a `None`
/// block is empty and trailing empty blocks are trimmed.
///
/// `cardinality` is cached, so counting matches is O(1).
pub struct Bitmap {
  priv containers : Array[Container?]
  priv mut len : Int32
}

///|
/// Create an empty bitmap.
pub fn Bitmap::new() -> Bitmap {
  { containers: [], len: 0, }
}

///|
/// Build a bitmap from arbitrary ids.
///
/// Negative ids are ignored. Unsorted input and duplicates are accepted; the
/// bitmap stores each id once.
pub fn Bitmap::from_ids(ids : Array[Int32]) -> Bitmap {
  let bitmap = Bitmap::new()
  for id in ids {
    bitmap.add(id)
  }
  bitmap
}

///|
/// Deep copy of the bitmap.
pub fn Bitmap::clone(self : Bitmap) -> Bitmap {
  let containers : Array[Container?] = []
  for container in self.containers {
    match container {
      None => containers.push(None)
      Some(value) => containers.push(Some(clone_container(value)))
    }
  }
  { containers, len: self.len, }
}

///|
/// Number of ids in the bitmap.
pub fn Bitmap::cardinality(self : Bitmap) -> Int32 {
  self.len
}

///|
/// Whether the bitmap has no ids.
pub fn Bitmap::is_empty(self : Bitmap) -> Bool {
  self.len == 0
}

///|
/// Add one id. Negative ids are ignored.
///
/// A block starts as an array container, flips to a bits container when it
/// grows past `CONTAINER_ARRAY_MAX`, and keeps its form afterwards.
pub fn Bitmap::add(self : Bitmap, id : Int32) -> Unit {
  if id < 0 {
    return
  }
  let block = id >> BITMAP_BLOCK_SHIFT
  let offset = (id & BITMAP_BLOCK_MASK).to_uint16()
  while self.containers.length() <= block {
    self.containers.push(None)
  }
  match self.containers[block] {
    None => {
      self.containers[block] = Some(Container::Array([offset]))
      self.len = self.len + 1
    }
    Some(Container::Array(values)) => {
      let position = lower_bound(values, offset)
      if position >= values.length() || values[position] != offset {
        values.insert(position, offset)
        self.len = self.len + 1
        if values.length() > CONTAINER_ARRAY_MAX {
          self.containers[block] = Some(Container::Bits(array_to_bits(values)))
        }
      }
    }
    Some(Container::Bits(words)) => {
      let index = offset.to_int()
      let word = index / BITMAP_WORD_BITS
      let bit = index % BITMAP_WORD_BITS
      let mask = 1UL << bit
      if (words[word] & mask) == 0UL {
        words[word] = words[word] | mask
        self.len = self.len + 1
      }
    }
  }
}

///|
/// Remove one id. Removing an absent or negative id is a no-op.
///
/// A bits container flips back to the array form once its cardinality drops to
/// `CONTAINER_ARRAY_MAX`; an emptied block is set to `None` and trailing empty
/// blocks are trimmed.
pub fn Bitmap::remove(self : Bitmap, id : Int32) -> Unit {
  if id < 0 {
    return
  }
  let block = id >> BITMAP_BLOCK_SHIFT
  if block >= self.containers.length() {
    return
  }
  let offset = (id & BITMAP_BLOCK_MASK).to_uint16()
  match self.containers[block] {
    None => ()
    Some(Container::Array(values)) => {
      let position = lower_bound(values, offset)
      if position < values.length() && values[position] == offset {
        ignore(values.remove(position))
        self.len = self.len - 1
        if values.is_empty() {
          self.containers[block] = None
          trim_trailing_empty(self.containers)
        }
      }
    }
    Some(Container::Bits(words)) => {
      let index = offset.to_int()
      let word_index = index / BITMAP_WORD_BITS
      let bit = index % BITMAP_WORD_BITS
      let mask = 1UL << bit
      if (words[word_index] & mask) != 0UL {
        words[word_index] = words[word_index] & mask.lnot()
        self.len = self.len - 1
        let remaining = words_cardinality(words)
        if remaining == 0 {
          self.containers[block] = None
          trim_trailing_empty(self.containers)
        } else if remaining <= CONTAINER_ARRAY_MAX {
          self.containers[block] = Some(Container::Array(bits_to_array(words)))
        }
      }
    }
  }
}

///|
/// Whether the id is present.
pub fn Bitmap::contains(self : Bitmap, id : Int32) -> Bool {
  if id < 0 {
    return false
  }
  let block = id >> BITMAP_BLOCK_SHIFT
  if block >= self.containers.length() {
    return false
  }
  match self.containers[block] {
    None => false
    Some(container) =>
      container_contains(container, (id & BITMAP_BLOCK_MASK).to_uint16())
  }
}

///|
/// All ids in the bitmap, ascending.
pub fn Bitmap::to_sorted_ids(self : Bitmap) -> Array[Int32] {
  let ids : Array[Int32] = []
  for block in 0..<self.containers.length() {
    let base = block << BITMAP_BLOCK_SHIFT
    match self.containers[block] {
      None => ()
      Some(Container::Array(values)) =>
        for value in values {
          ids.push(base + value.to_int())
        }
      Some(Container::Bits(words)) =>
        for value in bits_to_array(words) {
          ids.push(base + value.to_int())
        }
    }
  }
  ids
}

///|
/// Intersection of two bitmaps.
pub fn Bitmap::intersect(self : Bitmap, other : Bitmap) -> Bitmap {
  let blocks = if self.containers.length() < other.containers.length() {
    self.containers.length()
  } else {
    other.containers.length()
  }
  let result : Array[Container?] = []
  let mut count = 0
  for block in 0..<blocks {
    let container = match (self.containers[block], other.containers[block]) {
      (Some(left), Some(right)) => containers_and(left, right)
      _ => None
    }
    match container {
      Some(value) => count = count + container_cardinality(value)
      None => ()
    }
    result.push(container)
  }
  trim_trailing_empty(result)
  { containers: result, len: count, }
}

///|
/// Union of two bitmaps.
pub fn Bitmap::union(self : Bitmap, other : Bitmap) -> Bitmap {
  let blocks = if self.containers.length() > other.containers.length() {
    self.containers.length()
  } else {
    other.containers.length()
  }
  let result : Array[Container?] = []
  let mut count = 0
  for block in 0..<blocks {
    let left = block_container(self.containers, block)
    let right = block_container(other.containers, block)
    let container = match (left, right) {
      (None, None) => None
      (Some(value), None) => Some(clone_container(value))
      (None, Some(value)) => Some(clone_container(value))
      (Some(a), Some(b)) => containers_or(a, b)
    }
    match container {
      Some(value) => count = count + container_cardinality(value)
      None => ()
    }
    result.push(container)
  }
  trim_trailing_empty(result)
  { containers: result, len: count, }
}

///|
/// Difference `self \ other` of two bitmaps.
pub fn Bitmap::difference(self : Bitmap, other : Bitmap) -> Bitmap {
  let result : Array[Container?] = []
  let mut count = 0
  for block in 0..<self.containers.length() {
    let left = self.containers[block]
    let right = block_container(other.containers, block)
    let container = match (left, right) {
      (None, _) => None
      (Some(value), None) => Some(clone_container(value))
      (Some(a), Some(b)) => containers_andnot(a, b)
    }
    match container {
      Some(value) => count = count + container_cardinality(value)
      None => ()
    }
    result.push(container)
  }
  trim_trailing_empty(result)
  { containers: result, len: count, }
}

///|
/// Container at `block`, or `None` when the block is out of range or empty.
fn block_container(containers : Array[Container?], block : Int32) -> Container? {
  if block < 0 || block >= containers.length() {
    None
  } else {
    containers[block]
  }
}

///|
/// Number of ids stored in one container.
fn container_cardinality(container : Container) -> Int32 {
  match container {
    Container::Array(values) => values.length()
    Container::Bits(words) => words_cardinality(words)
  }
}

///|
/// Number of set bits in a bits container.
fn words_cardinality(words : Array[UInt64]) -> Int32 {
  let mut total = 0
  for word in words {
    total = total + word.popcnt()
  }
  total
}

///|
/// Whether a container holds the within-block offset.
fn container_contains(container : Container, offset : UInt16) -> Bool {
  match container {
    Container::Array(values) => {
      let position = lower_bound(values, offset)
      position < values.length() && values[position] == offset
    }
    Container::Bits(words) => {
      let index = offset.to_int()
      let word = index / BITMAP_WORD_BITS
      let bit = index % BITMAP_WORD_BITS
      (words[word] & (1UL << bit)) != 0UL
    }
  }
}

///|
/// First position in an ascending array whose value is at least `target`.
fn lower_bound(values : Array[UInt16], target : UInt16) -> Int32 {
  let mut low = 0
  let mut high = values.length()
  while low < high {
    let middle = (low + high) / 2
    if values[middle] < target {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low
}

///|
/// Deep copy of one container.
fn clone_container(container : Container) -> Container {
  match container {
    Container::Array(values) => Container::Array(values.copy())
    Container::Bits(words) => Container::Bits(words.copy())
  }
}

///|
/// Convert array offsets to a fresh bits container.
fn array_to_bits(values : Array[UInt16]) -> Array[UInt64] {
  let words : Array[UInt64] = []
  for _ in 0..<BITMAP_WORDS {
    words.push(0UL)
  }
  for value in values {
    let index = value.to_int()
    let word = index / BITMAP_WORD_BITS
    let bit = index % BITMAP_WORD_BITS
    words[word] = words[word] | (1UL << bit)
  }
  words
}

///|
/// Extract the offsets of a bits container in ascending order.
fn bits_to_array(words : Array[UInt64]) -> Array[UInt16] {
  let values : Array[UInt16] = []
  for word_index in 0..<BITMAP_WORDS {
    let mut word = words[word_index]
    while word != 0UL {
      let bit = word.ctz()
      values.push((word_index * BITMAP_WORD_BITS + bit).to_uint16())
      word = word & (word - 1UL)
    }
  }
  values
}

///|
/// Normalize an array container: drop empty blocks and flip to bits when the
/// cardinality passes the threshold.
fn normalize_array_container(values : Array[UInt16]) -> Container? {
  if values.is_empty() {
    None
  } else if values.length() <= CONTAINER_ARRAY_MAX {
    Some(Container::Array(values))
  } else {
    Some(Container::Bits(array_to_bits(values)))
  }
}

///|
/// Normalize a bits container: drop empty blocks and flip to an array when the
/// cardinality falls to the threshold.
fn normalize_bits_container(words : Array[UInt64]) -> Container? {
  let count = words_cardinality(words)
  if count == 0 {
    None
  } else if count <= CONTAINER_ARRAY_MAX {
    Some(Container::Array(bits_to_array(words)))
  } else {
    Some(Container::Bits(words))
  }
}

///|
/// Block-level intersection.
fn containers_and(left : Container, right : Container) -> Container? {
  match (left, right) {
    (Container::Array(a), Container::Array(b)) => array_and_array(a, b)
    (Container::Array(a), Container::Bits(b)) => array_and_bits(a, b)
    (Container::Bits(a), Container::Array(b)) => array_and_bits(b, a)
    (Container::Bits(a), Container::Bits(b)) => bits_and_bits(a, b)
  }
}

///|
/// Block-level union.
fn containers_or(left : Container, right : Container) -> Container? {
  match (left, right) {
    (Container::Array(a), Container::Array(b)) => array_or_array(a, b)
    (Container::Array(a), Container::Bits(b)) => array_or_bits(a, b)
    (Container::Bits(a), Container::Array(b)) => array_or_bits(b, a)
    (Container::Bits(a), Container::Bits(b)) => bits_or_bits(a, b)
  }
}

///|
/// Block-level difference `left \ right`.
fn containers_andnot(left : Container, right : Container) -> Container? {
  match (left, right) {
    (Container::Array(a), Container::Array(b)) => array_andnot_array(a, b)
    (Container::Array(a), Container::Bits(b)) => array_andnot_bits(a, b)
    (Container::Bits(a), Container::Array(b)) => bits_andnot_array(a, b)
    (Container::Bits(a), Container::Bits(b)) => bits_andnot_bits(a, b)
  }
}

///|
/// Merge-intersection of two ascending offset arrays.
fn array_and_array(left : Array[UInt16], right : Array[UInt16]) -> Container? {
  let result : Array[UInt16] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    let a = left[i]
    let b = right[j]
    if a == b {
      result.push(a)
      i = i + 1
      j = j + 1
    } else if a < b {
      i = i + 1
    } else {
      j = j + 1
    }
  }
  normalize_array_container(result)
}

///|
/// Probe every offset of an array against a bits container.
fn array_and_bits(values : Array[UInt16], words : Array[UInt64]) -> Container? {
  let result : Array[UInt16] = []
  for value in values {
    let index = value.to_int()
    let word = index / BITMAP_WORD_BITS
    let bit = index % BITMAP_WORD_BITS
    if (words[word] & (1UL << bit)) != 0UL {
      result.push(value)
    }
  }
  normalize_array_container(result)
}

///|
/// Word-parallel intersection of two bits containers.
fn bits_and_bits(left : Array[UInt64], right : Array[UInt64]) -> Container? {
  let result : Array[UInt64] = []
  for index in 0..<BITMAP_WORDS {
    result.push(left[index] & right[index])
  }
  normalize_bits_container(result)
}

///|
/// Merge-union of two ascending offset arrays.
fn array_or_array(left : Array[UInt16], right : Array[UInt16]) -> Container? {
  let result : Array[UInt16] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    let a = left[i]
    let b = right[j]
    if a == b {
      result.push(a)
      i = i + 1
      j = j + 1
    } else if a < b {
      result.push(a)
      i = i + 1
    } else {
      result.push(b)
      j = j + 1
    }
  }
  while i < left.length() {
    result.push(left[i])
    i = i + 1
  }
  while j < right.length() {
    result.push(right[j])
    j = j + 1
  }
  normalize_array_container(result)
}

///|
/// Add array offsets to a copy of a bits container.
fn array_or_bits(values : Array[UInt16], words : Array[UInt64]) -> Container? {
  let result = words.copy()
  for value in values {
    let index = value.to_int()
    let word = index / BITMAP_WORD_BITS
    let bit = index % BITMAP_WORD_BITS
    result[word] = result[word] | (1UL << bit)
  }
  normalize_bits_container(result)
}

///|
/// Word-parallel union of two bits containers.
fn bits_or_bits(left : Array[UInt64], right : Array[UInt64]) -> Container? {
  let result : Array[UInt64] = []
  for index in 0..<BITMAP_WORDS {
    result.push(left[index] | right[index])
  }
  normalize_bits_container(result)
}

///|
/// Merge-difference of two ascending offset arrays.
fn array_andnot_array(
  left : Array[UInt16],
  right : Array[UInt16],
) -> Container? {
  let result : Array[UInt16] = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    let a = left[i]
    let b = right[j]
    if a == b {
      i = i + 1
      j = j + 1
    } else if a < b {
      result.push(a)
      i = i + 1
    } else {
      j = j + 1
    }
  }
  while i < left.length() {
    result.push(left[i])
    i = i + 1
  }
  normalize_array_container(result)
}

///|
/// Keep the array offsets that are absent from the bits container.
fn array_andnot_bits(
  values : Array[UInt16],
  words : Array[UInt64],
) -> Container? {
  let result : Array[UInt16] = []
  for value in values {
    let index = value.to_int()
    let word = index / BITMAP_WORD_BITS
    let bit = index % BITMAP_WORD_BITS
    if (words[word] & (1UL << bit)) == 0UL {
      result.push(value)
    }
  }
  normalize_array_container(result)
}

///|
/// Clear array offsets from a copy of a bits container.
fn bits_andnot_array(
  words : Array[UInt64],
  values : Array[UInt16],
) -> Container? {
  let result = words.copy()
  for value in values {
    let index = value.to_int()
    let word = index / BITMAP_WORD_BITS
    let bit = index % BITMAP_WORD_BITS
    result[word] = result[word] & (1UL << bit).lnot()
  }
  normalize_bits_container(result)
}

///|
/// Word-parallel difference of two bits containers.
fn bits_andnot_bits(left : Array[UInt64], right : Array[UInt64]) -> Container? {
  let result : Array[UInt64] = []
  for index in 0..<BITMAP_WORDS {
    result.push(left[index] & right[index].lnot())
  }
  normalize_bits_container(result)
}

///|
/// Drop trailing empty blocks from a container array.
fn trim_trailing_empty(containers : Array[Container?]) -> Unit {
  let mut trimming = true
  while trimming && !containers.is_empty() {
    match containers[containers.length() - 1] {
      None => ignore(containers.pop())
      Some(_) => trimming = false
    }
  }
}
