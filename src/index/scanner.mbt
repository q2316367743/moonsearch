///|
/// One configured root.
pub(all) struct RootSpec {
  path : Bytes
  one_file_system : Bool
}

///|
/// Build a root specification.
pub fn RootSpec::new(
  path~ : BytesView,
  one_file_system~ : Bool = false,
) -> RootSpec {
  { path: path.to_owned(), one_file_system, }
}

///|
/// How the scanner handles a directory it cannot read.
pub(all) enum UnreadableDirectoryPolicy {
  /// Record a `ScanIssue` and continue with empty statistics for that directory.
  Continue
  /// Abort the scan with `IndexError::UnreadableDirectory`.
  Fatal
}

///|
/// Inputs to a scan.
pub(all) struct ScanConfig {
  roots : Array[RootSpec]
  excludes : Array[ExcludeRule]
  exclude_hidden : Bool
  /// Reject a root that is nested inside another root.
  allow_nested_roots : Bool
  /// Skip the pseudo file systems `/proc`, `/sys`, `/dev`, and `/run` when a
  /// root covers them.
  default_excludes : Bool
  /// Whether a permission-denied directory aborts the scan. Entry races and
  /// other recoverable I/O failures remain `ScanIssue`s under either policy.
  unreadable_directories : UnreadableDirectoryPolicy
}

///|
/// Build a scan configuration with the common defaults.
pub fn ScanConfig::new(
  roots~ : Array[RootSpec],
  excludes~ : Array[ExcludeRule] = [],
  exclude_hidden~ : Bool = false,
  allow_nested_roots~ : Bool = false,
  default_excludes~ : Bool = true,
  unreadable_directories~ : UnreadableDirectoryPolicy = Continue,
) -> ScanConfig {
  {
    roots,
    excludes,
    exclude_hidden,
    allow_nested_roots,
    default_excludes,
    unreadable_directories,
  }
}

///|
/// A recoverable scan problem.
///
/// The scan keeps going and the command still succeeds; the CLI prints these
/// only with `--verbose`. Typical causes are a permission-denied subdirectory,
/// an entry that vanished between `readdir` and `lstat`, a name that does not
/// fit in the index, or cumulative size overflow.
pub(all) struct ScanIssue {
  path : Bytes
  message : String
}

///|
/// Everything a scan produced.
pub(all) struct ScanReport {
  store : @core.Store
  issues : Array[ScanIssue]
  skipped_hidden : Int32
  skipped_excluded : Int32
  skipped_mount : Int32
  /// Whether the backend could supply device ids, and therefore whether
  /// one-file-system filtering was enforceable.
  device_ids_available : Bool
}

///|
/// Subtree totals below one directory.
///
/// `folders` counts the folders found below the directory, not the directory
/// itself. These totals become the `RootInfo` statistics and are also what each
/// parent folder adds to its own size.
priv struct Totals {
  files : UInt32
  folders : UInt32
  size : Int64
}

///|
/// Mutable state shared by the recursive scan.
priv struct ScanCtx {
  builder : Builder
  excludes : Array[ExcludeRule]
  exclude_hidden : Bool
  default_excludes : Bool
  unreadable_directories : UnreadableDirectoryPolicy
  issues : Array[ScanIssue]
  mut skipped_hidden : Int32
  mut skipped_excluded : Int32
  mut skipped_mount : Int32
  mut total_file_size : Int64
  mut size_overflow_reported : Bool
}

///|
fn ScanCtx::new(config : ScanConfig, builder : Builder) -> ScanCtx {
  {
    builder,
    excludes: config.excludes,
    exclude_hidden: config.exclude_hidden,
    default_excludes: config.default_excludes,
    unreadable_directories: config.unreadable_directories,
    issues: [],
    skipped_hidden: 0,
    skipped_excluded: 0,
    skipped_mount: 0,
    total_file_size: 0L,
    size_overflow_reported: false,
  }
}

///|
fn ScanCtx::record(
  self : ScanCtx,
  path : BytesView,
  message : StringView,
) -> Unit {
  self.issues.push({ path: path.to_owned(), message: "\{message}", })
}

