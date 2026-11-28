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
/// Optional fields a compiled predicate can observe.
///
/// The scan engine builds one view per entry. Materializing the full path,
/// parent path, depth chain, and folder totals for every entry costs far more
/// than the predicate itself for name-only queries, so the engine asks for
/// exactly the fields the compiled expression can read. Every unrequested
/// field keeps its documented default (empty bytes, zero, `None`); evaluation
/// must never rely on a field it did not request.
priv struct ScanNeeds {
  name : Bool
  path : Bool
  size : Bool
  mtime : Bool
  depth : Bool
  child_counts : Bool
  parent_path : Bool
}

///|
/// Build a requirement set; unnamed fields default to `false`.
fn ScanNeeds::new(
  name~ : Bool = false,
  path~ : Bool = false,
  size~ : Bool = false,
  mtime~ : Bool = false,
  depth~ : Bool = false,
  child_counts~ : Bool = false,
  parent_path~ : Bool = false,
) -> ScanNeeds {
  { name, path, size, mtime, depth, child_counts, parent_path, }
}

///|
/// A requirement set that computes every optional field.
fn ScanNeeds::all() -> ScanNeeds {
  ScanNeeds::new(
    name=true,
    path=true,
    size=true,
    mtime=true,
    depth=true,
    child_counts=true,
    parent_path=true,
  )
}

///|
/// Union of two requirement sets.
fn ScanNeeds::union(self : ScanNeeds, other : ScanNeeds) -> ScanNeeds {
  ScanNeeds::new(
    name=self.name || other.name,
    path=self.path || other.path,
    size=self.size || other.size,
    mtime=self.mtime || other.mtime,
    depth=self.depth || other.depth,
    child_counts=self.child_counts || other.child_counts,
    parent_path=self.parent_path || other.parent_path,
  )
}

///|
/// Build a view from one immutable Store entry with every optional field.
///
/// Prefer `of_store_for` inside the executor; this constructor is kept for
/// callers that genuinely need the complete view.
pub fn EntryView::of_store(
  store : @core.Store,
  entry : @core.EntryRef,
) -> EntryView {
  EntryView::of_store_for(store, entry, ScanNeeds::all())
}

///|
/// Build a view that materializes only the fields in `needs`.
fn EntryView::of_store_for(
  store : @core.Store,
  entry : @core.EntryRef,
  needs : ScanNeeds,
) -> EntryView {
  let (flags, parent_id, child_count, num_files, num_folders) = match
    entry.kind {
    @core.Folder =>
      match store.folder(entry.id) {
        Some(folder) =>
          (
            folder.flags(),
            folder.parent(),
            folder.child_count(),
            folder.num_files(),
            folder.num_folders(),
          )
        None => (0, @core.NO_PARENT, 0, 0, 0)
      }
    @core.File =>
      match store.file(entry.id) {
        Some(file) => (file.flags(), file.parent(), 0U, 0U, 0U)
        None => (0, @core.NO_PARENT, 0, 0, 0)
      }
  }
  let parent_path = if needs.parent_path && parent_id >= 0 {
    Some(store.folder_path(parent_id))
  } else {
    None
  }
  {
    path: if needs.path {
      store.entry_path(entry)
    } else {
      b""
    },
    name: if needs.name {
      store.entry_name(entry).to_owned()
    } else {
      b""
    },
    kind: entry.kind,
    size: if needs.size {
      store.entry_size(entry).unwrap_or(0L)
    } else {
      0L
    },
    mtime: if needs.mtime {
      store.entry_mtime(entry).unwrap_or(0L)
    } else {
      0L
    },
    flags,
    depth: if needs.depth {
      view_depth(store, entry)
    } else {
      0
    },
    parent_path,
    child_count: if needs.child_counts {
      child_count
    } else {
      0U
    },
    num_files: if needs.child_counts {
      num_files
    } else {
      0U
    },
    num_folders: if needs.child_counts {
      num_folders
    } else {
      0U
    },
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
