///|
/// Per-root summary recorded in the store.
///
/// `files`, `folders`, and `size` cover the subtree below `path`; the root
/// folder itself is not included in `folders` (it is present in the folder
/// array and counted by `Store::folder_count`). They are filled in once the
/// scan of that root finishes and are what `index` reports without walking the
/// entries again.
pub(all) struct RootInfo {
  path : Bytes
  one_file_system : Bool
  folder : FolderId
  files : UInt32
  folders : UInt32
  size : Int64
}

///|
/// Build a per-root summary.
///
/// The scanner fills these in through `Builder::set_root_stats`; a database
/// loader reconstructs them from the persisted ROOTS section.
pub fn RootInfo::new(
  path~ : BytesView,
  one_file_system~ : Bool,
  folder~ : FolderId,
  files~ : UInt32 = 0U,
  folders~ : UInt32 = 0U,
  size~ : Int64 = 0L,
) -> RootInfo {
  { path: path.to_owned(), one_file_system, folder, files, folders, size, }
}

///|
/// An immutable in-memory index.
///
/// A store owns the name pool and the folder/file arrays built by a scan. The
/// arrays are indexed by `FolderId` and `EntryId` respectively; every collection
/// the query layer builds later refers to entries through those ids. Each array
/// is physically ordered by `(name, path)`, so its indexes are already canonical
/// within that entry kind. A finished store is only read, which is what makes it
/// safe to share and straightforward to serialize.
pub struct Store {
  priv names : NamePool
  priv folders : Array[Entry]
  priv files : Array[Entry]
  priv roots : Array[RootInfo]
  priv built_at : Int64
  /// The single canonical order: `(name, path)` natural order over folders and
  /// files together. Built once, immutable afterwards.
  priv order : Array[EntryRef]
}

///|
/// Assemble a store from parts that still use builder-assigned ids.
///
/// The builder in the `index` package is the intended producer. Before the
/// arrays become immutable, this constructor sorts folders and files separately
/// by natural `(name, path)` order, builds the old-to-new id maps, and rewrites
/// every parent and root folder id. It then computes the merged canonical order
/// used by query output. Dict, Ranges, and Trigram are built only after this
/// step, so all derived structures use the final id space.
pub fn Store::new(
  names~ : NamePool,
  folders~ : Array[Entry],
  files~ : Array[Entry],
  roots~ : Array[RootInfo],
  built_at~ : Int64,
) -> Store {
  let (folders, files, roots, order) = normalize_entries(
    names, folders, files, roots,
  )
  { names, folders, files, roots, built_at, order, }
}

///|
/// Rebuild a store from parts that were already validated.
///
/// This is the database loader's constructor: it skips `Store::new`'s canonical
/// sort because the persisted ORDER section is the exact order the store had
/// when it was written. The caller owns validation: `order` must be a
/// permutation of the store-wide ids, every parent must name a folder, and every
/// name reference must be readable from `names`. A malformed order can make
/// results appear in the wrong sequence but cannot index out of bounds, because
/// every consumer of `order` resolves ids through `entry_at`.
pub fn Store::restore(
  names~ : NamePool,
  folders~ : Array[Entry],
  files~ : Array[Entry],
  roots~ : Array[RootInfo],
  built_at~ : Int64,
  order~ : Array[EntryRef],
) -> Store {
  { names, folders, files, roots, built_at, order, }
}

///|
/// Number of folder entries.
pub fn Store::folder_count(self : Store) -> Int32 {
  self.folders.length()
}

///|
/// Number of file entries.
pub fn Store::file_count(self : Store) -> Int32 {
  self.files.length()
}

///|
/// Total number of entries, folders and files together.
pub fn Store::entry_count(self : Store) -> Int32 {
  self.folders.length() + self.files.length()
}

