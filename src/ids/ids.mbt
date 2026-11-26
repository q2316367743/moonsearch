///|
/// Largest cardinality a `Sorted` set keeps before it becomes a `Bitmap`.
pub const IDS_SORTED_MAX : Int32 = 4096

///|
/// Density divisor for shape selection: a sorted set whose cardinality exceeds
/// `total / IDS_DENSITY_DIVISOR` is stored as a bitmap, because probing dense
/// ids one by one is slower than word-parallel operations.
pub const IDS_DENSITY_DIVISOR : Int32 = 32

///|
/// Minimum sorted-length difference before an operation switches from a linear
/// merge to exponential (galloping) search. The plan specifies `difference > 8`.
pub const IDS_GALLOP_MIN_LENGTH_DIFF : Int32 = 8

///|
/// An id set in one of two physical representations.
///
/// `Sorted` is an ascending, duplicate-free `Int32` array and wins for sparse
/// results: it is compact and merge-friendly. `Bitmap` is a compressed bitmap
/// and wins for dense results: intersections, unions, and differences are
/// word-parallel and cardinality is cached.
///
/// Both forms denote the same mathematical set. Public constructors keep the
/// invariants; the variants are exposed so the executor can choose a strategy
/// by pattern matching.
pub enum Ids {
  Bitmap(Bitmap)
  Sorted(Array[Int32])
}

///|
/// The empty set, in sorted form.
pub fn Ids::empty() -> Ids {
  Sorted([])
}

///|
/// Build an id set from arbitrary ids.
///
/// Negative ids are dropped, duplicates collapse, and the input order is
/// irrelevant. `total` is the number of entries in the index (0 when unknown);
/// when it is positive, the density rule from `normalize` also applies.
pub fn Ids::from_sorted(ids : Array[Int32], total~ : Int32 = 0) -> Ids {
  let values : Array[Int32] = []
  for id in ids {
    if id >= 0 {
      values.push(id)
    }
  }
  values.sort()
  values.dedup()
  canonical_sorted(values, total)
}

///|
/// Take ownership of an already canonical ascending, duplicate-free id array.
///
/// This is the allocation-free constructor used by execution workspaces after
/// they have filtered or merged ids. The caller must not mutate or retain the
/// array afterwards. Use `from_sorted` for arbitrary input.
pub fn Ids::from_sorted_canonical(
  ids : Array[Int32],
  total~ : Int32 = 0,
) -> Ids {
  canonical_sorted(ids, total)
}

///|
/// Wrap an existing bitmap, converting it to the sorted form when it is small.
///
/// The bitmap is not copied; the result may share it. Use `Bitmap::clone` first
/// if the caller keeps mutating the source.
pub fn Ids::from_bitmap(bitmap : Bitmap) -> Ids {
  canonical_bitmap(bitmap, 0)
}

///|
/// Number of ids in the set.
pub fn Ids::cardinality(self : Ids) -> Int32 {
  match self {
    Bitmap(bitmap) => bitmap.cardinality()
    Sorted(ids) => ids.length()
  }
}

///|
/// Highest occupied 65536-id block, or `-1` for an empty set.
pub fn Ids::max_block(self : Ids) -> Int32 {
  match self {
    Bitmap(bitmap) => bitmap.max_block()
    Sorted(ids) =>
      if ids.is_empty() {
        -1
      } else {
        ids[ids.length() - 1] >> BITMAP_BLOCK_SHIFT
      }
  }
}

///|
/// Highest id in the set, or `-1` when it is empty.
pub fn Ids::max_id(self : Ids) -> Int32 {
  match self {
    Bitmap(bitmap) => bitmap.max_id()
    Sorted(ids) => if ids.is_empty() { -1 } else { ids[ids.length() - 1] }
  }
}

///|
/// Whether the set has no ids.
pub fn Ids::is_empty(self : Ids) -> Bool {
  self.cardinality() == 0
}

///|
/// Whether the id is a member.
pub fn Ids::contains(self : Ids, id : Int32) -> Bool {
  match self {
    Bitmap(bitmap) => bitmap.contains(id)
    Sorted(ids) => sorted_contains(ids, id)
  }
}

///|
/// Rewrite the set into the representation its size and density call for.
///
/// A set becomes a bitmap when its cardinality exceeds `IDS_SORTED_MAX` or,
/// with a positive `total`, when `cardinality * IDS_DENSITY_DIVISOR > total`.
/// Otherwise it stays (or becomes) a sorted array.
pub fn Ids::normalize(self : Ids, total : Int32) -> Ids {
  match self {
    Bitmap(bitmap) => {
      let count = bitmap.cardinality()
      if count == 0 {
        Sorted([])
      } else if prefer_bitmap(count, total) {
        Bitmap(bitmap)
      } else {
        Sorted(bitmap.to_sorted_ids())
      }
    }
    Sorted(ids) => canonical_sorted(ids, total)
  }
}

