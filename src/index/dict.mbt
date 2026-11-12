///|
/// One extension bucket: the ASCII-folded extension and every file that has it.
///
/// The bucket list in `Dict` is sorted by extension bytes, which makes a lookup
/// a binary search and keeps the output deterministic across runs. An empty
/// extension is a real bucket; it holds files whose name has no extension.
pub struct ExtensionEntry {
  priv extension : Bytes
  priv ids : @ids.Ids
}

///|
/// ASCII-folded extension bytes.
pub fn ExtensionEntry::extension(self : ExtensionEntry) -> BytesView {
  self.extension[:]
}

///|
/// Files that carry this extension.
pub fn ExtensionEntry::ids(self : ExtensionEntry) -> @ids.Ids {
  self.ids
}

///|
/// The low-cardinality field dictionary.
///
/// Every set here is a bitmap or sorted id set over the store-wide id space
/// from `@core.Store::global_id`: folders first, then files. The dictionary is
/// built once, after the scan, and treated as read-only afterwards.
///
/// It covers the fields whose values repeat often and whose queries are
/// equality or set membership:
///
/// - each extension, including the empty extension;
/// - all files, all folders, and the hidden/visible split;
/// - each configured root and its whole subtree;
/// - the built-in category macros (`app:`, `archive:`, `audio:`, `doc:`,
///   `pic:`, `video:`), materialized as the union of their extension buckets.
///
/// High-cardinality fields such as `parent:` do not belong here; they use the
/// range indexes of S08 instead of one bitmap per folder.
///
/// Accessors return the stored sets by value without copying them. Treat every
/// returned `Ids` as read-only, like the rest of a finished index.
pub struct Dict {
  priv total : Int32
  priv all : @ids.Ids
  priv files_all : @ids.Ids
  priv folders_all : @ids.Ids
  priv hidden : @ids.Ids
  priv visible : @ids.Ids
  priv extensions : Array[ExtensionEntry]
  /// One set per category, indexed by `TypeCategory::index`.
  priv categories : Array[@ids.Ids]
  /// One set per configured root, in `Store::roots()` order.
  priv roots : Array[@ids.Ids]
}

///|
/// Build the dictionary for a finished store.
///
/// The pass is linear in the number of entries plus the extension sort, and it
/// allocates no per-entry index structure. Category sets are materialized here
/// so a `pic:` query later costs one array lookup and one set operation.
pub fn Dict::build(store : @core.Store) -> Dict {
  let folder_count = store.folder_count()
  let file_count = store.file_count()
  let total = folder_count + file_count
  let folders_all = @ids.Ids::from_sorted(
    Array::makei(folder_count, fn(id) { id }),
    total~,
  )
  let files_all = @ids.Ids::from_sorted(
    Array::makei(file_count, fn(id) { folder_count + id }),
    total~,
  )
  let all = folders_all.union(files_all).normalize(total)
  let hidden_ids : Array[Int32] = []
  for id in 0..<folder_count {
    match store.folder(id) {
      Some(entry) => if entry.is_hidden() { hidden_ids.push(id) }
      None => ()
    }
  }
  for id in 0..<file_count {
    match store.file(id) {
      Some(entry) => if entry.is_hidden() { hidden_ids.push(folder_count + id) }
      None => ()
    }
  }
  let hidden = @ids.Ids::from_sorted(hidden_ids, total~)
  let visible = all.difference(hidden).normalize(total)
  let extensions = build_extensions(store, folder_count, file_count, total)
  let categories = build_categories(extensions, total)
  let roots = build_roots(store, folder_count, file_count, total)
  {
    total,
    all,
    files_all,
    folders_all,
    hidden,
    visible,
    extensions,
    categories,
    roots,
  }
}

