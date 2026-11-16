///|
/// Result order selected by `--sort`.
///
/// `Name` is the canonical order the store builds once: natural name order,
/// then full path. Every other key is computed per query over the matched set,
/// with the canonical order as the deterministic tie-breaker.
pub(all) enum SortKey {
  Name
  Path
  Size
  MTime
  Ext
  Type
}

///|
/// Stable name of a sort key, as printed in help and error messages.
pub fn SortKey::name(self : SortKey) -> String {
  match self {
    Name => "name"
    Path => "path"
    Size => "size"
    MTime => "mtime"
    Ext => "ext"
    Type => "type"
  }
}

///|
/// Every sort key in help order.
pub fn SortKey::all() -> Array[SortKey] {
  [Name, Path, Size, MTime, Ext, Type]
}

///|
/// Parse a sort key name, ASCII case-insensitively.
pub fn SortKey::from_name(text : StringView) -> SortKey? {
  let bytes = @utf8.encode(text)
  if @util.eq_ignore_ascii_case(bytes[:], b"name"[:]) {
    Some(Name)
  } else if @util.eq_ignore_ascii_case(bytes[:], b"path"[:]) {
    Some(Path)
  } else if @util.eq_ignore_ascii_case(bytes[:], b"size"[:]) {
    Some(Size)
  } else if @util.eq_ignore_ascii_case(bytes[:], b"mtime"[:]) {
    Some(MTime)
  } else if @util.eq_ignore_ascii_case(bytes[:], b"ext"[:]) {
    Some(Ext)
  } else if @util.eq_ignore_ascii_case(bytes[:], b"type"[:]) {
    Some(Type)
  } else {
    None
  }
}

///|
/// How to order and limit the matched entries.
///
/// `limit` is applied after ordering, so `--sort size -n 20` keeps the twenty
/// smallest matches, not the twenty smallest entries in canonical order. A
/// non-positive limit means unlimited.
pub(all) struct OrderOptions {
  key : SortKey
  reverse : Bool
  folders_first : Bool
  limit : Int32
}

///|
/// Build order options.
pub fn OrderOptions::new(
  key~ : SortKey = Name,
  reverse~ : Bool = false,
  folders_first~ : Bool = false,
  limit~ : Int32 = 0,
) -> OrderOptions {
  { key, reverse, folders_first, limit: if limit < 0 { 0 } else { limit }, }
}

///|
/// Whether the engine can produce the final order directly.
///
/// True for `name` without `--folders-first`: forward walks the canonical order
/// from the start, `--reverse` walks it from the end, and both stop at `limit`.
/// When this is true the caller must not call `order_hits`, which would sort
/// the already-final hits forward. Folder grouping and every other key need the
/// whole match set first.
pub fn OrderOptions::streams_name_order(self : OrderOptions) -> Bool {
  match self.key {
    Name => !self.folders_first
    _ => false
  }
}

///|
/// Order matches and apply the limit.
///
/// The input must be in canonical order, which is what both engines produce.
/// Plain name order keeps that order and only truncates, so it preserves the
/// engine's early stop. `--folders-first` groups folders before files and then
/// orders each group; `--reverse` reverses within the groups.
pub fn order_hits(
  store : @core.Store,
  hits : Array[@core.EntryRef],
  options : OrderOptions,
) -> Array[@core.EntryRef] {
  if hits.is_empty() {
    return hits
  }
  let plain_name_order = match options.key {
    Name => !options.reverse
    _ => false
  }
  if !options.folders_first && plain_name_order {
    return take_hits(hits, options.limit)
  }
  if !options.folders_first {
    return order_group(store, hits, options)
  }
  let folders : Array[@core.EntryRef] = []
  let files : Array[@core.EntryRef] = []
  for hit in hits {
    if hit.is_file() {
      files.push(hit)
    } else {
      folders.push(hit)
    }
  }
  let folder_hits = order_group(store, folders, options)
  if options.limit > 0 && folder_hits.length() >= options.limit {
    return folder_hits
  }
  let remaining = if options.limit > 0 {
    options.limit - folder_hits.length()
  } else {
    0
  }
  let file_options = OrderOptions::new(
    key=options.key,
    reverse=options.reverse,
    limit=remaining,
  )
  let file_hits = order_group(store, files, file_options)
  for hit in file_hits {
    folder_hits.push(hit)
  }
  folder_hits
}