///|
/// Map an entry reference into the store-wide id space.
///
/// Folders occupy `0 .. folder_count - 1` and files continue from there, so the
/// result is unique across both arrays. Out-of-range references are not checked;
/// `entry_at` is the validating reverse direction.
pub fn Store::global_id(self : Store, entry : EntryRef) -> GlobalId {
  match entry.kind {
    Folder => entry.id
    File => self.folders.length() + entry.id
  }
}

///|
/// Resolve a store-wide id back to the folder or file it names.
///
/// Returns `None` for negative ids and ids at or past `entry_count`, which is
/// what a corrupted posting or bitmap must degrade to instead of indexing out
/// of bounds.
pub fn Store::entry_at(self : Store, id : GlobalId) -> EntryRef? {
  let folder_count = self.folders.length()
  if id < 0 {
    None
  } else if id < folder_count {
    Some(EntryRef::new(Folder, id))
  } else if id < folder_count + self.files.length() {
    Some(EntryRef::new(File, id - folder_count))
  } else {
    None
  }
}

///|
/// Unix time at which the store was built.
pub fn Store::built_at(self : Store) -> Int64 {
  self.built_at
}

///|
/// Roots recorded by the scan, in the order they were configured.
pub fn Store::roots(self : Store) -> ArrayView[RootInfo] {
  self.roots
}

///|
/// Folder entry by id, or `None` when the id is out of range.
pub fn Store::folder(self : Store, id : FolderId) -> Entry? {
  if id < 0 || id >= self.folders.length() {
    None
  } else {
    Some(self.folders[id])
  }
}

///|
/// File entry by id, or `None` when the id is out of range.
pub fn Store::file(self : Store, id : EntryId) -> Entry? {
  if id < 0 || id >= self.files.length() {
    None
  } else {
    Some(self.files[id])
  }
}

///|
/// Resolve a name reference to its bytes.
pub fn Store::name(self : Store, name_ref : NameRef) -> BytesView {
  self.names.view(name_ref)
}

///|
/// Entries in canonical order: folders and files merged by name, then path.
///
/// This is the order the scan engine evaluates in, and the order `--sort name`
/// prints without any additional work. It is built once when the store is
/// created, so a query never sorts the whole index.
pub fn Store::entries_in_order(self : Store) -> ArrayView[EntryRef] {
  self.order
}

///|
/// Name bytes of one entry, or an empty view when the id is out of range.
pub fn Store::entry_name(self : Store, entry : EntryRef) -> BytesView {
  match entry.kind {
    Folder =>
      if entry.id < 0 || entry.id >= self.folders.length() {
        b""[0:0]
      } else {
        self.names.view(self.folders[entry.id].name())
      }
    File =>
      if entry.id < 0 || entry.id >= self.files.length() {
        b""[0:0]
      } else {
        self.names.view(self.files[entry.id].name())
      }
  }
}

///|
/// Extension bytes of one entry, or an empty view when the id is out of range.
///
/// Folders have no extension even when their name contains a dot: `ext:` is a
/// file field, and the output layer must agree with the query layer. The bytes
/// are returned as stored; callers fold ASCII case when comparing or printing.
pub fn Store::entry_extension(self : Store, entry : EntryRef) -> BytesView {
  if entry.is_file() {
    @util.extension_of(self.entry_name(entry))
  } else {
    b""[0:0]
  }
}

///|
/// Full path bytes of one entry, or an empty value when the id is out of range.
pub fn Store::entry_path(self : Store, entry : EntryRef) -> Bytes {
  match entry.kind {
    Folder => self.folder_path(entry.id)
    File => self.file_path(entry.id)
  }
}

///|
/// Modification time of one entry, or `None` when the id is out of range.
pub fn Store::entry_mtime(self : Store, entry : EntryRef) -> Int64? {
  match entry.kind {
    Folder =>
      if entry.id < 0 || entry.id >= self.folders.length() {
        None
      } else {
        Some(self.folders[entry.id].mtime())
      }
    File =>
      if entry.id < 0 || entry.id >= self.files.length() {
        None
      } else {
        Some(self.files[entry.id].mtime())
      }
  }
}

