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
/// id before any recursion happens. Sizes and child counts are filled in on the
/// way out (post-order), so each directory is updated exactly once.
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
