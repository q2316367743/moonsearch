///|
/// Evaluate a compiled expression against one entry view.
fn eval_expr(expr : ScanExpr, entry : EntryView) -> Bool {
  match expr {
    All => true
    None => false
    Test(term) => eval_term(term, entry)
    And(left, right) => eval_expr(left, entry) && eval_expr(right, entry)
    Or(left, right) => eval_expr(left, entry) || eval_expr(right, entry)
    Not(inner) => !eval_expr(inner, entry)
  }
}

///|
/// Evaluate one leaf predicate.
fn eval_term(term : ScanTerm, entry : EntryView) -> Bool {
  if !kind_allows(term.kind, entry.kind) {
    return false
  }
  if !visibility_allows(term.visibility, entry) {
    return false
  }
  match term.body {
    Name(matcher) => match_name(entry, matcher)
    Kind(kind) => kind_allows(kind, entry.kind)
    Visibility(filter) => visibility_allows(filter, entry)
    Category(_, extensions) => match_extensions(entry, extensions)
    Extensions(list) => match_extensions(entry, list)
    Size(comparison) => compare_number(comparison, entry.size)
    Depth(comparison) => compare_number(comparison, entry.depth.to_int64())
    ChildCount(comparison) =>
      entry.kind is @core.Folder &&
      compare_number(comparison, entry.child_count.to_int64())
    ChildFileCount(comparison) =>
      entry.kind is @core.Folder &&
      compare_number(comparison, entry.num_files.to_int64())
    ChildFolderCount(comparison) =>
      entry.kind is @core.Folder &&
      compare_number(comparison, entry.num_folders.to_int64())
    Modified(comparison) => compare_number(comparison, entry.mtime)
    Parent(path) => match_parent(entry, path)
    Empty =>
      if entry.kind is @core.File {
        false
      } else {
        entry.child_count == 0U
      }
    ContentType(text) => match_content_type(entry, text)
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
fn visibility_allows(
  filter : @query.VisibilityFilter,
  entry : EntryView,
) -> Bool {
  let hidden = (entry.flags & @core.ENTRY_FLAG_HIDDEN) != 0
  match filter {
    @query.AnyVisibility => true
    @query.HiddenOnly => hidden
    @query.VisibleOnly => !hidden
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
fn match_name(entry : EntryView, matcher : NameMatcher) -> Bool {
  let text : BytesView = if matcher.path {
    entry.path[:]
  } else {
    entry.name[:]
  }
  match matcher.kind {
    Substring =>
      @util.contains_bytes_with(text, matcher.needle[:], matcher.fold)
    Exact => @util.eq_bytes(text, matcher.needle[:], matcher.fold)
    Glob => @util.glob_match_with(text, matcher.needle[:], matcher.fold)
    Regex =>
      match matcher.regex {
        Some(regex) => regex.matches_bytes(text)
        None => false
      }
  }
}

///|
/// Match an extension list. `ext:` only applies to files.
fn match_extensions(entry : EntryView, list : Array[Bytes]) -> Bool {
  if entry.kind is @core.Folder {
    return false
  }
  let extension = @util.extension_of(entry.name[:])
  for candidate in list {
    if @util.eq_bytes(extension, candidate[:], true) {
      return true
    }
  }
  false
}

///|
/// Match `parent:` against the full path of the entry's parent folder.
fn match_parent(entry : EntryView, target : Bytes) -> Bool {
  match entry.parent_path {
    Some(parent) => @util.eq_bytes(parent[:], target[:], false)
    None => false
  }
}