///|
/// First `limit` matches, or the input itself when it already fits.
fn take_hits(
  hits : Array[@core.EntryRef],
  limit : Int32,
) -> Array[@core.EntryRef] {
  if limit <= 0 || hits.length() <= limit {
    return hits
  }
  let result : Array[@core.EntryRef] = []
  let mut index = 0
  while index < limit {
    result.push(hits[index])
    index = index + 1
  }
  result
}

///|
/// One entry plus the precomputed values its sort key needs.
///
/// Building these once per match avoids rebuilding paths and folded extensions
/// inside every comparison.
priv struct SortItem {
  entry : @core.EntryRef
  path : Bytes?
  ext : Bytes?
  type_rank : Int32
}

///|
/// Order one group of matches. The input may be any subset of the canonical
/// order; the comparator is a total order, so the result is deterministic.
fn order_group(
  store : @core.Store,
  hits : Array[@core.EntryRef],
  options : OrderOptions,
) -> Array[@core.EntryRef] {
  if hits.is_empty() {
    return hits
  }
  let items = build_sort_items(store, hits, options.key)
  let compare = fn(left : SortItem, right : SortItem) -> Int32 {
    let order = compare_items(store, left, right, options.key)
    if options.reverse {
      -order
    } else {
      order
    }
  }
  let ordered = if options.limit > 0 && options.limit < items.length() {
    select_top_k(items, options.limit, compare)
  } else {
    items.sort_by(compare)
    items
  }
  let result : Array[@core.EntryRef] = []
  for item in ordered {
    result.push(item.entry)
  }
  result
}

///|
/// Precompute the values one sort key compares.
fn build_sort_items(
  store : @core.Store,
  hits : Array[@core.EntryRef],
  key : SortKey,
) -> Array[SortItem] {
  let items : Array[SortItem] = []
  let categories = match key {
    Type => Some(type_category_map())
    _ => None
  }
  for entry in hits {
    let path = match key {
      Path => Some(store.entry_path(entry))
      _ => None
    }
    let ext = match key {
      Ext | Type => Some(@util.ascii_fold(store.entry_extension(entry)))
      _ => None
    }
    let type_rank = if key is Type {
      if entry.is_folder() {
        0
      } else {
        match ext {
          Some(ext) => type_rank_of(ext[:], categories.unwrap())
          None => 7
        }
      }
    } else {
      0
    }
    items.push({ entry, path, ext, type_rank, })
  }
  items
}

///|
/// Type ordering rank: folders first, then the built-in categories in their
/// stable order, then files without a known category.
fn type_rank_of(
  ext : BytesView,
  categories : Map[Bytes, @util.TypeCategory],
) -> Int32 {
  match categories.get_from_bytes(ext) {
    Some(category) => category.index() + 1
    None => 7
  }
}

///|
/// Extension → category lookup built once per type-ordered query.
fn type_category_map() -> Map[Bytes, @util.TypeCategory] {
  let map : Map[Bytes, @util.TypeCategory] = Map([])
  for category in @util.TypeCategory::all() {
    for extension in category.extensions() {
      map.set(@utf8.encode(extension[:]), category)
    }
  }
  map
}

///|
/// Compare two prepared items by the primary key, falling back to canonical
/// order so equal keys never depend on the input order.
fn compare_items(
  store : @core.Store,
  left : SortItem,
  right : SortItem,
  key : SortKey,
) -> Int32 {
  let primary = match key {
    Name => compare_canonical(store, left.entry, right.entry)
    Path => @util.cmp_paths(left.path.unwrap()[:], right.path.unwrap()[:])
    Size =>
      compare_int64(size_of(store, left.entry), size_of(store, right.entry))
    MTime =>
      compare_int64(mtime_of(store, left.entry), mtime_of(store, right.entry))
    Ext => compare_lexical(left.ext.unwrap()[:], right.ext.unwrap()[:])
    Type => {
      let order = compare_int32(left.type_rank, right.type_rank)
      if order != 0 {
        order
      } else {
        compare_lexical(left.ext.unwrap()[:], right.ext.unwrap()[:])
      }
    }
  }
  match key {
    Name => primary
    _ =>
      if primary != 0 {
        primary
      } else {
        compare_canonical(store, left.entry, right.entry)
      }
  }
}

