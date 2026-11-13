///|
/// One numeric field that is indexed as a sorted `(value, id)` array.
///
/// These are the fields whose values rarely repeat and whose queries are range
/// or equality comparisons. Extensions, kinds, and other low-cardinality fields
/// belong to `Dict` instead: one bitmap per value there, one sorted array here.
pub(all) enum RangeField {
  /// File size in bytes, or summed subtree size for a folder.
  Size
  /// Modification time in Unix seconds.
  MTime
  /// Folder depth: roots are 0, their direct children 1.
  Depth
  /// Direct child count, folders only.
  ChildCount
  /// Parent folder id, a high-cardinality equality field.
  Parent
}

///|
/// Stable name used by `--fast-fields`, stats, and `--explain`.
pub fn RangeField::name(self : RangeField) -> String {
  match self {
    Size => "size"
    MTime => "mtime"
    Depth => "depth"
    ChildCount => "childcount"
    Parent => "parent"
  }
}

///|
/// Every range field, in build order.
pub fn RangeField::all() -> Array[RangeField] {
  [Size, MTime, Depth, ChildCount, Parent]
}

///|
/// Resolve a field name. `dm` is accepted as an alias of `mtime` and
/// `children` as an alias of `childcount`; matching folds ASCII case.
pub fn RangeField::from_name(name : StringView) -> RangeField? {
  let folded = @util.ascii_fold(@utf8.encode(name))
  if @util.eq_bytes(folded[:], b"size"[:], false) {
    Some(Size)
  } else if @util.eq_bytes(folded[:], b"mtime"[:], false) ||
    @util.eq_bytes(folded[:], b"dm"[:], false) {
    Some(MTime)
  } else if @util.eq_bytes(folded[:], b"depth"[:], false) {
    Some(Depth)
  } else if @util.eq_bytes(folded[:], b"childcount"[:], false) ||
    @util.eq_bytes(folded[:], b"children"[:], false) {
    Some(ChildCount)
  } else if @util.eq_bytes(folded[:], b"parent"[:], false) {
    Some(Parent)
  } else {
    None
  }
}

///|
/// The bit that represents one field in a `RangeFieldSet`.
fn range_field_bit(field : RangeField) -> UInt32 {
  match field {
    Size => 0x01U
    MTime => 0x02U
    Depth => 0x04U
    ChildCount => 0x08U
    Parent => 0x10U
  }
}

///|
/// A small set of `RangeField` values.
///
/// `--fast-fields` selects the fields that are built eagerly. The remaining
/// fields are still available: they are built from the store on first use, so
/// startup work and memory follow the fields a workload actually queries.
pub struct RangeFieldSet {
  priv bits : UInt32
}

///|
/// The empty selection.
pub fn RangeFieldSet::empty() -> RangeFieldSet {
  { bits: 0U, }
}

///|
/// Every field. This is the library default; the CLI default is `size,mtime`.
pub fn RangeFieldSet::all() -> RangeFieldSet {
  { bits: 0x1FU, }
}

///|
/// A selection containing one field.
pub fn RangeFieldSet::single(field : RangeField) -> RangeFieldSet {
  { bits: range_field_bit(field), }
}

///|
/// Build a selection from a list of fields.
pub fn RangeFieldSet::of(fields : Array[RangeField]) -> RangeFieldSet {
  let mut bits = 0U
  for field in fields {
    bits = bits | range_field_bit(field)
  }
  { bits, }
}

///|
/// Whether the field is selected.
pub fn RangeFieldSet::contains(
  self : RangeFieldSet,
  field : RangeField,
) -> Bool {
  (self.bits & range_field_bit(field)) != 0U
}

///|
/// Union of two selections.
pub fn RangeFieldSet::union(
  self : RangeFieldSet,
  other : RangeFieldSet,
) -> RangeFieldSet {
  { bits: self.bits | other.bits, }
}

///|
/// Whether no field is selected.
pub fn RangeFieldSet::is_empty(self : RangeFieldSet) -> Bool {
  self.bits == 0U
}

///|
/// Number of selected fields.
pub fn RangeFieldSet::size(self : RangeFieldSet) -> Int32 {
  let mut count = 0
  for field in RangeField::all() {
    if self.contains(field) {
      count = count + 1
    }
  }
  count
}

