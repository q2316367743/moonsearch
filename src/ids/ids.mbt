///|
/// Largest cardinality a `Sorted` set keeps before it becomes a `Bitmap`.
pub const IDS_SORTED_MAX : Int32 = 4096

///|
/// Density divisor for shape selection: a sorted set whose cardinality exceeds
/// `total / IDS_DENSITY_DIVISOR` is stored as a bitmap, because probing dense
/// ids one by one is slower than word-parallel operations.
pub const IDS_DENSITY_DIVISOR : Int32 = 32

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
/// Wrap an existing bitmap, converting it to the sorted form when it is small.
///
/// The bitmap is not copied; the result may share it. Use `Bitmap::clone` first
/// if the caller keeps mutating the source.
pub fn Ids::from_bitmap(bitmap : Bitmap) -> Ids {
  let count = bitmap.cardinality()
  if count == 0 {
    Sorted([])
  } else if count > IDS_SORTED_MAX {
    Bitmap(bitmap)
  } else {
    Sorted(bitmap.to_sorted_ids())
  }
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
/// word operations, sorted×sorted uses a merge, and mixed pairs probe the
/// bitmap with the smaller sorted side.
pub fn Ids::intersect(self : Ids, other : Ids) -> Ids {
  match (self, other) {
    (Bitmap(left), Bitmap(right)) => Ids::from_bitmap(left.intersect(right))
    (Sorted(left), Sorted(right)) =>
      canonical_sorted(sorted_intersect(left, right), 0)
    (Bitmap(bitmap), Sorted(ids)) => bitmap_intersect_sorted(bitmap, ids)
    (Sorted(ids), Bitmap(bitmap)) => bitmap_intersect_sorted(bitmap, ids)
  }
}

///|
/// Union of two sets.
pub fn Ids::union(self : Ids, other : Ids) -> Ids {
  match (self, other) {
    (Bitmap(left), Bitmap(right)) => Ids::from_bitmap(left.union(right))
    (Sorted(left), Sorted(right)) =>
      canonical_sorted(sorted_union(left, right), 0)
    (Bitmap(bitmap), Sorted(ids)) =>
      Ids::from_bitmap(bitmap.union(Bitmap::from_ids(ids)))
    (Sorted(ids), Bitmap(bitmap)) =>
      Ids::from_bitmap(bitmap.union(Bitmap::from_ids(ids)))
  }
}

///|
/// Difference `self \ other`.
pub fn Ids::difference(self : Ids, other : Ids) -> Ids {
  match (self, other) {
    (Bitmap(left), Bitmap(right)) => Ids::from_bitmap(left.difference(right))
    (Sorted(left), Sorted(right)) =>
      canonical_sorted(sorted_difference(left, right), 0)
    (Bitmap(bitmap), Sorted(ids)) =>
      Ids::from_bitmap(bitmap.difference(Bitmap::from_ids(ids)))
    (Sorted(ids), Bitmap(bitmap)) => {
      let result : Array[Int32] = []
      for id in ids {
        if !bitmap.contains(id) {
          result.push(id)
        }
      }
      canonical_sorted(result, 0)
    }
  }
}

///|
/// Keep only the ids accepted by `pred`.
///
/// The result is re-normalized by cardinality, so filtering a bitmap down to a
/// handful of ids returns a sorted set.
pub fn Ids::filter(self : Ids, pred : (Int32) -> Bool) -> Ids {
  let result : Array[Int32] = []
  match self {
    Bitmap(bitmap) =>
      for id in bitmap.to_sorted_ids() {
        if pred(id) {
          result.push(id)
        }
      }
    Sorted(ids) =>
      for id in ids {
        if pred(id) {
          result.push(id)
        }
      }
  }
  canonical_sorted(result, 0)
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
/// Merge-intersection of two ascending arrays.
fn sorted_intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let result : Array[Int32] = []
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
  result
}

///|
/// Merge-union of two ascending arrays.
fn sorted_union(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let result : Array[Int32] = []
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
  result
}

///|
/// Merge-difference of two ascending arrays.
fn sorted_difference(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let result : Array[Int32] = []
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
  result
}

///|
/// Intersect a bitmap with a sorted set.
///
/// Small sorted sides are cheaper to probe than to turn into a bitmap; a large
/// sorted side (only possible through the raw `Sorted` constructor) is
/// converted first, as the plan's strategy table specifies.
fn bitmap_intersect_sorted(bitmap : Bitmap, ids : Array[Int32]) -> Ids {
  if ids.length() > IDS_SORTED_MAX {
    Ids::from_bitmap(bitmap.intersect(Bitmap::from_ids(ids)))
  } else {
    let result : Array[Int32] = []
    for id in ids {
      if bitmap.contains(id) {
        result.push(id)
      }
    }
    canonical_sorted(result, 0)
  }
}