///|
/// Intersection of two sets.
///
/// The operator picks the cheapest pair of representations: bitmap×bitmap uses
/// word operations, sorted×sorted uses a merge or galloping when the lengths are
/// sufficiently skewed, and mixed pairs probe the bitmap with the smaller sorted
/// side.
pub fn Ids::intersect(self : Ids, other : Ids) -> Ids {
  self.intersect_with_total(other)
}

///|
/// Intersection with result shaping based on the index-wide entry count.
pub fn Ids::intersect_with_total(
  self : Ids,
  other : Ids,
  total~ : Int32 = 0,
) -> Ids {
  if self.is_empty() || other.is_empty() {
    return Ids::empty()
  }
  match (self, other) {
    (Bitmap(left), Bitmap(right)) =>
      canonical_bitmap(left.intersect(right), total)
    (Sorted(left), Sorted(right)) =>
      canonical_sorted(sorted_intersect(left, right), total)
    (Bitmap(bitmap), Sorted(ids)) =>
      bitmap_intersect_sorted(bitmap, ids, total~)
    (Sorted(ids), Bitmap(bitmap)) =>
      bitmap_intersect_sorted(bitmap, ids, total~)
  }
}

///|
/// Union of two sets.
pub fn Ids::union(self : Ids, other : Ids) -> Ids {
  self.union_with_total(other)
}

///|
/// Union with result shaping based on the index-wide entry count.
pub fn Ids::union_with_total(
  self : Ids,
  other : Ids,
  total~ : Int32 = 0,
) -> Ids {
  if self.is_empty() {
    return if representation_matches(other, total) {
      other
    } else {
      other.normalize(total)
    }
  }
  if other.is_empty() {
    return if representation_matches(self, total) {
      self
    } else {
      self.normalize(total)
    }
  }
  match (self, other) {
    (Bitmap(left), Bitmap(right)) => canonical_bitmap(left.union(right), total)
    (Sorted(left), Sorted(right)) =>
      canonical_sorted(sorted_union(left, right), total)
    (Bitmap(bitmap), Sorted(ids)) => bitmap_union_sorted(bitmap, ids, total~)
    (Sorted(ids), Bitmap(bitmap)) => bitmap_union_sorted(bitmap, ids, total~)
  }
}

///|
/// Difference `self \ other`.
pub fn Ids::difference(self : Ids, other : Ids) -> Ids {
  self.difference_with_total(other)
}

///|
/// Difference with result shaping based on the index-wide entry count.
pub fn Ids::difference_with_total(
  self : Ids,
  other : Ids,
  total~ : Int32 = 0,
) -> Ids {
  if self.is_empty() {
    return Ids::empty()
  }
  if other.is_empty() {
    return if representation_matches(self, total) {
      self
    } else {
      self.normalize(total)
    }
  }
  match (self, other) {
    (Bitmap(left), Bitmap(right)) =>
      canonical_bitmap(left.difference(right), total)
    (Sorted(left), Sorted(right)) =>
      canonical_sorted(sorted_difference(left, right), total)
    (Bitmap(bitmap), Sorted(ids)) =>
      bitmap_difference_sorted(bitmap, ids, total~)
    (Sorted(ids), Bitmap(bitmap)) => {
      let result : Array[Int32] = []
      for id in ids {
        if !bitmap.contains(id) {
          result.push(id)
        }
      }
      canonical_sorted(result, total)
    }
  }
}

///|
/// Keep only the ids accepted by `pred`.
///
/// The result is re-normalized by cardinality, so filtering a bitmap down to a
/// handful of ids returns a sorted set.
pub fn Ids::filter(self : Ids, pred : (Int32) -> Bool) -> Ids {
  self.filter_with_total(pred)
}

///|
/// Filter with result shaping based on the index-wide entry count.
pub fn Ids::filter_with_total(
  self : Ids,
  pred : (Int32) -> Bool,
  total~ : Int32 = 0,
) -> Ids {
  let result : Array[Int32] = []
  self.filter_into(pred, result)
  canonical_sorted(result, total)
}

///|
/// Append the ids accepted by `pred` to `values`, clearing it first.
///
/// The array's capacity is retained. This low-level helper lets an execution
/// context recycle a work buffer without the intermediate sorted array that a
/// bitmap would otherwise allocate. It does not normalize or take ownership of
/// `values`; pass the result to `from_sorted_canonical` afterwards.
pub fn Ids::filter_into(
  self : Ids,
  pred : (Int32) -> Bool,
  values : Array[Int32],
) -> Unit {
  while !values.is_empty() {
    ignore(values.pop())
  }
  match self {
    Bitmap(bitmap) =>
      bitmap.for_each_ids(fn(id) { if pred(id) { values.push(id) } })
    Sorted(ids) =>
      for id in ids {
        if pred(id) {
          values.push(id)
        }
      }
  }
}