///|
/// Group file ids by ASCII-folded extension.
///
/// Files are visited in id order, so every bucket starts ascending; the sort
/// afterwards only orders the buckets by extension. The intermediate hash map
/// is dropped once the immutable sorted array exists.
fn build_extensions(
  store : @core.Store,
  folder_count : Int32,
  file_count : Int32,
  total : Int32,
) -> Array[ExtensionEntry] {
  let buckets : Map[Bytes, Array[Int32]] = Map([])
  for id in 0..<file_count {
    match store.file(id) {
      Some(entry) => {
        let name = store.name(entry.name())
        let key = @util.ascii_fold(@util.extension_of(name))
        let global = folder_count + id
        match buckets.get_from_bytes(key[:]) {
          Some(ids) => ids.push(global)
          None => buckets.set(key, [global])
        }
      }
      None => ()
    }
  }
  let entries : Array[ExtensionEntry] = []
  for pair in buckets.to_array() {
    entries.push({
      extension: pair.0,
      ids: @ids.Ids::from_sorted(pair.1, total~),
    })
  }
  // Lexicographic order, not `Compare`'s shortlex order, so the bucket list
  // reads like a sorted extension column and the binary search below uses the
  // same total order.
  entries.sort_by(fn(left, right) {
    left.extension[:].lexical_compare(right.extension[:])
  })
  entries
}

///|
/// Materialize every category as the union of its extension buckets.
fn build_categories(
  extensions : Array[ExtensionEntry],
  total : Int32,
) -> Array[@ids.Ids] {
  let categories : Array[@ids.Ids] = []
  for category in @util.TypeCategory::all() {
    let mut ids = @ids.Ids::empty()
    for extension in category.extensions() {
      let key = @utf8.encode(extension)
      ids = ids.union(extension_lookup(extensions, key[:]))
    }
    categories.push(ids.normalize(total))
  }
  categories
}

///|
/// Assign every entry to the configured root it was discovered under.
///
/// The root folder and all of its descendants go into one bucket. Roots are
/// recorded by the scanner in configuration order, and `Store::roots()` keeps
/// that order, so the dictionary's root index matches it.
fn build_roots(
  store : @core.Store,
  folder_count : Int32,
  file_count : Int32,
  total : Int32,
) -> Array[@ids.Ids] {
  let root_count = store.roots().length()
  let resolved : Array[Int32] = Array::makei(folder_count, fn(_) { -1 })
  for index in 0..<root_count {
    let folder = store.roots()[index].folder
    if folder >= 0 && folder < folder_count {
      resolved[folder] = index
    }
  }
  let buckets : Array[Array[Int32]] = []
  for _ in 0..<root_count {
    buckets.push([])
  }
  for id in 0..<folder_count {
    let root = resolve_root(store, resolved, id, folder_count)
    if root >= 0 && root < root_count {
      buckets[root].push(id)
    }
  }
  for id in 0..<file_count {
    let root = match store.file(id) {
      Some(entry) => {
        let parent = entry.parent()
        if parent >= 0 && parent < folder_count {
          resolved[parent]
        } else {
          -1
        }
      }
      None => -1
    }
    if root >= 0 && root < root_count {
      buckets[root].push(folder_count + id)
    }
  }
  let roots : Array[@ids.Ids] = []
  for bucket in buckets {
    roots.push(@ids.Ids::from_sorted(bucket, total~))
  }
  roots
}

///|
/// Root index of a folder, propagating the answer up the parent chain.
///
/// Folder ids from the builder are pre-order, so the parent is normally
/// resolved already. The explicit path buffer also handles a store assembled
/// with an arbitrary array order, and the length guard stops a corrupted parent
/// cycle instead of looping forever.
fn resolve_root(
  store : @core.Store,
  resolved : Array[Int32],
  id : Int32,
  limit : Int32,
) -> Int32 {
  let path : Array[Int32] = []
  let mut current = id
  while current >= 0 &&
        current < resolved.length() &&
        resolved[current] < 0 &&
        path.length() <= limit {
    path.push(current)
    current = match store.folder(current) {
      Some(entry) => entry.parent()
      None => -1
    }
  }
  let value = if current >= 0 && current < resolved.length() {
    resolved[current]
  } else {
    -1
  }
  for node in path {
    resolved[node] = value
  }
  value
}