///|
/// Size of one entry, or `None` when the id is out of range.
pub fn Store::entry_size(self : Store, entry : EntryRef) -> Int64? {
  match entry.kind {
    Folder =>
      if entry.id < 0 || entry.id >= self.folders.length() {
        None
      } else {
        Some(self.folders[entry.id].size())
      }
    File =>
      if entry.id < 0 || entry.id >= self.files.length() {
        None
      } else {
        Some(self.files[entry.id].size())
      }
  }
}

///|
/// Number of distinct names in the pool.
pub fn Store::name_count(self : Store) -> Int32 {
  self.names.count()
}

///|
/// Total number of name bytes.
pub fn Store::name_bytes(self : Store) -> Int32 {
  self.names.byte_len()
}

///|
/// Sum of the sizes of all file entries, saturating at `Int64::MAX`.
///
/// Folders are excluded on purpose: their sizes already include their subtree,
/// so adding both would count every byte twice.
pub fn Store::total_size(self : Store) -> Int64 {
  let mut total = 0L
  for entry in self.files {
    let (next, _) = saturating_add(total, entry.size())
    total = next
  }
  total
}

///|
/// Path bytes of a folder entry.
///
/// The root folder stores its full path in its name, so concatenating the names
/// from the root down yields the path. An out-of-range id yields an empty path.
pub fn Store::folder_path(self : Store, id : FolderId) -> Bytes {
  if id < 0 || id >= self.folders.length() {
    return b""
  }
  join_chain(
    self.names,
    self.folders,
    self.folders[id].name(),
    self.folders[id].parent(),
  )
}

///|
/// Path bytes of a file entry.
pub fn Store::file_path(self : Store, id : EntryId) -> Bytes {
  if id < 0 || id >= self.files.length() {
    return b""
  }
  let entry = self.files[id]
  join_chain(self.names, self.folders, entry.name(), entry.parent())
}

///|
/// Build the path of an entry from its own name and its parent folder.
///
/// The chain is walked from the parent up to the root, then written in reverse.
/// A step limit keeps hand-built malformed cycles finite. A root name of `/`
/// must not produce a doubled separator.
fn join_chain(
  names : NamePool,
  folders : Array[Entry],
  name : NameRef,
  parent : FolderId,
) -> Bytes {
  let refs : Array[NameRef] = [name]
  let mut current = parent
  let mut remaining = folders.length()
  while current >= 0 && current < folders.length() && remaining > 0 {
    let entry = folders[current]
    refs.push(entry.name())
    current = entry.parent()
    remaining = remaining - 1
  }
  let buffer = @buffer.Buffer()
  let mut index = refs.length() - 1
  let mut root_is_slash = false
  let mut first = true
  while index >= 0 {
    let component = names.view(refs[index])
    if first {
      root_is_slash = component.length() > 0 &&
        component[component.length() - 1] == b'/'
    } else if !(root_is_slash && index == refs.length() - 2) {
      buffer.write_byte(b'/')
    }
    buffer.write_bytes(component)
    first = false
    index = index - 1
  }
  buffer.to_bytes()
}

///|
/// One entry plus the keys needed while builder ids are being normalized.
priv struct OrderedEntry {
  old_id : Int32
  path : Bytes
  /// Nearest configured root. Nested roots can duplicate a path; this keeps
  /// their otherwise identical records independent of scan insertion order.
  root : Int32
}