///|
/// Convert to a bitmap, copying when the set is already one.
pub fn Ids::to_bitmap(self : Ids) -> Bitmap {
  match self {
    Bitmap(bitmap) => bitmap.clone()
    Sorted(ids) => Bitmap::from_ids(ids)
  }
}

///|
/// All ids in the set, ascending. The returned array is a copy.
pub fn Ids::to_sorted_ids(self : Ids) -> Array[Int32] {
  match self {
    Bitmap(bitmap) => bitmap.to_sorted_ids()
    Sorted(ids) => ids.copy()
  }
}

///|
/// Canonicalize an ascending, duplicate-free array.
///
/// This is the single place that decides between the two representations, so
/// the cardinality and density thresholds are applied consistently.
fn canonical_sorted(values : Array[Int32], total : Int32) -> Ids {
  let count = values.length()
  if count == 0 {
    Sorted(values)
  } else if prefer_bitmap(count, total) {
    Bitmap(Bitmap::from_ids(values))
  } else {
    Sorted(values)
  }
}

///|
/// Normalize a bitmap without converting it to sorted and back unnecessarily.
fn canonical_bitmap(bitmap : Bitmap, total : Int32) -> Ids {
  let count = bitmap.cardinality()
  if count == 0 {
    Sorted([])
  } else if prefer_bitmap(count, total) {
    Bitmap(bitmap)
  } else {
    Sorted(bitmap.to_sorted_ids())
  }
}

///|
/// Whether an empty-set short circuit can return the operand without traversing
/// it. Canonical operands usually match; a raw enum value may still need shape
/// normalization when the caller supplies the index-wide total.
fn representation_matches(ids : Ids, total : Int32) -> Bool {
  match ids {
    Bitmap(bitmap) => prefer_bitmap(bitmap.cardinality(), total)
    Sorted(values) => !prefer_bitmap(values.length(), total)
  }
}

///|
/// Whether a set of `count` ids should be stored as a bitmap.
fn prefer_bitmap(count : Int32, total : Int32) -> Bool {
  if count > IDS_SORTED_MAX {
    return true
  }
  if total <= 0 {
    return false
  }
  count.to_int64() * IDS_DENSITY_DIVISOR.to_int64() > total.to_int64()
}

