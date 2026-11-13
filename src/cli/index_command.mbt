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
/// Whether a flag was set.
fn flag_set(matches : @argparse.Matches, name : String) -> Bool {
  matches.flags.get(name).unwrap_or(false)
}

///|
/// Parse `--exclude-scope`.
fn exclude_scope_of(
  matches : @argparse.Matches,
) -> Result[@index.ExcludeScope, String] {
  match first_option_value(matches, "exclude-scope").unwrap_or("full_path") {
    "full_path" => Ok(@index.FullPath)
    "basename" => Ok(@index.Basename)
    other =>
      Err(
        "error: --exclude-scope must be full_path or basename, got '\{other}'",
      )
  }
}

///|
/// Parse `--exclude-target`.
fn exclude_target_of(
  matches : @argparse.Matches,
) -> Result[@index.ExcludeTarget, String] {
  match first_option_value(matches, "exclude-target").unwrap_or("both") {
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
/// Build the scan configuration from the parsed command line.
fn scan_config_of(invocation : Invocation) -> Result[@index.ScanConfig, String] {
  let matches = invocation.matches
  let roots = option_values(matches, "root") + option_values(matches, "roots")
  if roots.is_empty() {
    return Err(
      "error: no roots configured; pass --root <PATH> or a root argument",
    )
  }
  let scope = match exclude_scope_of(matches) {
    Ok(scope) => scope
    Err(message) => return Err(message)
  }
  let target = match exclude_target_of(matches) {
    Ok(target) => target
    Err(message) => return Err(message)
  }
  let excludes : Array[@index.ExcludeRule] = []
  for spec in option_values(matches, "exclude") {
    let parsed = try @index.ExcludeRule::parse(spec, scope~, target~) catch {
      err => Err(err.message())
    } noraise {
      rule => Ok(rule)
    }
    match parsed {
      Ok(rule) => excludes.push(rule)
      Err(message) => return Err("error: \{message}")
    }
  }
  let one_file_system = flag_set(matches, "one-file-system")
  let root_specs = roots.map(fn(path) {
    @index.RootSpec::new(path~, one_file_system~)
  })
  Ok(
    @index.ScanConfig::new(
      roots=root_specs,
      excludes~,
      exclude_hidden=flag_set(matches, "exclude-hidden"),
      allow_nested_roots=flag_set(matches, "allow-nested-roots"),
      default_excludes=!flag_set(matches, "no-default-excludes"),
    ),
  )
}

///|
/// Parse `--fast-fields` into the range fields built eagerly.
///
/// The default `size,mtime` keeps startup work low; the remaining fields are
/// built on first use by `Ranges`.
fn fast_fields_of(
  matches : @argparse.Matches,
) -> Result[@index.RangeFieldSet, String] {
  let text = first_option_value(matches, "fast-fields").unwrap_or("size,mtime")
  match @index.RangeFieldSet::parse(text) {
    Ok(fields) => Ok(fields)
    Err(message) => Err("error: \{message}")
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
/// The byte figure is the in-memory posting arrays only; S12 replaces them with
/// the delta-varint `POSTINGS` section on disk.
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
  dict : @index.Dict,
  ranges : @index.Ranges,
  trigram : @index.TrigramIndex?,
  elapsed_ms : Int64,
) -> String {
  let matches = invocation.matches
  let verbose = flag_set(matches, "verbose")
  let stats = flag_set(matches, "stats")
  let out = StringBuilder()
  if verbose {
    for root in report.store.roots() {
      out.write_string(
        "root: \{root.path} (files: \{root.files}, folders: \{root.folders}, bytes: \{root.size})\n",
      )
    }
    for issue in report.issues {
      out.write_string("warning: \{issue.path}: \{issue.message}\n")
    }
  }
  if stats {
    out.write_string("scan: \{elapsed_ms} ms\n")
    out.write_string(
      "names: \{report.store.name_count()} names, \{report.store.name_bytes()} bytes\n",
    )
    out.write_string(
      "dict: \{dict.extension_count()} extensions, \{dict.type_category_count()} categories, \{dict.hidden().cardinality()} hidden\n",
    )
    out.write_string("ranges: \{loaded_ranges(ranges)}\n")
    out.write_string("trigram: \{describe_trigram(trigram)}\n")
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
/// The store lives in memory until the persistence step; S07 materializes the
/// field dictionary as part of the build even though nothing consumes it yet.
/// Writing both to disk arrives with S12.
async fn run_index(invocation : Invocation) -> CliResult {
  let config = match scan_config_of(invocation) {
    Ok(config) => config
    Err(message) => return Failure(message)
  }
  let fast_fields = match fast_fields_of(invocation.matches) {
    Ok(fields) => fields
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
      // Materialize the dictionary, the eager range indexes, and the trigram
      // postings as part of the index build; S10 evaluates queries on them and
      // S12 persists them.
      let dict = @index.Dict::build(report.store)
      let ranges = @index.Ranges::build(report.store, eager=fast_fields)
      let trigram = if flag_set(invocation.matches, "no-trigram") {
        None
      } else {
        Some(@index.TrigramIndex::build(report.store))
      }
      let quiet = flag_set(invocation.matches, "quiet")
      let mut diagnostics = if quiet {
        ""
      } else {
        diagnostics_of(invocation, report, dict, ranges, trigram, elapsed_ms)
      }
      if flag_set(invocation.matches, "one-file-system") &&
        !report.device_ids_available {
        let warning = "warning: --one-file-system has no effect: this backend cannot read device ids"
        if diagnostics.is_empty() {
          diagnostics = warning
        } else {
          diagnostics = "\{diagnostics}\n\{warning}"
        }
      }
      if quiet {
        return SuccessWith("", diagnostics)
      }
      let summary = summary_of(report)
      if diagnostics.is_empty() {
        Success(summary)
      } else {
        SuccessWith(summary, diagnostics)
      }
    }
  }
}
