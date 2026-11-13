///|
/// Number of shortest postings one lookup intersects.
///
/// Every byte trigram of the needle must occur in any matching name, so
/// intersecting a subset is still a superset. Three keeps the number of merge
/// passes bounded while the shortest lists supply most of the selectivity.
pub const TRIGRAM_POSTING_LIMIT : Int32 = 3

///|
/// Divisor of the stop-gram threshold: a posting holding more than
/// `total / TRIGRAM_STOP_GRAM_DIVISOR` ids (20%) is skipped at query time.
///
/// Such a posting appears in too large a share of the index to narrow the
/// candidate set, so intersecting it only costs time.
pub const TRIGRAM_STOP_GRAM_DIVISOR : Int32 = 5

///|
/// Ratio at which the intersection stops merging and gallops over the longer
/// posting. Merging is linear in the longer side; once the lists are far apart
/// in length, exponential search followed by binary search is cheaper.
const TRIGRAM_GALLOP_RATIO : Int32 = 32

///|
/// The ids of one trigram, ascending and duplicate-free.
///
/// A posting is built by appending ids in store-wide id order, so the ascending
/// invariant holds without a final sort. Query-time intersections read the
/// array; nothing mutates it after construction.
pub struct TrigramPosting {
  priv ids : Array[Int32]
}

///|
/// Number of ids in the posting.
pub fn TrigramPosting::len(self : TrigramPosting) -> Int32 {
  self.ids.length()
}

///|
/// Whether the trigram occurs in no indexed name.
pub fn TrigramPosting::is_empty(self : TrigramPosting) -> Bool {
  self.ids.length() == 0
}

///|
/// Ids in ascending order, for diagnostics and tests.
pub fn TrigramPosting::ids(self : TrigramPosting) -> ArrayView[Int32] {
  self.ids
}

///|
/// The trigram inverted index over entry names.
///
/// One posting per distinct ASCII-folded 3-byte window. Keys are stored in one
/// ascending `UInt32` array and the postings in a parallel array, so a lookup
/// is a binary search and no per-key hash container survives the build.
///
/// The index covers names only, exactly the bytes `Store::entry_name` returns.
/// Paths are not indexed; a `path:` term has to fall back to the scan engine
/// (or verify against a candidate set produced by other terms).
pub struct TrigramIndex {
  /// Number of entries the index was built over; drives the stop-gram rule.
  priv total : Int32
  /// 24-bit trigram keys, strictly ascending.
  priv keys : Array[UInt32]
  /// Postings parallel to `keys`.
  priv postings : Array[TrigramPosting]
  /// Sum of all posting lengths.
  priv posting_count : Int32
  /// Names shorter than three bytes. They carry no trigram; a needle of three
  /// bytes or more cannot match them, so they need no candidate list.
  priv short_names : Int32
  /// Keys whose posting exceeds the stop-gram threshold.
  priv stop_grams : Int32
}

///|
/// An empty index, for stores with no entries and for tests.
pub fn TrigramIndex::empty() -> TrigramIndex {
  {
    total: 0,
    keys: [],
    postings: [],
    posting_count: 0,
    short_names: 0,
    stop_grams: 0,
  }
}

