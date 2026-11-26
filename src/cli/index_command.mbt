///|
/// Values provided for an option, or an empty array.
fn option_values(matches : @argparse.Matches, name : String) -> Array[String] {
  match matches.values.get(name) {
    Some(values) => values
    None => []
  }
}

///|
/// First value of an option, if any.
fn first_option_value(matches : @argparse.Matches, name : String) -> String? {
  match option_values(matches, name).get(0) {
    Some(value) => Some(value)
    None => None
  }
}

///|
/// First option value only when it came from argv or the environment.
///
/// Argparse defaults are placeholders for help/rendering. Configuration values
/// must be allowed to replace them, so callers use this when merging settings.
fn explicit_option_value(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) =>
      match (values.get(0), matches.sources.get(name)) {
        (Some(""), Some(@argparse.Env)) => None
        (_, Some(@argparse.Default)) => None
        (value, _) => value
      }
    None => None
  }
}

///|
/// Whether a flag was set.
fn flag_set(matches : @argparse.Matches, name : String) -> Bool {
  matches.flags.get(name).unwrap_or(false)
}

///|
/// Parse `--exclude-scope`, falling back to the configured default.
fn exclude_scope_of(
  matches : @argparse.Matches,
  fallback : String,
) -> Result[@index.ExcludeScope, String] {
  match explicit_option_value(matches, "exclude-scope").unwrap_or(fallback) {
    "full_path" => Ok(@index.FullPath)
    "basename" => Ok(@index.Basename)
    other =>
      Err(
        "error: --exclude-scope must be full_path or basename, got '\{other}'",
      )
  }
}

///|
/// Parse `--exclude-target`, falling back to the configured default.
fn exclude_target_of(
  matches : @argparse.Matches,
  fallback : String,
) -> Result[@index.ExcludeTarget, String] {
  match explicit_option_value(matches, "exclude-target").unwrap_or(fallback) {
    "both" => Ok(@index.Both)
    "files" => Ok(@index.Files)
    "folders" => Ok(@index.Folders)
    other =>
      Err(
        "error: --exclude-target must be both, files, or folders, got '\{other}'",
      )
  }
}

///|
/// Parse the unreadable-directory policy.
fn unreadable_policy_of(
  invocation : Invocation,
) -> Result[@index.UnreadableDirectoryPolicy, String] {
  match explicit_option_value(invocation.matches, "unreadable-directories") {
    Some(value) =>
      match value {
        "continue" => Ok(@index.Continue)
        "fatal" => Ok(@index.Fatal)
        _ =>
          Err(
            "error: --unreadable-directories must be continue or fatal, got '\{value}'",
          )
      }
    None => Ok(invocation.config.unreadable_directories)
  }
}

///|
/// Whether one-file-system filtering is enabled by any source.
fn one_file_system_enabled(invocation : Invocation) -> Bool {
  flag_set(invocation.matches, "one-file-system") ||
  invocation.config.one_file_system.unwrap_or(false)
}

///|
/// Expand a command-line root.
fn cli_root(
  path : String,
  invocation : Invocation,
) -> Result[@index.RootSpec, String] {
  let env = effective_environment(invocation)
  let expanded = try @config.expand_path(path, env) catch {
    err => return Err("error: root \{path}: \{err.message()}")
  } noraise {
    value => value
  }
  Ok(
    @index.RootSpec::new(
      path=@utf8.encode(expanded),
      one_file_system=one_file_system_enabled(invocation),
    ),
  )
}

///|
/// Roots persisted by the database `update` reuses when neither CLI nor config
/// supplies roots. Raw root bytes are preserved.
async fn stored_roots(
  invocation : Invocation,
) -> Result[Array[@index.RootSpec], String] {
  let database = match database_path(invocation) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let exists = @fs.exists(database) catch { _ => false }
  if !exists {
    return Ok([])
  }
  let index = try @index.Index::read_database(database) catch {
    err =>
      return Err("error: cannot read roots from \{database}: \{err.message()}")
  } noraise {
    value => value
  }
  let roots : Array[@index.RootSpec] = []
  for root in index.store().roots() {
    let one_file_system = flag_set(invocation.matches, "one-file-system") ||
      invocation.config.one_file_system.unwrap_or(root.one_file_system)
    roots.push(@index.RootSpec::new(path=root.path, one_file_system~))
  }
  Ok(roots)
}