///|
/// Physically canonicalize both entry arrays and remap every folder reference.
fn normalize_entries(
  names : NamePool,
  folders : Array[Entry],
  files : Array[Entry],
  roots : Array[RootInfo],
) -> (Array[Entry], Array[Entry], Array[RootInfo], Array[EntryRef]) {
  let folder_count = folders.length()
  let owners = resolve_root_owners(folders, roots)
  let ordered_folders = Array::makei(folder_count, fn(id) {
    let entry = folders[id]
    {
      old_id: id,
      path: join_chain(names, folders, entry.name(), entry.parent()),
      root: owners[id],
    }
  })
  ordered_folders.sort_by(fn(left, right) {
    compare_ordered(names, folders, folders, left, right, true)
  })
  let ordered_files = Array::makei(files.length(), fn(id) {
    let entry = files[id]
    let parent = entry.parent()
    let root = if parent >= 0 && parent < folder_count {
      owners[parent]
    } else {
      -1
    }
    {
      old_id: id,
      path: join_chain(names, folders, entry.name(), parent),
      root,
    }
  })
  ordered_files.sort_by(fn(left, right) {
    compare_ordered(names, folders, files, left, right, false)
  })
  let folder_map = Array::makei(folder_count, fn(_) { -1 })
  for new_id in 0..<ordered_folders.length() {
    folder_map[ordered_folders[new_id].old_id] = new_id
  }
  let normalized_folders : Array[Entry] = []
  for ordered in ordered_folders {
    let entry = folders[ordered.old_id]
    remap_parent(entry, folder_map, folder_count)
    normalized_folders.push(entry)
  }
  let normalized_files : Array[Entry] = []
  for ordered in ordered_files {
    let entry = files[ordered.old_id]
    remap_parent(entry, folder_map, folder_count)
    normalized_files.push(entry)
  }
  let normalized_roots = roots.map(fn(root) {
    let folder = if root.folder >= 0 && root.folder < folder_count {
      folder_map[root.folder]
    } else {
      root.folder
    }
    RootInfo::new(
      path=root.path,
      one_file_system=root.one_file_system,
      folder~,
      files=root.files,
      folders=root.folders,
      size=root.size,
    )
  })
  let order = merge_order(
    names, normalized_folders, normalized_files, ordered_folders, ordered_files,
  )
  (normalized_folders, normalized_files, normalized_roots, order)
}

///|
/// Compare two builder entries by natural name and path, then by deterministic
/// intrinsic fields. A real scan cannot contain the same path twice under one
/// root, and nested-root copies are separated by `root`; the old id is only a
/// final tie-break for locally identical hand-built records.
fn compare_ordered(
  names : NamePool,
  folders : Array[Entry],
  entries : Array[Entry],
  left : OrderedEntry,
  right : OrderedEntry,
  is_folder : Bool,
) -> Int32 {
  let left_entry = entries[left.old_id]
  let right_entry = entries[right.old_id]
  let name_order = names.compare(left_entry.name(), right_entry.name())
  if name_order != 0 {
    return name_order
  }
  let path_order = @util.cmp_paths(left.path[:], right.path[:])
  if path_order != 0 {
    return path_order
  }
  let root_order = compare_int32(left.root, right.root)
  if root_order != 0 {
    return root_order
  }
  let left_parent_path = parent_path(names, folders, left_entry.parent())
  let right_parent_path = parent_path(names, folders, right_entry.parent())
  let parent_order = @util.cmp_paths(left_parent_path[:], right_parent_path[:])
  if parent_order != 0 {
    return parent_order
  }
  let flags_order = compare_int32(
    left_entry.flags().to_int(),
    right_entry.flags().to_int(),
  )
  if flags_order != 0 {
    return flags_order
  }
  let size_order = compare_int64(left_entry.size(), right_entry.size())
  if size_order != 0 {
    return size_order
  }
  let mtime_order = compare_int64(left_entry.mtime(), right_entry.mtime())
  if mtime_order != 0 {
    return mtime_order
  }
  if is_folder {
    let files_order = compare_int32(
      left_entry.num_files().reinterpret_as_int(),
      right_entry.num_files().reinterpret_as_int(),
    )
    if files_order != 0 {
      return files_order
    }
    let folders_order = compare_int32(
      left_entry.num_folders().reinterpret_as_int(),
      right_entry.num_folders().reinterpret_as_int(),
    )
    if folders_order != 0 {
      return folders_order
    }
  }
  let raw_name_order = compare_lexical(
    names.view(left_entry.name()),
    names.view(right_entry.name()),
  )
  if raw_name_order != 0 {
    return raw_name_order
  }
  let raw_path_order = compare_lexical(left.path[:], right.path[:])
  if raw_path_order != 0 {
    return raw_path_order
  }
  compare_int32(left.old_id, right.old_id)
}

