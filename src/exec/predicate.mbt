///|
/// Evaluate a compiled expression against one entry.
///
/// The tree is short-circuiting: an `AND` stops at the first false branch, an
/// `OR` at the first true one. `NOT` is the complement over every entry in the
/// store, which is what `MIGRATION_PLAN.md` section 5.8.1 means when it gives a
/// negation the `Both` domain.
fn eval_expr(
  expr : ScanExpr,
  store : @core.Store,
  entry : @core.EntryRef,
) -> Bool {
  match expr {
    All => true
    None => false
    Test(term) => eval_term(term, store, entry)
    And(left, right) =>
      eval_expr(left, store, entry) && eval_expr(right, store, entry)
    Or(left, right) =>
      eval_expr(left, store, entry) || eval_expr(right, store, entry)
    Not(inner) => !eval_expr(inner, store, entry)
  }
}

///|
/// Evaluate one leaf predicate.
fn eval_term(
  term : ScanTerm,
  store : @core.Store,
  entry : @core.EntryRef,
) -> Bool {
  if !kind_allows(term.kind, entry.kind) {
    return false
  }
  if !visibility_allows(term.visibility, store, entry) {
    return false
  }
  match term.body {
    Name(matcher) => match_name(store, entry, matcher)
    Kind(kind) => kind_allows(kind, entry.kind)
    Visibility(filter) => visibility_allows(filter, store, entry)
    Category(_, extensions) => match_extensions(store, entry, extensions)
    Extensions(list) => match_extensions(store, entry, list)
    Size(comparison) => compare_number(comparison, entry_size(store, entry))
    Depth(comparison) =>
      compare_number(comparison, entry_depth(store, entry).to_int64())
    ChildCount(comparison) => match_child_count(store, entry, 0, comparison)
    ChildFileCount(comparison) => match_child_count(store, entry, 1, comparison)
    ChildFolderCount(comparison) =>
      match_child_count(store, entry, 2, comparison)
    Modified(comparison) =>
      compare_number(comparison, entry_mtime(store, entry))
    Parent(path) => match_parent(store, entry, path)
    Empty =>
      if entry.kind is @core.File {
        false
      } else {
        match store.folder(entry.id) {
          Some(folder) => folder.child_count() == 0U
          None => false
        }
      }
    ContentType(text) => match_content_type(store, entry, text)
  }
}

///|
/// Whether a kind filter admits an entry kind.
fn kind_allows(filter : @query.KindFilter, kind : @core.EntryKind) -> Bool {
  match filter {
    @query.AnyKind => true
    @query.FilesOnly => kind is @core.File
    @query.FoldersOnly => kind is @core.Folder
  }
}

///|
/// Whether a visibility filter admits an entry.
///
/// Hidden means the dot-prefixed name flag recorded by the scanner; the field
/// dictionary builds the same set from the same flag.
fn visibility_allows(
  filter : @query.VisibilityFilter,
  store : @core.Store,
  entry : @core.EntryRef,
) -> Bool {
  match filter {
    @query.AnyVisibility => true
    @query.HiddenOnly => entry_is_hidden(store, entry)
    @query.VisibleOnly => !entry_is_hidden(store, entry)
  }
}

///|
/// Whether the entry carries the hidden flag, defaulting to `false` when the
/// id is out of range.
fn entry_is_hidden(store : @core.Store, entry : @core.EntryRef) -> Bool {
  match entry.kind {
    @core.Folder =>
      match store.folder(entry.id) {
        Some(folder) => folder.is_hidden()
        None => false
      }
    @core.File =>
      match store.file(entry.id) {
        Some(file) => file.is_hidden()
        None => false
      }
  }
}

///|
/// Evaluate a numeric comparison.
fn compare_number(comparison : @query.Comparison, value : Int64) -> Bool {
  match comparison.op {
    @query.Equal => value == comparison.lo
    @query.Greater => value > comparison.lo
    @query.GreaterEqual => value >= comparison.lo
    @query.Smaller => value < comparison.lo
    @query.SmallerEqual => value <= comparison.lo
    @query.Range => value >= comparison.lo && value < comparison.hi
  }
}