///|
/// Look up one extension bucket by bytes, folding ASCII case.
///
/// Returns the empty set when the extension does not occur in the index.
fn extension_lookup(
  entries : Array[ExtensionEntry],
  extension : BytesView,
) -> @ids.Ids {
  let folded = @util.ascii_fold(extension)
  let mut low = 0
  let mut high = entries.length()
  while low < high {
    let middle = (low + high) / 2
    let order = entries[middle].extension[:].lexical_compare(folded[:])
    if order < 0 {
      low = middle + 1
    } else if order > 0 {
      high = middle
    } else {
      return entries[middle].ids
    }
  }
  @ids.Ids::empty()
}

///|
/// Number of entries the dictionary was built over.
pub fn Dict::entry_count(self : Dict) -> Int32 {
  self.total
}

///|
/// Every entry, files and folders together.
pub fn Dict::all(self : Dict) -> @ids.Ids {
  self.all
}

///|
/// Every file entry.
pub fn Dict::files_all(self : Dict) -> @ids.Ids {
  self.files_all
}

///|
/// Every folder entry.
pub fn Dict::folders_all(self : Dict) -> @ids.Ids {
  self.folders_all
}

///|
/// Entries whose name starts with a dot.
pub fn Dict::hidden(self : Dict) -> @ids.Ids {
  self.hidden
}

///|
/// Entries whose name does not start with a dot.
pub fn Dict::visible(self : Dict) -> @ids.Ids {
  self.visible
}

///|
/// Number of distinct extensions, including the empty one.
pub fn Dict::extension_count(self : Dict) -> Int32 {
  self.extensions.length()
}

///|
/// Extension buckets in ascending byte order, for diagnostics and tests.
pub fn Dict::extensions(self : Dict) -> ArrayView[ExtensionEntry] {
  self.extensions
}

///|
/// Files with the given extension (ASCII case-insensitive).
///
/// An empty extension selects files whose name has no extension, matching
/// `ext:`. The empty set means the extension does not occur in this index.
pub fn Dict::extension(self : Dict, extension : BytesView) -> @ids.Ids {
  extension_lookup(self.extensions, extension)
}

///|
/// Union of several extension buckets, the indexed form of `ext:a;b;c`.
pub fn Dict::lookup_extensions(
  self : Dict,
  extensions : Array[Bytes],
) -> @ids.Ids {
  let mut result = @ids.Ids::empty()
  for extension in extensions {
    result = result.union(extension_lookup(self.extensions, extension[:]))
  }
  result.normalize(self.total)
}

///|
/// Number of built-in categories, currently six.
pub fn Dict::type_category_count(self : Dict) -> Int32 {
  self.categories.length()
}

///|
/// The materialized set of one built-in category.
///
/// The set is complete: every extension in the category is resolved here, not
/// per query, so `pic:` costs one array index.
pub fn Dict::type_category(
  self : Dict,
  category : @util.TypeCategory,
) -> @ids.Ids {
  let index = category.index()
  if index < 0 || index >= self.categories.length() {
    @ids.Ids::empty()
  } else {
    self.categories[index]
  }
}

///|
/// Resolve a built-in macro name to its category set.
///
/// `None` means the name is not a built-in macro; the query parser applies the
/// same rule, so the two layers agree on which names are categories.
pub fn Dict::builtin_macro(self : Dict, name : StringView) -> @ids.Ids? {
  match @util.TypeCategory::from_name(name) {
    Some(category) => Some(self.type_category(category))
    None => None
  }
}

///|
/// Number of configured roots.
pub fn Dict::root_count(self : Dict) -> Int32 {
  self.roots.length()
}

///|
/// One subtree set per configured root, in `Store::roots()` order.
pub fn Dict::roots(self : Dict) -> ArrayView[@ids.Ids] {
  self.roots
}

///|
/// The subtree set of the root at `index`, or `None` when out of range.
pub fn Dict::root(self : Dict, index : Int32) -> @ids.Ids? {
  if index < 0 || index >= self.roots.length() {
    None
  } else {
    Some(self.roots[index])
  }
}