///|
/// Binary search in an ascending array.
fn sorted_contains(ids : Array[Int32], id : Int32) -> Bool {
  let mut low = 0
  let mut high = ids.length()
  while low < high {
    let middle = (low + high) / 2
    if ids[middle] < id {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low < ids.length() && ids[low] == id
}

///|
/// Strategy for two sorted operands.
priv enum SortedStrategy {
  Merge
  GallopLeft
  GallopRight
}

///|
/// Pick galloping only when one side is more than the plan's threshold longer.
fn sorted_strategy(left : Int32, right : Int32) -> SortedStrategy {
  let difference = left.to_int64() - right.to_int64()
  if difference > IDS_GALLOP_MIN_LENGTH_DIFF.to_int64() {
    GallopRight
  } else if difference < -IDS_GALLOP_MIN_LENGTH_DIFF.to_int64() {
    GallopLeft
  } else {
    Merge
  }
}

///|
/// Merge-intersection of two ascending arrays.
fn sorted_intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let result : Array[Int32] = []
  match sorted_strategy(left.length(), right.length()) {
    Merge => sorted_intersect_merge(left, right, result)
    GallopLeft => gallop_intersect(left, right, result)
    GallopRight => gallop_intersect(right, left, result)
  }
  result
}

///|
/// Linear merge used when sorted operands have similar lengths.
fn sorted_intersect_merge(
  left : Array[Int32],
  right : Array[Int32],
  result : Array[Int32],
) -> Unit {
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
}

///|
/// Probe a longer sorted array for every element of a shorter one.
fn gallop_intersect(
  short : Array[Int32],
  long : Array[Int32],
  result : Array[Int32],
) -> Unit {
  let mut position = 0
  for value in short {
    position = gallop_lower_bound(long, value, position)
    if position >= long.length() {
      return
    }
    if long[position] == value {
      result.push(value)
      position = position + 1
    }
  }
}

///|
/// Union of two ascending arrays.
fn sorted_union(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let result : Array[Int32] = []
  match sorted_strategy(left.length(), right.length()) {
    Merge => sorted_union_merge(left, right, result)
    GallopLeft => gallop_union(left, right, result)
    GallopRight => gallop_union(right, left, result)
  }
  result
}

///|
/// Linear merge used when sorted operands have similar lengths.
fn sorted_union_merge(
  left : Array[Int32],
  right : Array[Int32],
  result : Array[Int32],
) -> Unit {
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
}

///|
/// Merge skewed sorted arrays by galloping the short side through the long one.
/// Every long-side element still has to be emitted, but the short side avoids a
/// linear walk across large gaps.
fn gallop_union(
  short : Array[Int32],
  long : Array[Int32],
  result : Array[Int32],
) -> Unit {
  let mut long_position = 0
  for value in short {
    let next = gallop_lower_bound(long, value, long_position)
    while long_position < next {
      result.push(long[long_position])
      long_position = long_position + 1
    }
    result.push(value)
    if long_position < long.length() && long[long_position] == value {
      long_position = long_position + 1
    }
  }
  while long_position < long.length() {
    result.push(long[long_position])
    long_position = long_position + 1
  }
}

///|
/// Difference `left \ right` of two ascending arrays.
fn sorted_difference(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let result : Array[Int32] = []
  match sorted_strategy(left.length(), right.length()) {
    Merge => sorted_difference_merge(left, right, result)
    GallopLeft | GallopRight => gallop_difference(left, right, result)
  }
  result
}

///|
/// Linear merge used when sorted operands have similar lengths.
fn sorted_difference_merge(
  left : Array[Int32],
  right : Array[Int32],
  result : Array[Int32],
) -> Unit {
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
}

///|
/// Difference with an advancing galloping cursor in the right operand.
fn gallop_difference(
  left : Array[Int32],
  right : Array[Int32],
  result : Array[Int32],
) -> Unit {
  let mut position = 0
  for value in left {
    position = gallop_lower_bound(right, value, position)
    if position >= right.length() || right[position] != value {
      result.push(value)
    }
  }
}

///|
/// First position whose value is at least `target`, starting at `start`.
///
/// The search doubles its step until it brackets the target, then binary
/// searches that bracket. Int64 intermediates keep the doubling arithmetic safe
/// even for arrays near the Int32 length limit.
fn gallop_lower_bound(
  values : Array[Int32],
  target : Int32,
  start : Int32,
) -> Int32 {
  let length = values.length().to_int64()
  let mut low = if start < 0 { 0L } else { start.to_int64() }
  if low >= length {
    return length.to_int()
  }
  if values[low.to_int()] >= target {
    return low.to_int()
  }
  let mut high = low + 1L
  while high < length && values[high.to_int()] < target {
    low = high + 1L
    if high > (length - 1L) / 2L {
      high = length
    } else {
      high = high * 2L
    }
  }
  let mut end = if high < length { high + 1L } else { length }
  while low < end {
    let middle = (low + end) / 2L
    if values[middle.to_int()] < target {
      low = middle + 1L
    } else {
      end = middle
    }
  }
  low.to_int()
}

///|
/// Intersect a bitmap with a sorted set.
///
/// Small sorted sides are cheaper to probe than to turn into a bitmap; a large
/// sorted side (only possible through the raw `Sorted` constructor) is
/// converted first, as the plan's strategy table specifies.
fn bitmap_intersect_sorted(
  bitmap : Bitmap,
  ids : Array[Int32],
  total~ : Int32,
) -> Ids {
  if ids.length() > IDS_SORTED_MAX {
    canonical_bitmap(bitmap.intersect(Bitmap::from_ids(ids)), total)
  } else {
    let result : Array[Int32] = []
    for id in ids {
      if bitmap.contains(id) {
        result.push(id)
      }
    }
    canonical_sorted(result, total)
  }
}

///|
/// Union a small sorted side into a bitmap without allocating empty blocks up
/// to a large sparse id. Large raw sorted sides use the block-parallel path.
fn bitmap_union_sorted(
  bitmap : Bitmap,
  ids : Array[Int32],
  total~ : Int32,
) -> Ids {
  if ids.length() > IDS_SORTED_MAX {
    canonical_bitmap(bitmap.union(Bitmap::from_ids(ids)), total)
  } else {
    let result = bitmap.clone()
    result.add_ids(ids)
    canonical_bitmap(result, total)
  }
}

///|
/// Remove a small sorted side from a bitmap without materializing its empty
/// blocks. Large raw sorted sides use the block-parallel path.
fn bitmap_difference_sorted(
  bitmap : Bitmap,
  ids : Array[Int32],
  total~ : Int32,
) -> Ids {
  if ids.length() > IDS_SORTED_MAX {
    canonical_bitmap(bitmap.difference(Bitmap::from_ids(ids)), total)
  } else {
    let result = bitmap.clone()
    result.remove_ids(ids)
    canonical_bitmap(result, total)
  }
}
