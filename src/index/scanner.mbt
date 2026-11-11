///|
/// One configured root.
pub(all) struct RootSpec {
  path : String
  one_file_system : Bool
}

///|
/// Build a root specification.
pub fn RootSpec::new(
  path~ : String,
  one_file_system~ : Bool = false,
) -> RootSpec {
  { path, one_file_system, }
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
}

///|
/// Build a scan configuration with the common defaults.
pub fn ScanConfig::new(
  roots~ : Array[RootSpec],
  excludes~ : Array[ExcludeRule] = [],
  exclude_hidden~ : Bool = false,
  allow_nested_roots~ : Bool = false,
  default_excludes~ : Bool = true,
) -> ScanConfig {
  { roots, excludes, exclude_hidden, allow_nested_roots, default_excludes, }
}

///|
/// A recoverable scan problem.
///
/// The scan keeps going and the command still succeeds; the CLI prints these
/// only with `--verbose`. Typical causes are a permission-denied subdirectory,
/// an entry that vanished between `readdir` and `lstat`, or a name that does
/// not fit in the index.
pub(all) struct ScanIssue {
  path : String
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
  issues : Array[ScanIssue]
  mut skipped_hidden : Int32
  mut skipped_excluded : Int32
  mut skipped_mount : Int32
}

///|
fn ScanCtx::new(config : ScanConfig, builder : Builder) -> ScanCtx {
  {
    builder,
    excludes: config.excludes,
    exclude_hidden: config.exclude_hidden,
    default_excludes: config.default_excludes,
    issues: [],
    skipped_hidden: 0,
    skipped_excluded: 0,
    skipped_mount: 0,
  }
}

///|
fn ScanCtx::record(
  self : ScanCtx,
  path : StringView,
  message : StringView,
) -> Unit {
  self.issues.push({ path: "\{path}", message: "\{message}", })
}

///|
/// Whether a directory is one of the default pseudo file systems.
fn is_default_excluded(path : StringView) -> Bool {
  path == "/proc" || path == "/sys" || path == "/dev" || path == "/run"
}

///|
/// Whether a name starts with a dot.
fn is_hidden_name(name : String) -> Bool {
  name.get_char(0) is Some('.')
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
    spec.one_file_system,
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
  path : String,
  folder : @core.FolderId,
  ctx : ScanCtx,
  one_file_system : Bool,
  root_device : UInt64?,
) -> Totals raise IndexError {
  let listing = source.list(path) catch {
    err => {
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
  let keyed = listing.entries.map(fn(info) { (@utf8.encode(info.name), info) })
  keyed.sort_by(fn(left, right) { @util.cmp_paths(left.0[:], right.0[:]) })
  for pair in keyed {
    let entry = pair.1
    let name = entry.name
    let child_path = @util.join_path(path, name)
    let is_dir = entry.kind is Directory
    if pair.0.length() > @core.MAX_NAME_LEN {
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
    if cross_device(is_dir, entry.device, root_device, one_file_system) {
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
      total_size = total_size + subtree.size
    } else {
      ignore(
        ctx.builder.add_file(folder, name, entry.size, entry.mtime, flags~),
      )
      direct_files = direct_files + 1
      total_files = total_files + 1U
      total_size = total_size + entry.size
    }
  }
  ctx.builder.set_child_counts(folder, direct_files, direct_folders)
  ctx.builder.add_folder_size(folder, total_size)
  { files: total_files, folders: total_folders, size: total_size, }
}

///|
/// Whether a directory entry lives on a different device than the root.
///
/// Unknown device ids disable the check for that entry: a backend that cannot
/// supply `st_dev` must not silently drop content.
fn cross_device(
  is_dir : Bool,
  device : UInt64?,
  root_device : UInt64?,
  enabled : Bool,
) -> Bool {
  if !enabled || !is_dir {
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
