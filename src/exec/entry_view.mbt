///|
/// Entry metadata shared by Store scans and filesystem streaming scans.
///
/// Live traversal cannot know a folder's post-order size or child counts. Those
/// values are therefore zero in its view, and callers must fall back to a full
/// Store scan when the compiled query needs them.
pub(all) struct EntryView {
  path : Bytes
  name : Bytes
  kind : @core.EntryKind
  size : Int64
  mtime : Int64
  flags : UInt16
  depth : Int32
  parent_path : Bytes?
  child_count : UInt32
  num_files : UInt32
  num_folders : UInt32
}

///|
/// Build a view from one immutable Store entry.
pub fn EntryView::of_store(
  store : @core.Store,
  entry : @core.EntryRef,
) -> EntryView {
  let parent_id : Int32 = match entry.kind {
    @core.Folder =>
      match store.folder(entry.id) {
        Some(folder) => folder.parent()
        None => @core.NO_PARENT
      }
    @core.File =>
      match store.file(entry.id) {
        Some(file) => file.parent()
        None => @core.NO_PARENT
      }
  }
  let parent_path = if parent_id >= 0 {
    Some(store.folder_path(parent_id))
  } else {
    None
  }
  let (flags, child_count, num_files, num_folders) = match entry.kind {
    @core.Folder =>
      match store.folder(entry.id) {
        Some(folder) =>
          (
            folder.flags(),
            folder.child_count(),
            folder.num_files(),
            folder.num_folders(),
          )
        None => (0, 0, 0, 0)
      }
    @core.File =>
      match store.file(entry.id) {
        Some(file) => (file.flags(), 0, 0, 0)
        None => (0, 0, 0, 0)
      }
  }
  {
    path: store.entry_path(entry),
    name: store.entry_name(entry).to_owned(),
    kind: entry.kind,
    size: store.entry_size(entry).unwrap_or(0L),
    mtime: store.entry_mtime(entry).unwrap_or(0L),
    flags,
    depth: view_depth(store, entry),
    parent_path,
    child_count,
    num_files,
    num_folders,
  }
}

///|
/// Build a view from filesystem metadata gathered before directory aggregation.
pub fn EntryView::live(
  path~ : Bytes,
  name~ : Bytes,
  kind~ : @core.EntryKind,
  size~ : Int64,
  mtime~ : Int64,
  flags~ : UInt16,
  depth~ : Int32,
  parent_path~ : Bytes?,
) -> EntryView {
  {
    path,
    name,
    kind,
    size,
    mtime,
    flags,
    depth,
    parent_path,
    child_count: 0,
    num_files: 0,
    num_folders: 0,
  }
}

///|
/// Folder depth, with roots at zero and files one below their parent.
fn view_depth(store : @core.Store, entry : @core.EntryRef) -> Int32 {
  let is_file = entry.kind is @core.File
  let mut id = match entry.kind {
    @core.Folder => entry.id
    @core.File =>
      match store.file(entry.id) {
        Some(file) => file.parent()
        None => return 0
      }
  }
  let mut depth = 0
  while id >= 0 {
    match store.folder(id) {
      Some(folder) => {
        depth = depth + 1
        id = folder.parent()
      }
      None => break
    }
  }
  depth - 1 + (if is_file { 1 } else { 0 })
}
