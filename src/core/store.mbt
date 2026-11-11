///|
/// Per-root summary recorded in the store.
///
/// `files`, `folders`, and `size` cover the subtree below `path`, including the
/// root folder itself in `folders`. They are filled in once the scan of that
/// root finishes and are what `index` reports without walking the entries again.
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
}

///|
/// Assemble a store from already-built parts.
///
/// The builder in the `index` package is the intended producer. The constructor
/// validates nothing beyond what the parts already guarantee; ids in `entries`
/// are interpreted as indexes into the two arrays.
pub fn Store::new(
  names~ : NamePool,
  folders~ : Array[Entry],
  files~ : Array[Entry],
  roots~ : Array[RootInfo],
  built_at~ : Int64,
) -> Store {
  { names, folders, files, roots, built_at, }
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
  self.join_chain(self.folders[id].name(), self.folders[id].parent())
}

///|
/// Path bytes of a file entry.
pub fn Store::file_path(self : Store, id : EntryId) -> Bytes {
  if id < 0 || id >= self.files.length() {
    return b""
  }
  let entry = self.files[id]
  self.join_chain(entry.name(), entry.parent())
}

///|
/// Build the path of an entry from its own name and its parent folder.
///
/// The chain is walked from the parent up to the root, then written in reverse.
/// A root name of `/` must not produce a doubled separator.
fn Store::join_chain(self : Store, name : NameRef, parent : FolderId) -> Bytes {
  let refs : Array[NameRef] = [name]
  let mut current = parent
  while current >= 0 && current < self.folders.length() {
    let entry = self.folders[current]
    refs.push(entry.name())
    current = entry.parent()
  }
  let buffer = @buffer.Buffer()
  let mut index = refs.length() - 1
  let mut root_is_slash = false
  let mut first = true
  while index >= 0 {
    let component = self.names.view(refs[index])
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