///|
/// Saturate one cumulative size and report overflow at most once per scan.
fn ScanCtx::add_size(
  self : ScanCtx,
  path : BytesView,
  current : Int64,
  delta : Int64,
) -> Int64 {
  let (next, overflowed) = @core.saturating_add(current, delta)
  if overflowed && !self.size_overflow_reported {
    self.size_overflow_reported = true
    self.record(
      path, "size overflow: cumulative size saturated at the Int64 limit",
    )
  }
  next
}

///|
/// Whether a directory is one of the default pseudo file systems.
fn is_default_excluded(path : BytesView) -> Bool {
  @util.eq_bytes(path, b"/proc", false) ||
  @util.eq_bytes(path, b"/sys", false) ||
  @util.eq_bytes(path, b"/dev", false) ||
  @util.eq_bytes(path, b"/run", false)
}

///|
/// Whether a name starts with a dot.
fn is_hidden_name(name : BytesView) -> Bool {
  !name.is_empty() && name[0] == b'.'
}

///|
/// Scan one root and append its entries to the builder.
///
/// The root folder is created before its children (pre-order), which fixes its
/// temporary builder id before any recursion happens. Sizes and child counts are
/// filled in on the way out (post-order), so each directory is updated exactly
/// once; `Store::new` canonicalizes and remaps all ids after the scan.
async fn[Source : @platform.ScanSource] scan_root(
  source : Source,
  spec : RootSpec,
  ctx : ScanCtx,
) -> Unit raise IndexError {
  let info = source.stat(spec.path) catch {
    @platform.NotFound(_) => raise RootMissing(spec.path)
    @platform.NotDirectory(_) => raise RootNotDirectory(spec.path)
    err => raise Io(err.message())
  }
  if !(info.kind is Directory) {
    raise RootNotDirectory(spec.path)
  }
  let root_id = ctx.builder.add_root(
    spec.path,
    spec.one_file_system,
    info.mtime,
  )
  let root_index = ctx.builder.root_count() - 1
  let totals = scan_children(
    source,
    spec.path,
    root_id,
    ctx,
    spec.one_file_system && source.has_devices(),
    info.device,
  )
  ctx.builder.set_root_stats(
    root_index,
    totals.files,
    totals.folders,
    totals.size,
  )
}

///|
/// Scan the children of `path`, which is stored as folder `folder`.
async fn[Source : @platform.ScanSource] scan_children(
  source : Source,
  path : Bytes,
  folder : @core.FolderId,
  ctx : ScanCtx,
  one_file_system : Bool,
  root_device : UInt64?,
) -> Totals raise IndexError {
  let listing = source.list(path) catch {
    err => {
      match err {
        @platform.AccessDenied(_) if ctx.unreadable_directories is Fatal =>
          raise UnreadableDirectory(path)
        _ => ()
      }
      ctx.record(path, err.message())
      { entries: [], failures: [], }
    }
  }
  for failure in listing.failures {
    ctx.record(@util.join_path(path, failure.name), failure.message)
  }
  let mut direct_files = 0U
  let mut direct_folders = 0U
  let mut total_files = 0U
  let mut total_folders = 0U
  let mut total_size = 0L
  listing.entries.sort_by(fn(left, right) {
    @util.cmp_paths(left.name[:], right.name[:])
  })
  for entry in listing.entries {
    let name = entry.name
    let child_path = @util.join_path(path, name)
    let is_dir = entry.kind is Directory
    if name.length() > @core.MAX_NAME_LEN {
      ctx.record(child_path, "name does not fit in the index")
      continue
    }
    if ctx.exclude_hidden && is_hidden_name(name) {
      ctx.skipped_hidden = ctx.skipped_hidden + 1
      continue
    }
    if any_rule_matches(ctx.excludes, child_path, name, is_dir) {
      ctx.skipped_excluded = ctx.skipped_excluded + 1
      continue
    }
    if is_dir && ctx.default_excludes && is_default_excluded(child_path) {
      ctx.skipped_excluded = ctx.skipped_excluded + 1
      continue
    }
    if cross_device(entry.device, root_device, one_file_system) {
      ctx.skipped_mount = ctx.skipped_mount + 1
      continue
    }
    let flags = entry_flags(entry)
    if is_dir {
      let child_id = ctx.builder.add_folder(folder, name, entry.mtime, flags~)
      let subtree = scan_children(
        source, child_path, child_id, ctx, one_file_system, root_device,
      )
      direct_folders = direct_folders + 1
      total_folders = total_folders + 1U + subtree.folders
      total_files = total_files + subtree.files
      total_size = ctx.add_size(child_path, total_size, subtree.size)
    } else {
      ignore(
        ctx.builder.add_file(folder, name, entry.size, entry.mtime, flags~),
      )
      direct_files = direct_files + 1
      total_files = total_files + 1U
      total_size = ctx.add_size(child_path, total_size, entry.size)
      ctx.total_file_size = ctx.add_size(
        child_path,
        ctx.total_file_size,
        entry.size,
      )
    }
  }
  ctx.builder.set_child_counts(folder, direct_files, direct_folders)
  ctx.builder.add_folder_size(folder, total_size)
  { files: total_files, folders: total_folders, size: total_size, }
}