///|
/// Rewrite a valid builder parent through the old-to-new folder map. Invalid
/// parents are left untouched so hand-built stores keep their existing graceful
/// path truncation behavior.
fn remap_parent(
  entry : Entry,
  folder_map : Array[Int32],
  folder_count : Int32,
) -> Unit {
  let parent = entry.parent()
  if parent >= 0 && parent < folder_count {
    entry.set_parent(folder_map[parent])
  }
}

///|
/// Full path of a parent folder, or an empty path for a root/invalid parent.
fn parent_path(
  names : NamePool,
  folders : Array[Entry],
  parent : FolderId,
) -> Bytes {
  if parent < 0 || parent >= folders.length() {
    return b""
  }
  let entry = folders[parent]
  join_chain(names, folders, entry.name(), entry.parent())
}

///|
/// Assign every folder to its nearest configured root without recursion.
///
/// The scanner creates roots before their children, but `Store::new` also
/// accepts arbitrary array order. A three-state walk handles both late parents
/// and malformed cycles deterministically; cycle members remain unassigned.
fn resolve_root_owners(
  folders : Array[Entry],
  roots : Array[RootInfo],
) -> Array[Int32] {
  let count = folders.length()
  let owners = Array::makei(count, fn(_) { -1 })
  let states = Array::makei(count, fn(_) { b'\x00' })
  for index in 0..<roots.length() {
    let folder = roots[index].folder
    if folder >= 0 &&
      folder < count &&
      (owners[folder] < 0 || index < owners[folder]) {
      owners[folder] = index
      states[folder] = b'\x02'
    }
  }
  let chain : Array[Int32] = []
  for start in 0..<count {
    if states[start] != b'\x00' {
      continue
    }
    let mut current = start
    while current >= 0 &&
          current < count &&
          states[current] == b'\x00' &&
          chain.length() < count {
      states[current] = b'\x01'
      chain.push(current)
      current = folders[current].parent()
    }
    let owner = if current >= 0 && current < count && states[current] == b'\x02' {
      owners[current]
    } else {
      -1
    }
    for position in 0..<chain.length() {
      let node = chain[position]
      states[node] = b'\x02'
      owners[node] = owner
    }
    while !chain.is_empty() {
      ignore(chain.pop())
    }
  }
  owners
}

///|
/// Three-way comparison of two 32-bit integers.
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
/// Three-way lexicographic byte comparison.
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
/// Merge the two physically sorted arrays into the single canonical order.
///
/// Both inputs are already sorted by natural `(name, path)`, so this is linear
/// rather than a third comparison sort. Exact cross-kind ties put the folder
/// first, matching the store-wide id rule.
fn merge_order(
  names : NamePool,
  folders : Array[Entry],
  files : Array[Entry],
  ordered_folders : Array[OrderedEntry],
  ordered_files : Array[OrderedEntry],
) -> Array[EntryRef] {
  let order : Array[EntryRef] = []
  let mut folder = 0
  let mut file = 0
  while folder < folders.length() && file < files.length() {
    let name_order = names.compare(folders[folder].name(), files[file].name())
    let take_folder = if name_order != 0 {
      name_order < 0
    } else {
      let path_order = @util.cmp_paths(
        ordered_folders[folder].path[:],
        ordered_files[file].path[:],
      )
      path_order <= 0
    }
    if take_folder {
      order.push(EntryRef::new(Folder, folder))
      folder = folder + 1
    } else {
      order.push(EntryRef::new(File, file))
      file = file + 1
    }
  }
  while folder < folders.length() {
    order.push(EntryRef::new(Folder, folder))
    folder = folder + 1
  }
  while file < files.length() {
    order.push(EntryRef::new(File, file))
    file = file + 1
  }
  order
}