///|
/// Build the trigram index for a finished store.
///
/// Both folders and files are indexed: a plain name term matches either kind,
/// and both share the store-wide id space. Names are visited in global id order
/// (folders first, then files), which makes every posting ascending.
///
/// A name contributes each distinct folded trigram once. Repeated windows such
/// as the `aaa` in `aaaa` would otherwise insert the same id twice and break the
/// `Ids` invariants this index relies on.
pub fn TrigramIndex::build(store : @core.Store) -> TrigramIndex {
  let total = store.entry_count()
  let folder_count = store.folder_count()
  let buckets : Map[UInt32, Array[Int32]] = Map([])
  let mut short_names = 0
  for id in 0..<folder_count {
    let name = store.entry_name(@core.EntryRef::new(@core.Folder, id))
    if name.length() < 3 {
      short_names = short_names + 1
    } else {
      index_name(buckets, name, id)
    }
  }
  for id in 0..<store.file_count() {
    let name = store.entry_name(@core.EntryRef::new(@core.File, id))
    if name.length() < 3 {
      short_names = short_names + 1
    } else {
      index_name(buckets, name, folder_count + id)
    }
  }
  let pairs = buckets.to_array()
  pairs.sort_by(fn(left, right) {
    left.0.reinterpret_as_int() - right.0.reinterpret_as_int()
  })
  let keys : Array[UInt32] = []
  let postings : Array[TrigramPosting] = []
  let mut posting_count = 0
  let mut stop_grams = 0
  for pair in pairs {
    let count = pair.1.length()
    keys.push(pair.0)
    postings.push({ ids: pair.1, })
    posting_count = posting_count + count
    if is_stop_gram_count(count, total) {
      stop_grams = stop_grams + 1
    }
  }
  { total, keys, postings, posting_count, short_names, stop_grams, }
}

///|
/// Append one name's distinct trigrams to their buckets.
fn index_name(
  buckets : Map[UInt32, Array[Int32]],
  name : BytesView,
  id : Int32,
) -> Unit {
  for key in name_trigrams(name) {
    match buckets.get(key) {
      Some(ids) => ids.push(id)
      None => buckets.set(key, [id])
    }
  }
}

///|
/// Distinct ASCII-folded trigram keys of a byte string, in ascending order.
///
/// Only ASCII letters are folded; every other byte, including multi-byte UTF-8,
/// is used as-is. A string shorter than three bytes has no key. Sorting plus
/// `dedup` makes the extraction independent of window order and removes the
/// repeated windows of names such as `aaaa`.
fn name_trigrams(name : BytesView) -> Array[UInt32] {
  let keys : Array[UInt32] = []
  let length = name.length()
  if length < 3 {
    return keys
  }
  let mut index = 0
  while index + 2 < length {
    keys.push(
      pack_trigram(
        @util.ascii_lower(name[index]),
        @util.ascii_lower(name[index + 1]),
        @util.ascii_lower(name[index + 2]),
      ),
    )
    index = index + 1
  }
  keys.sort_by(fn(left, right) {
    left.reinterpret_as_int() - right.reinterpret_as_int()
  })
  keys.dedup()
  keys
}

///|
/// Pack three bytes into a 24-bit key, most significant byte first.
fn pack_trigram(first : Byte, second : Byte, third : Byte) -> UInt32 {
  (first.to_uint() << 16) | (second.to_uint() << 8) | third.to_uint()
}

///|
/// Whether a posting of `count` ids is a stop-gram for an index of `total`
/// entries. Strictly greater than 20%: a posting that holds exactly a fifth of
/// the index is still kept.
fn is_stop_gram_count(count : Int32, total : Int32) -> Bool {
  total > 0 &&
  count.to_int64() * TRIGRAM_STOP_GRAM_DIVISOR.to_int64() > total.to_int64()
}

///|
/// One trigram lookup's result.
///
/// `candidates` is a superset of the entries whose name contains the needle, or
/// `None` when no posting can narrow the search and the caller must scan all
/// entries. A `Some` result, including the empty set, still needs a byte
/// verification per candidate: the index is a filter, not a matcher.
pub struct TrigramLookup {
  priv candidates : @ids.Ids?
  /// Postings actually intersected (at most `TRIGRAM_POSTING_LIMIT`).
  priv used_keys : Int32
  /// Required trigrams skipped because their posting is a stop-gram.
  priv stop_grams : Int32
  /// A required trigram has no posting, so the candidate set is certainly
  /// empty.
  priv missing : Bool
}

