///|
/// Accumulates entries while a scan runs.
///
/// The builder owns the name pool and the folder/file arrays. Ids are assigned
/// in insertion order, which is deterministic because directory listings are
/// sorted by name before they are consumed. Once the scan is done, `finish`
/// hands the parts to an immutable `Store`.
pub struct Builder {
  priv names : @core.NamePool
  priv folders : Array[@core.Entry]
  priv files : Array[@core.Entry]
  priv roots : Array[@core.RootInfo]
}

///|
/// Create an empty builder.
pub fn Builder::new() -> Builder {
  { names: @core.NamePool::new(), folders: [], files: [], roots: [], }
}

///|
/// Append a root folder and record its configuration.
///
/// The root's name is the normalized root path itself, so path reconstruction
/// can stop at `NO_PARENT`. The returned id is the folder id to use as the
/// parent of every entry below this root; `root_count() - 1` is the index for
/// `set_root_stats`.
pub fn Builder::add_root(
  self : Builder,
  path : StringView,
  one_file_system : Bool,
  mtime : Int64,
) -> @core.FolderId raise IndexError {
  let name_ref = self.add_name(path)
  let id = self.folders.length()
  self.folders.push(
    @core.Entry::folder(parent=@core.NO_PARENT, name=name_ref, mtime~),
  )
  self.roots.push({
    path: "\{path}",
    one_file_system,
    folder: id,
    files: 0U,
    folders: 0U,
    size: 0L,
  })
  id
}

///|
/// Append a non-root folder entry.
pub fn Builder::add_folder(
  self : Builder,
  parent : @core.FolderId,
  name : StringView,
  mtime : Int64,
  flags~ : UInt16 = 0,
) -> @core.FolderId raise IndexError {
  let name_ref = self.add_name(name)
  let id = self.folders.length()
  self.folders.push(@core.Entry::folder(parent~, name=name_ref, mtime~, flags~))
  id
}

///|
/// Append a file entry.
pub fn Builder::add_file(
  self : Builder,
  parent : @core.FolderId,
  name : StringView,
  size : Int64,
  mtime : Int64,
  flags~ : UInt16 = 0,
) -> @core.EntryId raise IndexError {
  let name_ref = self.add_name(name)
  let id = self.files.length()
  self.files.push(
    @core.Entry::file(parent~, name=name_ref, size~, mtime~, flags~),
  )
  id
}

///|
/// Store the direct child counts of a scanned folder.
pub fn Builder::set_child_counts(
  self : Builder,
  id : @core.FolderId,
  files : UInt32,
  folders : UInt32,
) -> Unit {
  self.folders[id].set_child_counts(files, folders)
}

///|
/// Add the subtree size of one child to a folder.
pub fn Builder::add_folder_size(
  self : Builder,
  id : @core.FolderId,
  delta : Int64,
) -> Unit {
  self.folders[id].add_size(delta)
}

///|
/// Fill in the final statistics of the root at `index`.
pub fn Builder::set_root_stats(
  self : Builder,
  index : Int32,
  files : UInt32,
  folders : UInt32,
  size : Int64,
) -> Unit {
  self.roots[index] = {
    path: self.roots[index].path,
    one_file_system: self.roots[index].one_file_system,
    folder: self.roots[index].folder,
    files,
    folders,
    size,
  }
}

///|
/// Number of roots added so far.
pub fn Builder::root_count(self : Builder) -> Int32 {
  self.roots.length()
}

///|
/// Number of folders added so far.
pub fn Builder::folder_count(self : Builder) -> Int32 {
  self.folders.length()
}

///|
/// Number of files added so far.
pub fn Builder::file_count(self : Builder) -> Int32 {
  self.files.length()
}

///|
/// Freeze the builder into an immutable store.
///
/// `built_at` defaults to the current time in Unix seconds; tests pass an
/// explicit value for determinism.
pub fn Builder::finish(self : Builder, built_at~ : Int64 = -1L) -> @core.Store {
  let timestamp = if built_at >= 0L {
    built_at
  } else {
    (@env.now() / 1000UL).reinterpret_as_int64()
  }
  @core.Store::new(
    names=self.names,
    folders=self.folders,
    files=self.files,
    roots=self.roots,
    built_at=timestamp,
  )
}

///|
/// Append a name to the pool, translating pool errors to index errors.
fn Builder::add_name(
  self : Builder,
  name : StringView,
) -> @core.NameRef raise IndexError {
  let bytes = @utf8.encode(name)
  self.names.add(bytes[:]) catch {
    NameTooLong(length) => raise NameTooLong(length)
    PoolFull => raise NamePoolFull
  }
}