///|
/// Canonical comparison: natural name order, then path, then the store-wide id.
///
/// This is the same order the store builds for `--sort name`; the id makes the
/// order total even when two roots produce the same path.
fn compare_canonical(
  store : @core.Store,
  left : @core.EntryRef,
  right : @core.EntryRef,
) -> Int32 {
  let name_order = @util.cmp_paths(
    store.entry_name(left),
    store.entry_name(right),
  )
  if name_order != 0 {
    return name_order
  }
  let path_order = @util.cmp_paths(
    store.entry_path(left)[:],
    store.entry_path(right)[:],
  )
  if path_order != 0 {
    return path_order
  }
  compare_int32(store.global_id(left), store.global_id(right))
}

///|
/// Entry size, or zero for an out-of-range reference.
fn size_of(store : @core.Store, entry : @core.EntryRef) -> Int64 {
  match store.entry_size(entry) {
    Some(value) => value
    None => 0L
  }
}

///|
/// Entry modification time, or zero for an out-of-range reference.
fn mtime_of(store : @core.Store, entry : @core.EntryRef) -> Int64 {
  match store.entry_mtime(entry) {
    Some(value) => value
    None => 0L
  }
}

///|
/// Three-way comparison of two integers.
fn compare_int32(left : Int32, right : Int32) -> Int32 {
  if left < right {
    -1
  } else if left > right {
    1
  } else {
    0
  }
}

///|
/// Three-way comparison of two 64-bit integers.
fn compare_int64(left : Int64, right : Int64) -> Int32 {
  if left < right {
    -1
  } else if left > right {
    1
  } else {
    0
  }
}

///|
/// Three-way comparison of two byte strings in lexicographic order.
///
/// `BytesView` comparison is shortlex, which would put `ab` before `a`; sort
/// keys and output order need plain lexicographic order.
fn compare_lexical(left : BytesView, right : BytesView) -> Int32 {
  let order = left.lexical_compare(right)
  if order < 0 {
    -1
  } else if order > 0 {
    1
  } else {
    0
  }
}

///|
/// Keep the `k` smallest items under `compare` and return them in ascending
/// order.
///
/// The heap root is the worst kept item, so a new item only costs a comparison
/// when it beats the current worst. This is the top-K path for
/// `--sort size -n 20` on a large match set.
fn select_top_k(
  items : Array[SortItem],
  k : Int32,
  compare : (SortItem, SortItem) -> Int32,
) -> Array[SortItem] {
  let heap : Array[SortItem] = []
  for item in items {
    if heap.length() < k {
      heap.push(item)
      sift_up(heap, heap.length() - 1, compare)
    } else if compare(item, heap[0]) < 0 {
      heap[0] = item
      sift_down(heap, 0, compare)
    }
  }
  heap.sort_by(compare)
  heap
}

///|
/// Restore the max-heap property after appending at `index`.
fn sift_up(
  heap : Array[SortItem],
  index : Int32,
  compare : (SortItem, SortItem) -> Int32,
) -> Unit {
  let mut current = index
  while current > 0 {
    let parent = (current - 1) / 2
    if compare(heap[current], heap[parent]) > 0 {
      let swap = heap[parent]
      heap[parent] = heap[current]
      heap[current] = swap
      current = parent
    } else {
      break
    }
  }
}

///|
/// Restore the max-heap property after replacing the root.
fn sift_down(
  heap : Array[SortItem],
  index : Int32,
  compare : (SortItem, SortItem) -> Int32,
) -> Unit {
  let length = heap.length()
  let mut current = index
  while true {
    let left = current * 2 + 1
    if left >= length {
      break
    }
    let right = left + 1
    let mut largest = left
    if right < length && compare(heap[right], heap[left]) > 0 {
      largest = right
    }
    if compare(heap[largest], heap[current]) > 0 {
      let swap = heap[current]
      heap[current] = heap[largest]
      heap[largest] = swap
      current = largest
    } else {
      break
    }
  }
}