///|
/// Exclude rules persisted by the database `update` reuses when neither CLI nor
/// configuration supplies rules. Explicit roots do not clear this snapshot;
/// callers can replace it with `--exclude` or configured `excludes`.
async fn stored_excludes(
  invocation : Invocation,
) -> Result[Array[@index.ExcludeRule], String] {
  let database = match database_path(invocation) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let exists = @fs.exists(database) catch { _ => false }
  if !exists {
    return Ok([])
  }
  let index = try @index.Index::read_database(database) catch {
    err =>
      return Err(
        "error: cannot read excludes from \{database}: \{err.message()}",
      )
  } noraise {
    value => value
  }
  let rules : Array[@index.ExcludeRule] = []
  for rule in index.excludes() {
    rules.push(rule)
  }
  Ok(rules)
}

///|
/// Build the scan configuration from CLI, environment-backed options, config,
/// and defaults, in that order.
async fn scan_config_of(
  invocation : Invocation,
) -> Result[@index.ScanConfig, String] {
  let matches = invocation.matches
  let supplied_roots = option_values(matches, "root") +
    option_values(matches, "roots")
  let root_specs = if supplied_roots.is_empty() {
    if invocation.config.roots.is_empty() {
      if invocation.command is Update {
        match stored_roots(invocation) {
          Ok(roots) => roots
          Err(message) => return Err(message)
        }
      } else {
        []
      }
    } else {
      let roots : Array[@index.RootSpec] = []
      for root in invocation.config.roots {
        let one_file_system = flag_set(matches, "one-file-system") ||
          root.one_file_system.unwrap_or(
            invocation.config.one_file_system.unwrap_or(false),
          )
        roots.push(
          @index.RootSpec::new(path=@utf8.encode(root.path), one_file_system~),
        )
      }
      roots
    }
  } else {
    let roots : Array[@index.RootSpec] = []
    for path in supplied_roots {
      match cli_root(path, invocation) {
        Ok(root) => roots.push(root)
        Err(message) => return Err(message)
      }
    }
    roots
  }
  if root_specs.is_empty() {
    return Err(
      "error: no roots configured; pass --root <PATH> or a root argument",
    )
  }
  let scope = match
    exclude_scope_of(
      matches,
      match invocation.config.exclude_scope {
        @index.FullPath => "full_path"
        @index.Basename => "basename"
      },
    ) {
    Ok(scope) => scope
    Err(message) => return Err(message)
  }
  let target = match
    exclude_target_of(
      matches,
      match invocation.config.exclude_target {
        @index.Both => "both"
        @index.Files => "files"
        @index.Folders => "folders"
      },
    ) {
    Ok(target) => target
    Err(message) => return Err(message)
  }
  let mut excludes : Array[@index.ExcludeRule] = []
  let cli_excludes = option_values(matches, "exclude")
  if cli_excludes.is_empty() {
    if invocation.config.excludes.is_empty() && invocation.command is Update {
      match stored_excludes(invocation) {
        Ok(rules) => excludes = rules
        Err(message) => return Err(message)
      }
    } else {
      for rule in invocation.config.excludes {
        let parsed = try
          @index.ExcludeRule::new(
            kind=rule.kind,
            pattern=rule.pattern,
            scope=rule.scope,
            target=rule.target,
            active=rule.active,
          )
        catch {
          err => return Err("error: \{err.message()}")
        } noraise {
          value => value
        }
        excludes.push(parsed)
      }
    }
  } else {
    for spec in cli_excludes {
      let parsed = try @index.ExcludeRule::parse(spec, scope~, target~) catch {
        err => return Err("error: \{err.message()}")
      } noraise {
        rule => rule
      }
      excludes.push(parsed)
    }
  }
  let unreadable_directories = match unreadable_policy_of(invocation) {
    Ok(policy) => policy
    Err(message) => return Err(message)
  }
  Ok(
    @index.ScanConfig::new(
      roots=root_specs,
      excludes~,
      exclude_hidden=flag_set(matches, "exclude-hidden") ||
        invocation.config.exclude_hidden,
      allow_nested_roots=flag_set(matches, "allow-nested-roots") ||
        invocation.config.allow_nested_roots.unwrap_or(false),
      default_excludes=!flag_set(matches, "no-default-excludes") &&
        invocation.config.default_excludes.unwrap_or(true),
      unreadable_directories~,
    ),
  )
}