///|
/// Whether a directory entry lives on a different device than the root.
///
/// The check applies to every entry, not just directories: a bind-mounted
/// regular file also crosses a file system boundary. Unknown device ids disable
/// the check for that entry: a backend that cannot supply `st_dev` must not
/// silently drop content.
fn cross_device(
  device : UInt64?,
  root_device : UInt64?,
  enabled : Bool,
) -> Bool {
  if !enabled {
    return false
  }
  match (root_device, device) {
    (Some(root), Some(child)) => root != child
    _ => false
  }
}

///|
/// Flags recorded for one entry.
fn entry_flags(entry : @platform.NodeInfo) -> UInt16 {
  let mut flags : UInt16 = 0
  if is_hidden_name(entry.name) {
    flags = flags | @core.ENTRY_FLAG_HIDDEN
  }
  match entry.kind {
    Symlink => flags = flags | @core.ENTRY_FLAG_SYMLINK
    Other => flags = flags | @core.ENTRY_FLAG_SPECIAL
    _ => ()
  }
  flags
}

///|
/// Normalize roots and reject duplicates or nested roots.
///
/// Duplicates are dropped silently; nesting is an error unless
/// `allow_nested_roots` is set, because it would index the same subtree twice
/// under two different parents.
async fn[Source : @platform.ScanSource] normalize_roots(
  config : ScanConfig,
  source : Source,
) -> Array[RootSpec] raise IndexError {
  let result : Array[RootSpec] = []
  for spec in config.roots {
    let resolved = source.realpath(spec.path) catch {
      @platform.NotFound(_) => raise RootMissing(spec.path)
      err => raise Io(err.message())
    }
    let mut duplicate = false
    for existing in result {
      if existing.path == resolved {
        duplicate = true
      }
    }
    if duplicate {
      continue
    }
    if !config.allow_nested_roots {
      for existing in result {
        if @util.is_within(existing.path, resolved) ||
          @util.is_within(resolved, existing.path) {
          raise NestedRoots(outer=existing.path, nested=resolved)
        }
      }
    }
    result.push({ path: resolved, one_file_system: spec.one_file_system, })
  }
  result
}

///|
/// One entry observed by the cancellable live traversal.
pub(all) struct ScanEntry {
  path : Bytes
  name : Bytes
  kind : @core.EntryKind
  size : Int64
  mtime : Int64
  flags : UInt16
  depth : Int32
  parent_path : Bytes?
}

///|
/// Visitor control for the live traversal.
pub(all) enum VisitDecision {
  Continue
  Stop
}

///|
/// Partial scan diagnostics. Counts describe only the traversed prefix when the
/// visitor stops early.
pub(all) struct WalkReport {
  issues : Array[ScanIssue]
  skipped_hidden : Int32
  skipped_excluded : Int32
  skipped_mount : Int32
  device_ids_available : Bool
  directories_listed : Int32
  entries_seen : Int32
  entries_evaluated : Int32
  stopped_early : Bool
}