///|
/// Comma-separated names in `RangeField::all` order, e.g. `size,mtime`.
pub fn RangeFieldSet::describe(self : RangeFieldSet) -> String {
  let names : Array[String] = []
  for field in RangeField::all() {
    if self.contains(field) {
      names.push(field.name())
    }
  }
  names.join(",")
}

///|
/// Parse a comma-separated field list such as `size,mtime`.
///
/// Spaces around names are ignored, an empty list selects nothing, and an
/// unknown name is an error the CLI can print verbatim.
pub fn RangeFieldSet::parse(text : StringView) -> Result[RangeFieldSet, String] {
  let mut set = RangeFieldSet::empty()
  let trimmed = text.trim()
  if trimmed.is_empty() {
    return Ok(set)
  }
  for part in trimmed.split(",") {
    let name = part.trim()
    if name.is_empty() {
      return Err(
        "empty range field; expected size, mtime, depth, childcount, or parent",
      )
    }
    match RangeField::from_name(name) {
      Some(field) => set = set.union(RangeFieldSet::single(field))
      None =>
        return Err(
          "unknown range field '\{name}'; expected size, mtime, depth, childcount, or parent",
        )
    }
  }
  Ok(set)
}

///|
/// A numeric field stored as two parallel arrays sorted by `(value, id)`.
///
/// The arrays are the whole index: `values[i]` is the field value of entry
/// `ids[i]`, ascending by value and then by id, so equal values form a
/// contiguous run with ascending ids. A query is two binary searches plus a
/// slice, never a walk over the entries.
///
/// `total` is the index-wide entry count and only drives the `Ids` shape
/// decision: a range that covers a large share of the index becomes a bitmap,
/// while a narrow range stays a sorted array. It does not limit the ids.
pub struct RangeIndex {
  priv values : Array[Int64]
  priv ids : Array[Int32]
  priv total : Int32
}

///|
/// An index with no entries.
pub fn RangeIndex::empty() -> RangeIndex {
  { values: [], ids: [], total: 0, }
}

///|
/// Build an index from `(value, id)` pairs.
///
/// Pairs are copied, then sorted by value and, for equal values, by id. The
/// input order is irrelevant and duplicate ids are kept as given: callers pass
/// each entry once.
pub fn RangeIndex::build(
  entries : Array[(Int64, Int32)],
  total~ : Int32 = 0,
) -> RangeIndex {
  let sorted = entries.copy()
  sorted.sort_by(fn(left, right) {
    let value_order = if left.0 < right.0 {
      -1
    } else if left.0 > right.0 {
      1
    } else {
      0
    }
    if value_order != 0 {
      value_order
    } else {
      left.1 - right.1
    }
  })
  let values : Array[Int64] = []
  let ids : Array[Int32] = []
  for pair in sorted {
    values.push(pair.0)
    ids.push(pair.1)
  }
  { values, ids, total, }
}

///|
/// Wrap two arrays the caller already sorted by `(value, id)`.
///
/// Only the counting-sort builder uses this: its buckets are emitted in parent
/// id order with ids appended in input order, which is exactly the invariant.
fn range_index_partitioned(
  values : Array[Int64],
  ids : Array[Int32],
  total : Int32,
) -> RangeIndex {
  { values, ids, total, }
}

///|
/// Number of entries in the index.
pub fn RangeIndex::len(self : RangeIndex) -> Int32 {
  self.values.length()
}

///|
/// Whether the index has no entries.
pub fn RangeIndex::is_empty(self : RangeIndex) -> Bool {
  self.values.length() == 0
}

///|
/// The value at a sorted position, or `None` when out of range.
pub fn RangeIndex::value_at(self : RangeIndex, position : Int32) -> Int64? {
  if position < 0 || position >= self.values.length() {
    None
  } else {
    Some(self.values[position])
  }
}

///|
/// The entry id at a sorted position, or `None` when out of range.
pub fn RangeIndex::id_at(self : RangeIndex, position : Int32) -> Int32? {
  if position < 0 || position >= self.ids.length() {
    None
  } else {
    Some(self.ids[position])
  }
}

///|
/// Values in ascending `(value, id)` order, for diagnostics and tests.
pub fn RangeIndex::values(self : RangeIndex) -> ArrayView[Int64] {
  self.values
}

