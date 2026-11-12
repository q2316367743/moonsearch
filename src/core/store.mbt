///|
/// Per-root summary recorded in the store.
///
/// `files`, `folders`, and `size` cover the subtree below `path`; the root
/// folder itself is not included in `folders` (it is present in the folder
/// array and counted by `Store::folder_count`). They are filled in once the
/// scan of that root finishes and are what `index` reports without walking the
/// entries again.
pub(all) struct RootInfo {
  path : String
  one_file_system : Bool
  folder : FolderId
  files : UInt32
  folders : UInt32
  size : Int64
}

///|
/// An immutable in-memory index.
///
/// A store owns the name pool and the folder/file arrays built by a scan. The
/// arrays are indexed by `FolderId` and `EntryId` respectively; every collection
/// the query layer builds later refers to entries through those ids. A finished
/// store is only read, which is what makes it safe to share and, from S12 on,
/// straightforward to serialize.
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
/// Assemble a store from already-built parts.
///
/// The builder in the `index` package is the intended producer. The constructor
/// validates nothing beyond what the parts already guarantee; ids in `entries`
/// are interpreted as indexes into the two arrays. It also computes the
/// canonical order, which is the only pre-sorted sequence the query engine
/// keeps.
pub fn Store::new(
  names~ : NamePool,
  folders~ : Array[Entry],
  files~ : Array[Entry],
  roots~ : Array[RootInfo],
  built_at~ : Int64,
) -> Store {
  let order = build_order(names, folders, files)
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
/// Sum of the sizes of all file entries.
///
/// Folders are excluded on purpose: their sizes already include their subtree,
/// so adding both would count every byte twice.
pub fn Store::total_size(self : Store) -> Int64 {
  let mut total = 0L
  for entry in self.files {
    total = total + entry.size()
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
/// A root name of `/` must not produce a doubled separator.
fn join_chain(
  names : NamePool,
  folders : Array[Entry],
  name : NameRef,
  parent : FolderId,
) -> Bytes {
  let refs : Array[NameRef] = [name]
  let mut current = parent
  while current >= 0 && current < folders.length() {
    let entry = folders[current]
    refs.push(entry.name())
    current = entry.parent()
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
/// Compute the canonical order of all entries.
///
/// Names are the primary key and full paths the secondary key, with the entry's
/// position in the input as a final tie-breaker. Both keys use the natural path
/// ordering from `@util.cmp_paths`, so `file2` sorts before `file10`.
fn build_order(
  names : NamePool,
  folders : Array[Entry],
  files : Array[Entry],
) -> Array[EntryRef] {
  let folder_count = folders.length()
  let total = folder_count + files.length()
  let refs : Array[EntryRef] = []
  let paths : Array[Bytes] = []
  for id in 0..<folder_count {
    let entry = folders[id]
    refs.push(EntryRef::new(Folder, id))
    paths.push(join_chain(names, folders, entry.name(), entry.parent()))
  }
  for id in 0..<files.length() {
    let entry = files[id]
    refs.push(EntryRef::new(File, id))
    paths.push(join_chain(names, folders, entry.name(), entry.parent()))
  }
  let indices : Array[Int32] = []
  for index in 0..<total {
    indices.push(index)
  }
  indices.sort_by(fn(left, right) {
    let left_name = ref_name(names, folders, files, refs[left])
    let right_name = ref_name(names, folders, files, refs[right])
    let name_order = @util.cmp_paths(left_name, right_name)
    if name_order != 0 {
      name_order
    } else {
      let path_order = @util.cmp_paths(paths[left][:], paths[right][:])
      if path_order != 0 {
        path_order
      } else {
        left - right
      }
    }
  })
  let ordered : Array[EntryRef] = []
  for index in indices {
    ordered.push(refs[index])
  }
  ordered
}

///|
/// Name bytes behind an entry reference. Only called for ids built above.
fn ref_name(
  names : NamePool,
  folders : Array[Entry],
  files : Array[Entry],
  entry : EntryRef,
) -> BytesView {
  match entry.kind {
    Folder => names.view(folders[entry.id].name())
    File => names.view(files[entry.id].name())
  }
}