///|
/// Mutable state for the live traversal.
priv struct WalkCtx {
  excludes : Array[ExcludeRule]
  exclude_hidden : Bool
  default_excludes : Bool
  unreadable_directories : UnreadableDirectoryPolicy
  issues : Array[ScanIssue]
  mut skipped_hidden : Int32
  mut skipped_excluded : Int32
  mut skipped_mount : Int32
  mut directories_listed : Int32
  mut entries_seen : Int32
  mut entries_evaluated : Int32
}

///|
fn WalkCtx::new(config : ScanConfig) -> WalkCtx {
  {
    excludes: config.excludes,
    exclude_hidden: config.exclude_hidden,
    default_excludes: config.default_excludes,
    unreadable_directories: config.unreadable_directories,
    issues: [],
    skipped_hidden: 0,
    skipped_excluded: 0,
    skipped_mount: 0,
    directories_listed: 0,
    entries_seen: 0,
    entries_evaluated: 0,
  }
}

///|
fn WalkCtx::record(
  self : WalkCtx,
  path : BytesView,
  message : StringView,
) -> Unit {
  self.issues.push({ path: path.to_owned(), message: "\{message}", })
}

///|
/// One sorted directory stream on the depth-first walk stack.
priv struct WalkFrame {
  parent_path : Bytes
  depth : Int32
  entries : Array[@platform.NodeInfo]
  mut index : Int32
  one_file_system : Bool
  root_device : UInt64?
}

///|
/// Read a directory, retaining recoverable failures in the walk report.
async fn[Source : @platform.ScanSource] walk_listing(
  source : Source,
  path : Bytes,
  ctx : WalkCtx,
) -> @platform.DirListing raise IndexError {
  ctx.directories_listed = ctx.directories_listed + 1
  let listing = source.list(path) catch {
    err => {
      if err is @platform.AccessDenied(_) && ctx.unreadable_directories is Fatal {
        raise UnreadableDirectory(path)
      }
      ctx.record(path, err.message())
      return @platform.DirListing::new(entries=[], failures=[])
    }
  }
  for failure in listing.failures {
    ctx.record(@util.join_path(path, failure.name), failure.message)
  }
  listing.entries.sort_by(fn(left, right) {
    @util.cmp_paths(left.name[:], right.name[:])
  })
  listing
}

///|
/// Select the deepest open directory stream.
///
/// This is depth-first traversal: once a folder is emitted and opened, its
/// sorted children are visited before returning to later siblings. Streaming
/// cannot reproduce Store's global `(name, path)` order without listing every
/// directory first, which would defeat early stopping.
fn next_walk_entry(frames : Array[WalkFrame]) -> (Int32, @platform.NodeInfo)? {
  let mut index = frames.length() - 1
  while index >= 0 {
    let frame = frames[index]
    if frame.index < frame.entries.length() {
      let entry = frame.entries[frame.index]
      frames[index].index = frame.index + 1
      return Some((index, entry))
    }
    index = index - 1
  }
  None
}