///|
/// Parse `--fast-fields`, then the configured selection, then `size,mtime`.
fn fast_fields_of(
  invocation : Invocation,
) -> Result[@index.RangeFieldSet, String] {
  match explicit_option_value(invocation.matches, "fast-fields") {
    Some(text) =>
      match @index.RangeFieldSet::parse(text) {
        Ok(fields) => Ok(fields)
        Err(message) => Err("error: \{message}")
      }
    None =>
      match invocation.config.fast_fields {
        Some(fields) => Ok(@index.RangeFieldSet::of(fields))
        None =>
          match @index.RangeFieldSet::parse("size,mtime") {
            Ok(fields) => Ok(fields)
            Err(message) => Err("error: \{message}")
          }
      }
  }
}

///|
/// Format the stable stdout summary.
fn summary_of(report : @index.ScanReport) -> String {
  let store = report.store
  let out = StringBuilder()
  out.write_string("roots: \{store.roots().length()}\n")
  out.write_string("folders: \{store.folder_count()}\n")
  out.write_string("files: \{store.file_count()}\n")
  out.write_string("bytes: \{store.total_size()}")
  let skipped = report.skipped_hidden +
    report.skipped_excluded +
    report.skipped_mount
  if skipped > 0 {
    out.write_string("\nskipped: \{skipped}")
  }
  if report.issues.length() > 0 {
    out.write_string("\nissues: \{report.issues.length()}")
  }
  out.to_string()
}

///|
/// Summarize the range indexes that were actually built.
///
/// Only loaded fields appear, so the line shows the effect of `--fast-fields`
/// instead of forcing every lazy field to materialize for statistics.
fn loaded_ranges(ranges : @index.Ranges) -> String {
  let parts : Array[String] = []
  for field in @index.RangeField::all() {
    if ranges.is_loaded(field) {
      parts.push("\{field.name()}=\{ranges.field(field).len()}")
    }
  }
  if parts.is_empty() {
    "none"
  } else {
    parts.join(" ")
  }
}

///|
/// Summarize the trigram index, or report that `--no-trigram` skipped it.
///
/// The byte figure is the in-memory posting arrays only; the database stores
/// the same postings as delta-varint ids in `POSTINGS`.
fn describe_trigram(trigram : @index.TrigramIndex?) -> String {
  match trigram {
    Some(index) =>
      "\{index.key_count()} keys, \{index.posting_count()} postings, \{index.short_name_count()} short names, \{index.stop_gram_count()} stop-grams, \{index.posting_bytes()} B"
    None => "disabled"
  }
}