///|
/// Candidate entries for a name substring.
///
/// The needle is folded exactly like the indexed names. A case-sensitive query
/// can still use the lookup: folding only broadens the candidate set, and the
/// per-candidate byte comparison applies the real case rule.
///
/// Degradation is explicit:
///
/// - fewer than three bytes: no trigram exists, so `candidates()` is `None`;
/// - all required trigrams are stop-grams: `candidates()` is `None`;
/// - a required trigram is absent: the result is the empty candidate set;
/// - otherwise the shortest postings are intersected, at most
///   `TRIGRAM_POSTING_LIMIT` of them.
pub fn TrigramIndex::lookup(
  self : TrigramIndex,
  needle : BytesView,
) -> TrigramLookup {
  let required = name_trigrams(needle)
  if required.is_empty() {
    return { candidates: None, used_keys: 0, stop_grams: 0, missing: false, }
  }
  let usable : Array[(Int32, UInt32, Array[Int32])] = []
  let mut stop_grams = 0
  let mut missing = false
  for key in required {
    match self.posting(key) {
      None => missing = true
      Some(posting) => {
        let count = posting.len()
        if is_stop_gram_count(count, self.total) {
          stop_grams = stop_grams + 1
        } else {
          usable.push((count, key, posting.ids))
        }
      }
    }
  }
  if missing {
    return {
      candidates: Some(@ids.Ids::empty()),
      used_keys: 0,
      stop_grams,
      missing: true,
    }
  }
  if usable.is_empty() {
    return { candidates: None, used_keys: 0, stop_grams, missing: false, }
  }
  // Shortest first; the key breaks ties so the selection does not depend on
  // the sort implementation's stability.
  usable.sort_by(fn(left, right) {
    if left.0 != right.0 {
      left.0 - right.0
    } else {
      left.1.reinterpret_as_int() - right.1.reinterpret_as_int()
    }
  })
  let take = if usable.length() > TRIGRAM_POSTING_LIMIT {
    TRIGRAM_POSTING_LIMIT
  } else {
    usable.length()
  }
  let mut result = usable[0].2
  let mut used = 1
  while used < take && !result.is_empty() {
    result = posting_intersect(result, usable[used].2)
    used = used + 1
  }
  {
    candidates: Some(@ids.Ids::from_sorted(result, total=self.total)),
    used_keys: used,
    stop_grams,
    missing: false,
  }
}

///|
/// Candidate ids, or `None` when the caller must evaluate every entry.
pub fn TrigramLookup::candidates(self : TrigramLookup) -> @ids.Ids? {
  self.candidates
}

///|
/// Whether the lookup could not narrow the search at all.
pub fn TrigramLookup::is_full_scan(self : TrigramLookup) -> Bool {
  self.candidates is None
}

///|
/// Number of postings intersected. Zero for a full scan and for a missing
/// trigram.
pub fn TrigramLookup::key_count(self : TrigramLookup) -> Int32 {
  self.used_keys
}

///|
/// Number of required trigrams skipped as stop-grams.
pub fn TrigramLookup::stop_gram_count(self : TrigramLookup) -> Int32 {
  self.stop_grams
}

///|
/// Whether a required trigram was absent, which makes the result certainly
/// empty.
pub fn TrigramLookup::is_missing(self : TrigramLookup) -> Bool {
  self.missing
}

///|
/// Stable one-line description for `--explain`.
pub fn TrigramLookup::describe(self : TrigramLookup) -> String {
  if self.missing {
    "trigram: miss"
  } else {
    match self.candidates {
      Some(ids) =>
        "trigram: \{self.used_keys} keys, \{ids.cardinality()} candidate ids"
      None =>
        if self.stop_grams > 0 {
          "trigram: scan (\{self.stop_grams} stop-grams)"
        } else {
          "trigram: scan"
        }
    }
  }
}

///|
/// Number of entries the index covers.
pub fn TrigramIndex::entry_count(self : TrigramIndex) -> Int32 {
  self.total
}

///|
/// Number of distinct trigrams.
pub fn TrigramIndex::key_count(self : TrigramIndex) -> Int32 {
  self.keys.length()
}

///|
/// Total number of posting entries.
pub fn TrigramIndex::posting_count(self : TrigramIndex) -> Int32 {
  self.posting_count
}

///|
/// Number of names shorter than three bytes.
pub fn TrigramIndex::short_name_count(self : TrigramIndex) -> Int32 {
  self.short_names
}