///|
/// Ids in ascending `(value, id)` order, for diagnostics and tests.
pub fn RangeIndex::ids(self : RangeIndex) -> ArrayView[Int32] {
  self.ids
}

///|
/// First position whose value is `>= value`.
///
/// This is the lower edge of a half-open range. The result is in
/// `0 ..= len`, so callers can slice without a separate bounds check.
pub fn RangeIndex::lower_bound(self : RangeIndex, value : Int64) -> Int32 {
  let mut low = 0
  let mut high = self.values.length()
  while low < high {
    let middle = (low + high) / 2
    if self.values[middle] < value {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low
}

///|
/// First position whose value is `> value`.
///
/// This is the upper edge of a half-open range and the end of the run of
/// entries equal to `value`.
pub fn RangeIndex::upper_bound(self : RangeIndex, value : Int64) -> Int32 {
  let mut low = 0
  let mut high = self.values.length()
  while low < high {
    let middle = (low + high) / 2
    if self.values[middle] <= value {
      low = middle + 1
    } else {
      high = middle
    }
  }
  low
}

///|
/// Ids in the positions `[start, end)`.
///
/// The slice is sorted by value, not by id, so the result is canonicalized:
/// ids come back ascending exactly as `Ids` requires. Out-of-range positions
/// are clamped, which lets every range operator reuse this one function.
pub fn RangeIndex::slice(
  self : RangeIndex,
  start : Int32,
  end : Int32,
) -> @ids.Ids {
  let length = self.values.length()
  let lo = if start < 0 { 0 } else if start > length { length } else { start }
  let hi = if end < 0 { 0 } else if end > length { length } else { end }
  if lo >= hi {
    return @ids.Ids::empty()
  }
  let ids : Array[Int32] = []
  for position in lo..<hi {
    ids.push(self.ids[position])
  }
  @ids.Ids::from_sorted(ids, total=self.total)
}

///|
/// Ids whose value is in the half-open interval `[lo, hi)`.
///
/// An empty or inverted interval selects nothing. This is the form `size:a..b`
/// and `dm:a..b` compile to.
pub fn RangeIndex::range(self : RangeIndex, lo : Int64, hi : Int64) -> @ids.Ids {
  if lo >= hi {
    return @ids.Ids::empty()
  }
  self.slice(self.lower_bound(lo), self.lower_bound(hi))
}

///|
/// Ids whose value equals `value`.
///
/// Every entry in the run of equal values is returned; duplicate values are the
/// common case (many files share a size or a date).
pub fn RangeIndex::equal(self : RangeIndex, value : Int64) -> @ids.Ids {
  self.slice(self.lower_bound(value), self.upper_bound(value))
}

///|
/// Ids whose value is `>= value`.
pub fn RangeIndex::at_least(self : RangeIndex, value : Int64) -> @ids.Ids {
  self.slice(self.lower_bound(value), self.values.length())
}

///|
/// Ids whose value is `> value`.
pub fn RangeIndex::greater_than(self : RangeIndex, value : Int64) -> @ids.Ids {
  self.slice(self.upper_bound(value), self.values.length())
}

///|
/// Ids whose value is `<= value`.
pub fn RangeIndex::at_most(self : RangeIndex, value : Int64) -> @ids.Ids {
  self.slice(0, self.upper_bound(value))
}

///|
/// Ids whose value is `< value`.
pub fn RangeIndex::less_than(self : RangeIndex, value : Int64) -> @ids.Ids {
  self.slice(0, self.lower_bound(value))
}

///|
/// Folder paths in ascending byte order, paired with their folder ids.
///
/// `parent:` names a directory by path while the parent range index stores
/// folder ids, so this table is the translation. It is built together with the
/// parent index, and only then: it duplicates path bytes that the name pool
/// already holds.
priv struct ParentPaths {
  paths : Array[Bytes]
  ids : Array[Int32]
}

///|
/// Build the path-to-folder table.
///
/// Equal paths cannot occur for a well-formed store (roots are deduplicated and
/// every other folder has a distinct parent and name); the id tie-break keeps
/// the order deterministic even for a hand-built store.
fn build_parent_paths(store : @core.Store) -> ParentPaths {
  let pairs : Array[(Bytes, Int32)] = []
  for id in 0..<store.folder_count() {
    pairs.push((store.folder_path(id), id))
  }
  pairs.sort_by(fn(left, right) {
    let order = left.0[:].lexical_compare(right.0[:])
    if order != 0 {
      order
    } else {
      left.1 - right.1
    }
  })
  let paths : Array[Bytes] = []
  let ids : Array[Int32] = []
  for pair in pairs {
    paths.push(pair.0)
    ids.push(pair.1)
  }
  { paths, ids, }
}

///|
/// Folder id of an exact path, or `None` when no folder has that path.
fn ParentPaths::lookup(self : ParentPaths, path : BytesView) -> Int32? {
  let mut low = 0
  let mut high = self.paths.length()
  while low < high {
    let middle = (low + high) / 2
    let order = self.paths[middle][:].lexical_compare(path)
    if order < 0 {
      low = middle + 1
    } else if order > 0 {
      high = middle
    } else {
      return Some(self.ids[middle])
    }
  }
  None
}

///|
/// The five default range indexes of one store.
///
/// Construction builds the fields selected by `eager` and leaves the rest
/// unbuilt. A field is materialized on first access and cached, so a query that
/// never uses `depth:` does not pay for it, while repeated queries do not
/// rebuild it.
///
/// The builder owns a `Store` value (which shares its arrays; it does not copy
/// them) so lazy fields can be derived without another scan.
pub struct Ranges {
  priv store : @core.Store
  priv total : Int32
  priv eager : RangeFieldSet
  priv mut size_index : RangeIndex?
  priv mut mtime_index : RangeIndex?
  priv mut depth_index : RangeIndex?
  priv mut child_count_index : RangeIndex?
  priv mut parent_index : RangeIndex?
  priv mut parent_paths : ParentPaths?
}

///|
/// Build the range indexes for a finished store.
///
/// `eager` defaults to every field, which is what tests and library callers
/// want. The CLI passes `--fast-fields` (default `size,mtime`): the other
/// fields stay unbuilt until a query needs them.
pub fn Ranges::build(
  store : @core.Store,
  eager~ : RangeFieldSet = RangeFieldSet::all(),
) -> Ranges {
  let total = store.entry_count()
  let size_index = if eager.contains(Size) {
    Some(build_size(store, total))
  } else {
    None
  }
  let mtime_index = if eager.contains(MTime) {
    Some(build_mtime(store, total))
  } else {
    None
  }
  let depth_index = if eager.contains(Depth) {
    Some(build_depth(store, total))
  } else {
    None
  }
  let child_count_index = if eager.contains(ChildCount) {
    Some(build_child_count(store, total))
  } else {
    None
  }
  let parent_index = if eager.contains(Parent) {
    Some(build_parent(store, total))
  } else {
    None
  }
  let parent_paths = if parent_index is Some(_) {
    Some(build_parent_paths(store))
  } else {
    None
  }
  {
    store,
    total,
    eager,
    size_index,
    mtime_index,
    depth_index,
    child_count_index,
    parent_index,
    parent_paths,
  }
}

///|
/// Build the size index over files and folders.
fn build_size(store : @core.Store, total : Int32) -> RangeIndex {
  let entries : Array[(Int64, Int32)] = []
  let folder_count = store.folder_count()
  for id in 0..<folder_count {
    match store.folder(id) {
      Some(folder) => entries.push((folder.size(), id))
      None => ()
    }
  }
  for id in 0..<store.file_count() {
    match store.file(id) {
      Some(file) => entries.push((file.size(), folder_count + id))
      None => ()
    }
  }
  RangeIndex::build(entries, total~)
}

///|
/// Build the modification-time index over files and folders.
fn build_mtime(store : @core.Store, total : Int32) -> RangeIndex {
  let entries : Array[(Int64, Int32)] = []
  let folder_count = store.folder_count()
  for id in 0..<folder_count {
    match store.folder(id) {
      Some(folder) => entries.push((folder.mtime(), id))
      None => ()
    }
  }
  for id in 0..<store.file_count() {
    match store.file(id) {
      Some(file) => entries.push((file.mtime(), folder_count + id))
      None => ()
    }
  }
  RangeIndex::build(entries, total~)
}

///|
/// Build the depth index over files and folders.
///
/// Folder depth is memoized in one upward pass; files take their parent's depth
/// plus one. This reproduces `entry_depth` in the scan engine without walking
/// the parent chain once per entry.
fn build_depth(store : @core.Store, total : Int32) -> RangeIndex {
  let folder_count = store.folder_count()
  let depths : Array[Int32] = Array::makei(folder_count, fn(_) { -1 })
  for id in 0..<folder_count {
    ignore(resolve_folder_depth(store, depths, id, folder_count))
  }
  let entries : Array[(Int64, Int32)] = []
  for id in 0..<folder_count {
    entries.push((depths[id].to_int64(), id))
  }
  for id in 0..<store.file_count() {
    let depth = match store.file(id) {
      Some(file) => {
        let parent = file.parent()
        if parent >= 0 && parent < folder_count {
          depths[parent] + 1
        } else {
          0
        }
      }
      None => 0
    }
    entries.push((depth.to_int64(), folder_count + id))
  }
  RangeIndex::build(entries, total~)
}

///|
/// Fill in the depth of `id` and every ancestor that is not resolved yet.
///
/// The stack keeps the walk iterative. A chain longer than the folder count can
/// only come from a corrupted parent cycle; it is cut off and treated as a root
/// instead of looping forever. For a well-formed store this is exact.
fn resolve_folder_depth(
  store : @core.Store,
  depths : Array[Int32],
  id : Int32,
  folder_count : Int32,
) -> Int32 {
  if id < 0 || id >= folder_count {
    return -1
  }
  if depths[id] >= 0 {
    return depths[id]
  }
  let chain : Array[Int32] = []
  let mut current = id
  while current >= 0 &&
        current < folder_count &&
        depths[current] < 0 &&
        chain.length() <= folder_count {
    chain.push(current)
    current = match store.folder(current) {
      Some(folder) => folder.parent()
      None => -1
    }
  }
  let base = if current >= 0 && current < folder_count && depths[current] >= 0 {
    depths[current]
  } else {
    -1
  }
  let mut depth = base + 1
  let mut position = chain.length() - 1
  while position >= 0 {
    depths[chain[position]] = depth
    depth = depth + 1
    position = position - 1
  }
  depths[id]
}

///|
/// Build the direct-child-count index. Files are excluded: the scan engine's
/// `childcount:` never matches a file.
fn build_child_count(store : @core.Store, total : Int32) -> RangeIndex {
  let entries : Array[(Int64, Int32)] = []
  for id in 0..<store.folder_count() {
    match store.folder(id) {
      Some(folder) => entries.push((folder.child_count().to_int64(), id))
      None => ()
    }
  }
  RangeIndex::build(entries, total~)
}

///|
/// Build the parent index with a counting sort instead of a comparison sort.
///
/// The value of an entry is its parent folder id, so the key space is exactly
/// the folder ids: one bucket per folder. Counting pass, prefix sums, then one
/// append per entry in id order. Entries with no parent (roots) never enter the
/// index, which matches `parent:` never matching a root.
fn build_parent(store : @core.Store, total : Int32) -> RangeIndex {
  let folder_count = store.folder_count()
  let counts : Array[Int32] = Array::makei(folder_count, fn(_) { 0 })
  let mut included = 0
  for id in 0..<folder_count {
    let parent = match store.folder(id) {
      Some(folder) => folder.parent()
      None => -1
    }
    if parent >= 0 && parent < folder_count {
      counts[parent] = counts[parent] + 1
      included = included + 1
    }
  }
  for id in 0..<store.file_count() {
    let parent = match store.file(id) {
      Some(file) => file.parent()
      None => -1
    }
    if parent >= 0 && parent < folder_count {
      counts[parent] = counts[parent] + 1
      included = included + 1
    }
  }
  let starts : Array[Int32] = Array::makei(folder_count, fn(_) { 0 })
  let mut offset = 0
  for parent in 0..<folder_count {
    starts[parent] = offset
    offset = offset + counts[parent]
  }
  let next = starts.copy()
  let ids : Array[Int32] = Array::makei(included, fn(_) { 0 })
  for id in 0..<folder_count {
    let parent = match store.folder(id) {
      Some(folder) => folder.parent()
      None => -1
    }
    if parent >= 0 && parent < folder_count {
      ids[next[parent]] = id
      next[parent] = next[parent] + 1
    }
  }
  for id in 0..<store.file_count() {
    let parent = match store.file(id) {
      Some(file) => file.parent()
      None => -1
    }
    if parent >= 0 && parent < folder_count {
      let global = folder_count + id
      ids[next[parent]] = global
      next[parent] = next[parent] + 1
    }
  }
  let values : Array[Int64] = []
  for parent in 0..<folder_count {
    let count = counts[parent]
    if count > 0 {
      for _ in 0..<count {
        values.push(parent.to_int64())
      }
    }
  }
  range_index_partitioned(values, ids, total)
}

///|
/// Number of entries the indexes were built over.
pub fn Ranges::entry_count(self : Ranges) -> Int32 {
  self.total
}

///|
/// The fields selected for eager construction.
pub fn Ranges::eager_fields(self : Ranges) -> RangeFieldSet {
  self.eager
}

///|
/// Whether a field is already built. A lazy field flips to `true` on first
/// access; `--stats` uses this to report only the work that actually happened.
pub fn Ranges::is_loaded(self : Ranges, field : RangeField) -> Bool {
  match field {
    Size => self.size_index is Some(_)
    MTime => self.mtime_index is Some(_)
    Depth => self.depth_index is Some(_)
    ChildCount => self.child_count_index is Some(_)
    Parent => self.parent_index is Some(_)
  }
}

///|
/// The size index, built on first use when it was not eager.
pub fn Ranges::size(self : Ranges) -> RangeIndex {
  match self.size_index {
    Some(index) => index
    None => {
      let index = build_size(self.store, self.total)
      self.size_index = Some(index)
      index
    }
  }
}

///|
/// The modification-time index, built on first use when it was not eager.
pub fn Ranges::mtime(self : Ranges) -> RangeIndex {
  match self.mtime_index {
    Some(index) => index
    None => {
      let index = build_mtime(self.store, self.total)
      self.mtime_index = Some(index)
      index
    }
  }
}

///|
/// The depth index, built on first use when it was not eager.
pub fn Ranges::depth(self : Ranges) -> RangeIndex {
  match self.depth_index {
    Some(index) => index
    None => {
      let index = build_depth(self.store, self.total)
      self.depth_index = Some(index)
      index
    }
  }
}

///|
/// The direct-child-count index, built on first use when it was not eager.
pub fn Ranges::child_count(self : Ranges) -> RangeIndex {
  match self.child_count_index {
    Some(index) => index
    None => {
      let index = build_child_count(self.store, self.total)
      self.child_count_index = Some(index)
      index
    }
  }
}

///|
/// The parent index, built on first use when it was not eager.
pub fn Ranges::parent(self : Ranges) -> RangeIndex {
  match self.parent_index {
    Some(index) => index
    None => {
      let index = build_parent(self.store, self.total)
      self.parent_index = Some(index)
      index
    }
  }
}

///|
/// The path-to-folder table, built together with the parent index.
fn Ranges::parent_paths(self : Ranges) -> ParentPaths {
  match self.parent_paths {
    Some(paths) => paths
    None => {
      let paths = build_parent_paths(self.store)
      self.parent_paths = Some(paths)
      paths
    }
  }
}

///|
/// One field by enum, building it when needed.
pub fn Ranges::field(self : Ranges, field : RangeField) -> RangeIndex {
  match field {
    Size => self.size()
    MTime => self.mtime()
    Depth => self.depth()
    ChildCount => self.child_count()
    Parent => self.parent()
  }
}

///|
/// Folder id of an exact directory path, or `None` when the path is not in the
/// index. This is the lookup `parent:<path>` compiles to.
pub fn Ranges::parent_of(self : Ranges, path : BytesView) -> Int32? {
  self.parent_paths().lookup(path)
}

///|
/// Entries whose parent folder has exactly this path.
///
/// Roots have no parent and are never selected. A path that names no folder
/// yields the empty set, matching the scan predicate.
pub fn Ranges::parent_ids(self : Ranges, path : BytesView) -> @ids.Ids {
  match self.parent_of(path) {
    Some(folder) => self.parent().equal(folder.to_int64())
    None => @ids.Ids::empty()
  }
}