///|
/// Walk roots in deterministic depth-first order without building a Store.
///
/// Each directory is materialized one at a time and its entries are sorted by
/// name. Entries are matched and emitted incrementally; Store's global
/// `(name, path)` order is deliberately not promised because reproducing it
/// requires listing every directory before the first result.
pub async fn[Source : @platform.ScanSource] scan_stream(
  config : ScanConfig,
  source : Source,
  visitor : async (ScanEntry) -> VisitDecision noraise,
) -> WalkReport raise IndexError {
  let roots = normalize_roots(config, source)
  roots.sort_by(fn(left, right) { @util.cmp_paths(left.path[:], right.path[:]) })
  let ctx = WalkCtx::new(config)
  let frames : Array[WalkFrame] = []
  let mut root_index = 0
  let mut stopped_early = false
  while root_index < roots.length() || !frames.is_empty() {
    @async.pause()
    while !frames.is_empty() &&
          frames[frames.length() - 1].index >=
          frames[frames.length() - 1].entries.length() {
      ignore(frames.pop())
    }
    let next = if root_index < roots.length() && frames.is_empty() {
      let spec = roots[root_index]
      root_index = root_index + 1
      let info = source.stat(spec.path) catch {
        @platform.NotFound(_) => raise RootMissing(spec.path)
        @platform.NotDirectory(_) => raise RootNotDirectory(spec.path)
        err => raise Io(err.message())
      }
      if !(info.kind is Directory) {
        raise RootNotDirectory(spec.path)
      }
      Some((spec, info))
    } else {
      None
    }
    match next {
      Some((spec, info)) => {
        ctx.entries_evaluated = ctx.entries_evaluated + 1
        let decision = visitor({
          path: spec.path,
          name: spec.path,
          kind: @core.Folder,
          size: 0L,
          mtime: info.mtime,
          flags: 0,
          depth: 0,
          parent_path: None,
        })
        if decision is Stop {
          stopped_early = true
          break
        }
        let listing = walk_listing(source, spec.path, ctx)
        frames.push({
          parent_path: spec.path,
          depth: 1,
          entries: listing.entries,
          index: 0,
          one_file_system: spec.one_file_system && source.has_devices(),
          root_device: info.device,
        })
        continue
      }
      None => ()
    }
    let candidate = next_walk_entry(frames)
    if candidate is None {
      break
    }
    let (frame_index, entry) = match candidate {
      Some(value) => value
      None => break
    }
    let frame = frames[frame_index]
    let child_path = @util.join_path(frame.parent_path, entry.name)
    let is_dir = entry.kind is Directory
    ctx.entries_seen = ctx.entries_seen + 1
    if entry.name.length() > @core.MAX_NAME_LEN {
      ctx.record(child_path, "name does not fit in the index")
      continue
    }
    if ctx.exclude_hidden && is_hidden_name(entry.name) {
      ctx.skipped_hidden = ctx.skipped_hidden + 1
      continue
    }
    if any_rule_matches(ctx.excludes, child_path, entry.name, is_dir) {
      ctx.skipped_excluded = ctx.skipped_excluded + 1
      continue
    }
    if is_dir && ctx.default_excludes && is_default_excluded(child_path) {
      ctx.skipped_excluded = ctx.skipped_excluded + 1
      continue
    }
    if cross_device(entry.device, frame.root_device, frame.one_file_system) {
      ctx.skipped_mount = ctx.skipped_mount + 1
      continue
    }
    ctx.entries_evaluated = ctx.entries_evaluated + 1
    let decision = visitor({
      path: child_path,
      name: entry.name,
      kind: if is_dir {
        @core.Folder
      } else {
        @core.File
      },
      size: if is_dir {
        0L
      } else {
        entry.size
      },
      mtime: entry.mtime,
      flags: entry_flags(entry),
      depth: frame.depth,
      parent_path: Some(frame.parent_path),
    })
    if decision is Stop {
      stopped_early = true
      break
    }
    if is_dir {
      let listing = walk_listing(source, child_path, ctx)
      frames.push({
        parent_path: child_path,
        depth: frame.depth + 1,
        entries: listing.entries,
        index: 0,
        one_file_system: frame.one_file_system,
        root_device: frame.root_device,
      })
    }
  }
  {
    issues: ctx.issues,
    skipped_hidden: ctx.skipped_hidden,
    skipped_excluded: ctx.skipped_excluded,
    skipped_mount: ctx.skipped_mount,
    device_ids_available: source.has_devices(),
    directories_listed: ctx.directories_listed,
    entries_seen: ctx.entries_seen,
    entries_evaluated: ctx.entries_evaluated,
    stopped_early,
  }
}

///|
/// Scan every configured root into a fresh in-memory store.
///
/// Configuration errors (a missing root, nested roots) raise `IndexError`.
/// Per-directory and per-entry failures are collected in `ScanReport::issues`
/// and do not abort the scan.
pub async fn[Source : @platform.ScanSource] scan(
  config : ScanConfig,
  source : Source,
) -> ScanReport raise IndexError {
  let roots = normalize_roots(config, source)
  let ctx = ScanCtx::new(config, Builder::new())
  for spec in roots {
    scan_root(source, spec, ctx)
  }
  let store = ctx.builder.finish()
  {
    store,
    issues: ctx.issues,
    skipped_hidden: ctx.skipped_hidden,
    skipped_excluded: ctx.skipped_excluded,
    skipped_mount: ctx.skipped_mount,
    device_ids_available: source.has_devices(),
  }
}
