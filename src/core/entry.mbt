///|
/// Identifier of an entry. Folder ids index the folder array, file ids index
/// the file array; both spaces start at zero.
pub type EntryId = Int32

///|
/// Identifier of a folder, which is the index into the folder array.
pub type FolderId = Int32

///|
/// Parent value used by root folder entries.
pub const NO_PARENT : FolderId = -1

///|
/// Whether an entry is a file or a folder.
///
/// Entries do not store this: the array an entry lives in decides its kind.
/// The enum is used where a caller must choose a child count to update.
pub(all) enum EntryKind {
  File
  Folder
}

///|
/// A reference to one entry: the array it lives in and its id.
///
/// Folder ids and file ids are independent spaces, so a bare `Int32` cannot
/// identify an entry on its own. Query results and iteration over the canonical
/// order use `EntryRef` until the bitmap id space of S06 gives every entry a
/// single number.
pub(all) struct EntryRef {
  kind : EntryKind
  id : Int32
}

///|
/// Build an entry reference.
pub fn EntryRef::new(kind : EntryKind, id : Int32) -> EntryRef {
  { kind, id, }
}

///|
/// Whether the reference points at a file.
pub fn EntryRef::is_file(self : EntryRef) -> Bool {
  self.kind is File
}

///|
/// Whether the reference points at a folder.
pub fn EntryRef::is_folder(self : EntryRef) -> Bool {
  self.kind is Folder
}

///|
/// Bit 0 of `Entry::flags`: the name starts with a dot.
pub const ENTRY_FLAG_HIDDEN : UInt16 = 0x0001

///|
/// Bit 1 of `Entry::flags`: the entry is a symbolic link (never followed).
pub const ENTRY_FLAG_SYMLINK : UInt16 = 0x0002

///|
/// Bit 2 of `Entry::flags`: the entry is a socket, pipe, or device node.
pub const ENTRY_FLAG_SPECIAL : UInt16 = 0x0004

///|
/// One file or folder in the index.
///
/// The entry stores only raw fields and a reference into the name pool; the
/// full path is reconstructed through `parent`. Folders and files use the same
/// layout so a single record writer/reader covers both. `size` is the file
/// size for files and the summed subtree size for folders; `num_files` and
/// `num_folders` are direct-child counts and are meaningful for folders only.
pub struct Entry {
  priv mut parent : FolderId
  priv name : NameRef
  priv flags : UInt16
  priv mut size : Int64
  priv mtime : Int64
  priv mut num_files : UInt32
  priv mut num_folders : UInt32
}

///|
/// Build a file entry.
pub fn Entry::file(
  parent~ : FolderId,
  name~ : NameRef,
  size~ : Int64,
  mtime~ : Int64,
  flags~ : UInt16 = 0,
) -> Entry {
  { parent, name, flags, size, mtime, num_files: 0U, num_folders: 0U, }
}

///|
/// Build a folder entry. Folder sizes start at zero and grow through
/// `Entry::add_size` while the scanner unwinds the directory tree.
pub fn Entry::folder(
  parent~ : FolderId,
  name~ : NameRef,
  mtime~ : Int64,
  flags~ : UInt16 = 0,
) -> Entry {
  { parent, name, flags, size: 0L, mtime, num_files: 0U, num_folders: 0U, }
}

///|
/// Parent folder id; `NO_PARENT` for a root.
pub fn Entry::parent(self : Entry) -> FolderId {
  self.parent
}

///|
/// Name reference into the owning `NamePool`.
pub fn Entry::name(self : Entry) -> NameRef {
  self.name
}

///|
/// Raw entry flags.
pub fn Entry::flags(self : Entry) -> UInt16 {
  self.flags
}

///|
/// File size, or summed subtree size for a folder.
pub fn Entry::size(self : Entry) -> Int64 {
  self.size
}

///|
/// Modification time in Unix seconds.
pub fn Entry::mtime(self : Entry) -> Int64 {
  self.mtime
}

///|
/// Number of direct child files (folders only).
pub fn Entry::num_files(self : Entry) -> UInt32 {
  self.num_files
}

///|
/// Number of direct child folders (folders only).
pub fn Entry::num_folders(self : Entry) -> UInt32 {
  self.num_folders
}

///|
/// Repoint the entry at another folder after id normalization.
pub fn Entry::set_parent(self : Entry, parent : FolderId) -> Unit {
  self.parent = parent
}

///|
/// Replace the direct-child counts, for example after scanning a directory.
pub fn Entry::set_child_counts(
  self : Entry,
  files : UInt32,
  folders : UInt32,
) -> Unit {
  self.num_files = files
  self.num_folders = folders
}

///|
/// Record one direct child of the given kind.
pub fn Entry::add_child(self : Entry, kind : EntryKind) -> Unit {
  match kind {
    File => self.num_files = self.num_files + 1U
    Folder => self.num_folders = self.num_folders + 1U
  }
}

///|
/// Add `delta` bytes to the entry size, saturating at `Int64` bounds.
///
/// The scanner only adds non-negative file sizes, but handling both directions
/// keeps the invariant local to this method.
pub fn Entry::add_size(self : Entry, delta : Int64) -> Unit {
  if delta > 0L {
    if self.size > 9223372036854775807L - delta {
      self.size = 9223372036854775807L
    } else {
      self.size = self.size + delta
    }
  } else if delta < 0L {
    if self.size < -9223372036854775807L - 1L - delta {
      self.size = -9223372036854775807L - 1L
    } else {
      self.size = self.size + delta
    }
  }
}

///|
/// Total number of direct children.
pub fn Entry::child_count(self : Entry) -> UInt32 {
  self.num_files + self.num_folders
}

///|
/// Whether this entry is a root (`parent == NO_PARENT`).
pub fn Entry::is_root(self : Entry) -> Bool {
  self.parent == NO_PARENT
}

///|
/// Whether the hidden flag is set.
pub fn Entry::is_hidden(self : Entry) -> Bool {
  (self.flags & ENTRY_FLAG_HIDDEN) != 0
}

///|
/// Whether the entry is a symbolic link.
pub fn Entry::is_symlink(self : Entry) -> Bool {
  (self.flags & ENTRY_FLAG_SYMLINK) != 0
}