///|
/// Number of keys whose posting is a stop-gram.
pub fn TrigramIndex::stop_gram_count(self : TrigramIndex) -> Int32 {
  self.stop_grams
}

///|
/// Bytes occupied by the posting arrays.
///
/// This is the in-memory estimate `--stats` prints; keys and per-posting
/// overhead are excluded. S12 replaces the arrays with delta-varint data on
/// disk.
pub fn TrigramIndex::posting_bytes(self : TrigramIndex) -> Int64 {
  self.posting_count.to_int64() * 4L
}

///|
/// The key at a sorted position, or `None` when out of range.
pub fn TrigramIndex::key_at(self : TrigramIndex, position : Int32) -> UInt32? {
  if position < 0 || position >= self.keys.length() {
    None
  } else {
    Some(self.keys[position])
  }
}

///|
/// The posting at a sorted position, or `None` when out of range.
pub fn TrigramIndex::posting_at(
  self : TrigramIndex,
  position : Int32,
) -> TrigramPosting? {
  if position < 0 || position >= self.postings.length() {
    None
  } else {
    Some(self.postings[position])
  }
}

///|
/// The posting of one key, or `None` when the trigram does not occur.
pub fn TrigramIndex::posting(
  self : TrigramIndex,
  key : UInt32,
) -> TrigramPosting? {
  let target = key.reinterpret_as_int()
  let mut low = 0
  let mut high = self.keys.length()
  while low < high {
    let middle = (low + high) / 2
    let current = self.keys[middle].reinterpret_as_int()
    if current < target {
      low = middle + 1
    } else if current > target {
      high = middle
    } else {
      return Some(self.postings[middle])
    }
  }
  None
}

///|
/// Intersect two ascending postings.
///
/// The shorter list drives the walk. When it is at least
/// `TRIGRAM_GALLOP_RATIO` times shorter, each probe gallops over the longer
/// list; otherwise a plain merge is cheaper. Both branches return an ascending,
/// duplicate-free array.
fn posting_intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
  let left_len = left.length()
  let right_len = right.length()
  if left_len == 0 || right_len == 0 {
    return []
  }
  let small = if left_len <= right_len { left } else { right }
  let large = if left_len <= right_len { right } else { left }
  if small.length().to_int64() * TRIGRAM_GALLOP_RATIO.to_int64() <
    large.length().to_int64() {
    galloping_intersect(small, large)
  } else {
    merge_intersect(small, large)
  }
}

///|
/// Merge two ascending lists of comparable lengths.
fn merge_intersect(left : Array[Int32], right : Array[Int32]) -> Array[Int32] {
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
/// Probe the large list with exponential search for every small-list id.
fn galloping_intersect(
  small : Array[Int32],
  large : Array[Int32],
) -> Array[Int32] {
  let result : Array[Int32] = []
  let length = large.length()
  let mut position = 0
  let mut index = 0
  while index < small.length() && position < length {
    let id = small[index]
    position = gallop_lower_bound(large, id, position)
    if position >= length {
      break
    }
    if large[position] == id {
      result.push(id)
      position = position + 1
    }
    index = index + 1
  }
  result
}

///|
/// First position at or after `from` whose value is `>= value`.
///
/// Positions before `from` are already known to be smaller, which is what lets
/// the intersection resume where the previous probe stopped. Returns `length`
/// when every remaining value is smaller.
fn gallop_lower_bound(ids : Array[Int32], value : Int32, from : Int32) -> Int32 {
  let length = ids.length()
  let base = if from < 0 { 0 } else { from }
  if base >= length {
    return length
  }
  if ids[base] >= value {
    return base
  }
  let limit = length - base
  let mut step = 1
  while step < limit && ids[base + step] < value {
    if step > limit / 2 {
      step = limit
    } else {
      step = step * 2
    }
  }
  let mut low = base + 1
  let mut high = if step < limit { base + step + 1 } else { length }
  while low < high {
    let middle = low + (high - low) / 2
    if ids[middle] < value {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low
}