///|
/// Build the `--verbose` / `--stats` diagnostics.
fn diagnostics_of(
  invocation : Invocation,
  report : @index.ScanReport,
  index : @index.Index,
  database : String,
  database_size : Int64,
  elapsed_ms : Int64,
) -> String {
  let matches = invocation.matches
  let verbose = flag_set(matches, "verbose")
  let stats = flag_set(matches, "stats")
  let out = StringBuilder()
  if verbose {
    for root in report.store.roots() {
      out.write_string(
        "root: \{@utf8.decode_lossy(root.path)} (files: \{root.files}, folders: \{root.folders}, bytes: \{root.size})\n",
      )
    }
    for issue in report.issues {
      out.write_string(
        "warning: \{@utf8.decode_lossy(issue.path)}: \{issue.message}\n",
      )
    }
  }
  if stats {
    let dict = index.dict()
    let ranges = index.ranges()
    out.write_string("scan: \{elapsed_ms} ms\n")
    out.write_string("database: \{database} (\{database_size} bytes)\n")
    out.write_string(
      "names: \{report.store.name_count()} names, \{report.store.name_bytes()} bytes\n",
    )
    out.write_string(
      "dict: \{dict.extension_count()} extensions, \{dict.type_category_count()} categories, \{dict.hidden().cardinality()} hidden\n",
    )
    out.write_string("ranges: \{loaded_ranges(ranges)}\n")
    out.write_string("trigram: \{describe_trigram(index.trigram())}\n")
    out.write_string(
      "skipped: hidden=\{report.skipped_hidden} excluded=\{report.skipped_excluded} mount=\{report.skipped_mount}\n",
    )
    out.write_string("issues: \{report.issues.length()}\n")
  }
  trim_trailing_newline(out.to_string())
}

///|
/// Remove one trailing newline, if present.
fn trim_trailing_newline(text : String) -> String {
  if text.length() > 0 && text.get_char(text.length() - 1) is Some('\n') {
    "\{text[:text.length() - 1]}"
  } else {
    text
  }
}

///|
/// Run `index` or `update`.
///
/// The scan builds the store, the candidate sources, and the trigram postings
/// in one pass, then writes the complete index to the database with an atomic
/// replace. A later `search` loads the same parts without rebuilding them.
async fn run_index(invocation : Invocation) -> CliResult {
  let config = match scan_config_of(invocation) {
    Ok(config) => config
    Err(message) => return Failure(message)
  }
  let fast_fields = match fast_fields_of(invocation) {
    Ok(fields) => fields
    Err(message) => return Failure(message)
  }
  let database = match database_path(invocation) {
    Ok(path) => path
    Err(message) => return Failure(message)
  }
  let started = @env.now()
  let outcome = try @index.scan(config, @platform.system_source()) catch {
    err => Err("error: \{err.message()}")
  } noraise {
    report => Ok(report)
  }
  let elapsed_ms = (@env.now() - started).reinterpret_as_int64()
  match outcome {
    Err(message) => Failure(message)
    Ok(report) => {
      let index = @index.Index::build(
        report.store,
        eager=fast_fields,
        trigram=!flag_set(invocation.matches, "no-trigram") &&
          invocation.config.trigram.unwrap_or(true),
        excludes=config.excludes,
      )
      let written : Result[Unit, String] = Ok(
        @index.Index::write_database(index, database),
      ) catch {
        err => Err("error: \{err.message()}")
      }
      match written {
        Err(message) => return Failure(message)
        Ok(_) => ()
      }
      let database_size = @fs.file_size(database) catch { _ => 0L }
      let quiet = flag_set(invocation.matches, "quiet")
      let mut diagnostics = if quiet {
        ""
      } else {
        diagnostics_of(
          invocation, report, index, database, database_size, elapsed_ms,
        )
      }
      let mut uses_one_file_system = false
      for root in config.roots {
        uses_one_file_system = uses_one_file_system || root.one_file_system
      }
      if uses_one_file_system && !report.device_ids_available {
        let warning = "warning: --one-file-system has no effect: this backend cannot read device ids"
        if diagnostics.is_empty() {
          diagnostics = warning
        } else {
          diagnostics = "\{diagnostics}\n\{warning}"
        }
      }
      if quiet {
        return SuccessWith(b"", diagnostics)
      }
      let summary = text_line(summary_of(report))
      if diagnostics.is_empty() {
        Success(summary)
      } else {
        SuccessWith(summary, diagnostics)
      }
    }
  }
}