///|
/// Match a name term against the name or the full path.
fn match_name(
  store : @core.Store,
  entry : @core.EntryRef,
  matcher : NameMatcher,
) -> Bool {
  let text : BytesView = if matcher.path {
    store.entry_path(entry)[:]
  } else {
    store.entry_name(entry)
  }
  match matcher.kind {
    Substring =>
      @util.contains_bytes_with(text, matcher.needle[:], matcher.fold)
    Exact => @util.eq_bytes(text, matcher.needle[:], matcher.fold)
    Glob => @util.glob_match_with(text, matcher.needle[:], matcher.fold)
    Regex =>
      match matcher.regex {
        Some(regex) => match_regex(regex, text)
        None => false
      }
  }
}

///|
/// Run a compiled regex against name bytes.
///
/// Invalid UTF-8 cannot be represented as a `String` and is treated as a
/// non-match, as `MIGRATION_PLAN.md` section 5.11 specifies.
fn match_regex(regex : @string.Regex, text : BytesView) -> Bool {
  let decoded = Ok(@utf8.decode(text)) catch { _ => Err(()) }
  match decoded {
    Ok(value) => regex.execute(value) is Some(_)
    Err(_) => false
  }
}

///|
/// Match an extension list. `ext:` only applies to files.
fn match_extensions(
  store : @core.Store,
  entry : @core.EntryRef,
  list : Array[Bytes],
) -> Bool {
  if entry.kind is @core.Folder {
    return false
  }
  let extension = @util.extension_of(store.entry_name(entry))
  for candidate in list {
    if @util.eq_bytes(extension, candidate[:], true) {
      return true
    }
  }
  false
}

///|
/// The three child-count fields share one implementation.
fn match_child_count(
  store : @core.Store,
  entry : @core.EntryRef,
  field : Int32,
  comparison : @query.Comparison,
) -> Bool {
  if entry.kind is @core.File {
    return false
  }
  match store.folder(entry.id) {
    Some(folder) => {
      let value = match field {
        0 => folder.child_count()
        1 => folder.num_files()
        _ => folder.num_folders()
      }
      compare_number(comparison, value.to_int64())
    }
    None => false
  }
}

///|
/// Size of one entry, defaulting to zero for an out-of-range id.
fn entry_size(store : @core.Store, entry : @core.EntryRef) -> Int64 {
  match store.entry_size(entry) {
    Some(value) => value
    None => 0L
  }
}

///|
/// Modification time of one entry, defaulting to zero for an out-of-range id.
fn entry_mtime(store : @core.Store, entry : @core.EntryRef) -> Int64 {
  match store.entry_mtime(entry) {
    Some(value) => value
    None => 0L
  }
}

///|
/// Folder depth of an entry: roots are 0, their direct children 1.
fn entry_depth(store : @core.Store, entry : @core.EntryRef) -> Int32 {
  match entry.kind {
    @core.Folder => folder_depth(store, entry.id)
    @core.File =>
      match store.file(entry.id) {
        Some(file) => folder_depth(store, file.parent()) + 1
        None => 0
      }
  }
}

///|
/// Number of parent links above a folder. The folder itself is not counted, so
/// a root is zero.
fn folder_depth(store : @core.Store, id : @core.FolderId) -> Int32 {
  let mut depth = 0
  let mut current = id
  while current >= 0 {
    match store.folder(current) {
      Some(folder) => {
        depth = depth + 1
        current = folder.parent()
      }
      None => break
    }
  }
  depth - 1
}

///|
/// Match `parent:` against the full path of the entry's parent folder.
///
/// Roots have no parent and never match. Paths are compared byte for byte; the
/// query side is normalized once at compile time.
fn match_parent(
  store : @core.Store,
  entry : @core.EntryRef,
  target : Bytes,
) -> Bool {
  let parent = match entry.kind {
    @core.Folder =>
      match store.folder(entry.id) {
        Some(folder) => Some(folder.parent())
        None => None
      }
    @core.File =>
      match store.file(entry.id) {
        Some(file) => Some(file.parent())
        None => None
      }
  }
  match parent {
    Some(id) =>
      if id < 0 {
        false
      } else {
        @util.eq_bytes(store.folder_path(id)[:], target[:], false)
      }
    None => false
  }
}
