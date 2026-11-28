///|
/// Parse `--type`.
fn kind_filter_of(invocation : Invocation) -> Result[@query.KindFilter, String] {
  match explicit_option_value(invocation.matches, "type") {
    Some(text) =>
      match text {
        "any" => Ok(@query.AnyKind)
        "file" | "files" => Ok(@query.FilesOnly)
        "folder" | "folders" => Ok(@query.FoldersOnly)
        other =>
          Err("error: --type must be any, file, or folder, got '\{other}'")
      }
    None => Ok(invocation.config.search.kind)
  }
}

///|
/// Build the initial term flags from CLI and configured search defaults.
fn query_flags_of(invocation : Invocation) -> Result[@query.Flags, String] {
  let matches = invocation.matches
  let search = invocation.config.search
  let kind = match kind_filter_of(invocation) {
    Ok(kind) => kind
    Err(message) => return Err(message)
  }
  Ok(
    @query.Flags::new(
      case_sensitive=flag_set(matches, "case-sensitive") ||
        search.case_sensitive,
      exact=flag_set(matches, "exact") || search.exact,
      search_path=flag_set(matches, "search-path") || search.search_path,
      regex=flag_set(matches, "regex") || search.regex,
      kind~,
    ),
  )
}

///|
/// Build the query tree.
///
/// `--regex` turns the whole command-line query into one regex term, without
/// field or boolean parsing, as the CLI contract specifies. Otherwise the
/// ordinary parser runs.
fn build_query(
  invocation : Invocation,
  flags : @query.Flags,
) -> Result[@query.Query, String] {
  let text = invocation.query
  let compat = flag_set(invocation.matches, "compat")
  // `--type` is a global constraint, not a seed for term flags: a query-local
  // `file:` or `folder:` must not override it. Parse with a neutral kind and
  // intersect the command-line kind afterwards.
  let global_kind = flags.kind
  let parse_flags = flags.with_kind(@query.AnyKind)
  let query = if flags.regex {
    // `--regex` bypasses the parser, so apply the same term-level automatic
    // path and case rules the parser gives a bare word.
    @query.name_query(
      text,
      flags=@query.Flags::with_name_heuristics(parse_flags, text),
    )
  } else {
    let parsed = Ok(
      @query.parse(
        text,
        flags=parse_flags,
        macros=invocation.config.macros,
        compat~,
      ),
    ) catch {
      err => Err("error: \{err.message()}")
    }
    match parsed {
      Ok(value) => value
      Err(message) => return Err(message)
    }
  }
  Ok(@query.constrain_kind(query, global_kind))
}

///|
/// The execution engine selected by `--engine`.
priv enum Engine {
  ScanEngine
  BitmapEngine
}

///|
/// Parse `--engine`.
fn engine_of(invocation : Invocation) -> Result[Engine, String] {
  let configured = invocation.config.engine.unwrap_or("bitmap")
  match
    explicit_option_value(invocation.matches, "engine").unwrap_or(configured) {
    "scan" => Ok(ScanEngine)
    "bitmap" => Ok(BitmapEngine)
    other => Err("error: --engine must be scan or bitmap, got '\{other}'")
  }
}

///|
/// Parse the range fields to decode immediately from a persisted database.
fn load_fast_fields_of(
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
        None => Ok(@index.RangeFieldSet::default())
      }
  }
}

///|
/// Parse `--limit`, then the configured limit, then zero (unlimited).
fn limit_of(invocation : Invocation) -> Result[Int32, String] {
  match explicit_option_value(invocation.matches, "limit") {
    Some(text) =>
      match @query.parse_count(text) {
        Some(value) =>
          if value >= 0L && value <= 2147483647L {
            Ok(value.to_int())
          } else {
            Err("error: --limit must be a non-negative integer, got '\{text}'")
          }
        None =>
          Err("error: --limit must be a non-negative integer, got '\{text}'")
      }
    None => Ok(invocation.config.search.limit)
  }
}

///|
/// Build scan options from the effective limit.
fn scan_options_of(
  invocation : Invocation,
) -> Result[@exec.ScanOptions, String] {
  let limit = match limit_of(invocation) {
    Ok(limit) => limit
    Err(message) => return Err(message)
  }
  Ok(@exec.ScanOptions::new(limit~))
}

///|
/// Parse `--sort` and the ordering flags.
fn order_options_of(
  invocation : Invocation,
) -> Result[@exec.OrderOptions, String] {
  let matches = invocation.matches
  let search = invocation.config.search
  let text = explicit_option_value(matches, "sort").unwrap_or(search.sort)
  let key = match @exec.SortKey::from_name(text) {
    Some(key) => key
    None =>
      return Err(
        "error: --sort must be name, path, size, mtime, ext, or type, got '\{text}'",
      )
  }
  let limit = match limit_of(invocation) {
    Ok(limit) => limit
    Err(message) => return Err(message)
  }
  Ok(
    @exec.OrderOptions::new(
      key~,
      reverse=flag_set(matches, "reverse") || search.reverse,
      folders_first=flag_set(matches, "folders-first") || search.folders_first,
      limit~,
    ),
  )
}

///|
/// Build the output format from `--json`, `--format`, `--basename`, `--null`,
/// and `--relative-to`.
///
/// The three record formats are mutually exclusive: combining them would make
/// the output depend on an undocumented precedence. `--null` is a terminator
/// and works with every format. The relative base is resolved once here so the
/// formatter only compares bytes.
async fn format_options_of(
  invocation : Invocation,
) -> Result[@exec.FormatOptions, String] {
  let matches = invocation.matches
  let json = flag_set(matches, "json")
  let basename = flag_set(matches, "basename")
  let template = first_option_value(matches, "format")
  let has_template = match template {
    Some(_) => true
    None => false
  }
  if json && has_template {
    return Err("error: --json and --format cannot be combined")
  }
  if json && basename {
    return Err("error: --json and --basename cannot be combined")
  }
  if basename && has_template {
    return Err("error: --basename and --format cannot be combined")
  }
  let format = if json {
    @exec.Json
  } else if basename {
    @exec.Names
  } else {
    match template {
      Some(text) =>
        match @exec.FormatTemplate::parse(text) {
          Ok(template) => @exec.Template(template)
          Err(message) => return Err("error: \{message}")
        }
      None => @exec.Paths
    }
  }
  let relative_to = if basename {
    // `--basename` prints names only, so a relative base cannot affect output.
    None
  } else {
    match first_option_value(matches, "relative-to") {
      Some(path) => {
        let resolved = @platform.system_source().realpath(@utf8.encode(path)) catch {
          err => return Err("error: --relative-to \{path}: \{err.message()}")
        }
        Some(resolved)
      }
      None => None
    }
  }
  Ok(
    @exec.FormatOptions::new(
      format~,
      null_terminated=flag_set(matches, "null"),
      relative_to~,
    ),
  )
}

///|
/// Where a query's store and candidate sources come from.
priv enum QuerySource {
  /// A scan performed for this query by `--live` or `--auto-index`.
  Live(@core.Store, @index.ScanReport)
  /// The persisted index loaded from the database.
  Persisted(@index.Index)
}

///|
/// The store backing a query source.
fn source_store(source : QuerySource) -> @core.Store {
  match source {
    Live(store, _) => store
    Persisted(index) => index.store()
  }
}

///|
/// Whether the source was scanned during this invocation.
fn source_is_live(source : QuerySource) -> Bool {
  match source {
    Live(_, _) => true
    Persisted(_) => false
  }
}

///|
/// Scan the configured roots into a store.
async fn scan_store(
  invocation : Invocation,
) -> Result[(@core.Store, Array[@index.ExcludeRule], @index.ScanReport), String] {
  let config = match scan_config_of(invocation) {
    Ok(config) => config
    Err(message) => return Err(message)
  }
  let outcome : Result[@index.ScanReport, String] = Ok(
    @index.scan(config, @platform.system_source()),
  ) catch {
    err => Err("error: \{err.message()}")
  }
  match outcome {
    Ok(report) => Ok((report.store, config.excludes, report))
    Err(message) => Err(message)
  }
}

///|
/// Produce the store and index a query runs against.
///
/// `--live` scans the roots and does not touch the database. Otherwise the
/// persisted index is loaded as-is: the dictionary, range indexes, and trigram
/// postings come back without a rebuild. `--auto-index` scans and writes the
/// database first when it is missing. A plain search with no database is a
/// usage error that names the command which creates one.
async fn query_source(
  invocation : Invocation,
  eager : @index.RangeFieldSet,
) -> Result[QuerySource, String] {
  let matches = invocation.matches
  if flag_set(matches, "live") {
    let (store, _, report) = match scan_store(invocation) {
      Ok(result) => result
      Err(message) => return Err(message)
    }
    return Ok(Live(store, report))
  }
  let database = match database_path(invocation) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let exists = @fs.exists(database) catch { _ => false }
  if exists {
    let loaded : Result[@index.Index, String] = Ok(
      @index.Index::read_database(database, eager~),
    ) catch {
      err => Err("error: \{err.message()}")
    }
    return match loaded {
      Ok(index) => Ok(Persisted(index))
      Err(message) => Err(message)
    }
  }
  if flag_set(matches, "auto-index") {
    let (store, excludes, _) = match scan_store(invocation) {
      Ok(result) => result
      Err(message) => return Err(message)
    }
    let index = live_index(invocation, store, eager~, excludes~)
    let written : Result[Unit, String] = Ok(
      @index.Index::write_database(index, database),
    ) catch {
      err => Err("error: \{err.message()}")
    }
    return match written {
      Ok(_) => Ok(Persisted(index))
      Err(message) => Err(message)
    }
  }
  Err(
    "error: no index database at \{database}; run 'moonsearch index <ROOT>' to create it",
  )
}

///|
/// Milliseconds elapsed since `started`.
fn elapsed_ms(started : UInt64) -> Int64 {
  (@env.now() - started).reinterpret_as_int64()
}

///|
/// Build the in-memory index a live bitmap query runs against.
///
/// The five core range fields are always built. `eager` additionally selects
/// optional child-count fields; unselected optional queries degrade to scan.
/// The trigram postings are built because a name term is the common case.
fn live_index(
  invocation : Invocation,
  store : @core.Store,
  eager~ : @index.RangeFieldSet,
  excludes~ : Array[@index.ExcludeRule] = [],
) -> @index.Index {
  @index.Index::build(
    store,
    eager~,
    trigram=invocation.config.trigram.unwrap_or(true),
    excludes~,
  )
}

///|
/// Turn an id set into hits in canonical order.
///
/// This is the streaming half of the indexed engine: walking the canonical
/// order and checking membership keeps `--limit` early-stopping. Ordering and
/// formatting happen afterwards in `@exec`, so both engines share them.
fn hits_of_ids(
  store : @core.Store,
  ids : @ids.Ids,
  limit : Int32,
  reverse~ : Bool = false,
) -> Array[@core.EntryRef] {
  let hits : Array[@core.EntryRef] = []
  if ids.is_empty() {
    return hits
  }
  let order = store.entries_in_order()
  if reverse {
    let mut index = order.length() - 1
    while index >= 0 {
      let entry = order[index]
      if ids.contains(store.global_id(entry)) {
        hits.push(entry)
        if limit > 0 && hits.length() >= limit {
          break
        }
      }
      index = index - 1
    }
  } else {
    for entry in order {
      if ids.contains(store.global_id(entry)) {
        hits.push(entry)
        if limit > 0 && hits.length() >= limit {
          break
        }
      }
    }
  }
  hits
}

///|
/// Build the `--explain` / `--stats` diagnostics.
fn search_diagnostics(
  matches : @argparse.Matches,
  query : @query.Query,
  plan : String,
  store : @core.Store,
  hit_count : Int32,
  candidate_count : Int32,
  output_count : Int32,
  ids_shape : String,
  scan_ms : Int64,
  index_ms : Int64?,
  exec_ms : Int64,
  live : Bool,
) -> String {
  let out = StringBuilder()
  if flag_set(matches, "explain") {
    out.write_string("query: \{query.describe()}\n")
    out.write_string("plan: \{plan}\n")
  }
  if flag_set(matches, "stats") {
    if live {
      out.write_string("scan: \{scan_ms} ms\n")
    } else {
      out.write_string("load: \{scan_ms} ms\n")
    }
    match index_ms {
      Some(ms) => out.write_string("index: \{ms} ms\n")
      None => ()
    }
    out.write_string("entries: \{store.entry_count()}\n")
    out.write_string("candidates: \{candidate_count}\n")
    out.write_string("matches: \{hit_count}\n")
    out.write_string("output: \{output_count}\n")
    out.write_string("ids: \{ids_shape}\n")
    out.write_string("search: \{exec_ms} ms\n")
  }
  trim_trailing_newline(out.to_string())
}

///|
/// Append a warning without dropping existing diagnostics.
fn append_warning(diagnostics : String, warning : String) -> String {
  if diagnostics.is_empty() {
    warning
  } else {
    "\{diagnostics}\n\{warning}"
  }
}

///|
/// Whether output can be rendered before folder aggregation is complete.
fn output_supports_stream(output : @exec.FormatOptions) -> Bool {
  match output.format {
    @exec.Json => false
    @exec.Template(template) => !template.uses_size()
    _ => true
  }
}

///|
/// Run a true filesystem-streaming scan query.
async fn run_live_stream(
  invocation : Invocation,
  query : @query.Query,
  compiled : @exec.CompiledScan,
  output : @exec.FormatOptions,
  limit : Int32,
  sink : @stdio.Output,
) -> CliResult {
  let matches = invocation.matches
  let accurate_stats = flag_set(matches, "stats")
  let config = match scan_config_of(invocation) {
    Ok(config) => config
    Err(message) => return Failure(message)
  }
  let started = @env.now()
  let mut candidates = 0
  let mut total_matches = 0
  let mut emitted = 0
  let mut invalid_json = 0
  let mut write_error : @io.WriterError? = None
  let report = @index.scan_stream(config, @platform.system_source(), async fn(
    entry,
  ) -> @index.VisitDecision noraise {
    candidates = candidates + 1
    let view = @exec.EntryView::live(
      path=entry.path,
      name=entry.name,
      kind=entry.kind,
      size=entry.size,
      mtime=entry.mtime,
      flags=entry.flags,
      depth=entry.depth,
      parent_path=entry.parent_path,
    )
    if compiled.matches(view) {
      total_matches = total_matches + 1
      if limit == 0 || emitted < limit {
        let rendered = @exec.format_entry(view, output)
        invalid_json = invalid_json + rendered.invalid_utf8_records
        sink.write(rendered.bytes) catch {
          err => {
            write_error = Some(err)
            return @index.Stop
          }
        }
        emitted = emitted + 1
      }
    }
    if !accurate_stats && limit > 0 && emitted >= limit {
      @index.Stop
    } else {
      @index.Continue
    }
  }) catch {
    err => return Failure("error: \{err.message()}")
  }
  match write_error {
    Some(err) => return OutputFailure(err)
    None => ()
  }
  let scan_ms = elapsed_ms(started)
  let mut diagnostics = ""
  if flag_set(matches, "explain") {
    diagnostics = "query: \{query.describe()}\nplan: (scan#unknown source=universe reason=scan-engine \{compiled.describe()})"
  }
  if flag_set(matches, "stats") {
    if !diagnostics.is_empty() {
      diagnostics = "\{diagnostics}\n"
    }
    diagnostics = "\{diagnostics}scan: \{scan_ms} ms\nentries: \{report.entries_evaluated}\ncandidates: \{candidates}\nmatches: \{total_matches}\noutput: \{emitted}\nids: n/a\nsearch: \{scan_ms} ms"
  }
  if flag_set(matches, "verbose") && !flag_set(matches, "quiet") {
    if !diagnostics.is_empty() {
      diagnostics = "\{diagnostics}\n"
    }
    diagnostics = "\{diagnostics}skipped: hidden=\{report.skipped_hidden} excluded=\{report.skipped_excluded} mount=\{report.skipped_mount}\nissues: \{report.issues.length()}"
    if report.stopped_early {
      diagnostics = "\{diagnostics}\nscan: partial"
    }
    for issue in report.issues {
      diagnostics = "\{diagnostics}\nissue: \{@utf8.decode_lossy(issue.path)}: \{issue.message}"
    }
  }
  if invalid_json > 0 {
    diagnostics = append_warning(
      diagnostics,
      "warning: replaced invalid UTF-8 in \{invalid_json} JSON record(s) with U+FFFD",
    )
  }
  Streamed(
    if total_matches == 0 {
      @core.EXIT_NO_MATCH
    } else {
      @core.EXIT_OK
    },
    diagnostics,
  )
}

///|
/// Run `search` with the selected engine.
async fn run_search(
  invocation : Invocation,
  streaming_output : @stdio.Output?,
) -> CliResult {
  let matches = invocation.matches
  let engine = match engine_of(invocation) {
    Ok(engine) => engine
    Err(message) => return Failure(message)
  }
  let compat = flag_set(matches, "compat")
  let order = match order_options_of(invocation) {
    Ok(order) => order
    Err(message) => return Failure(message)
  }
  let output = match format_options_of(invocation) {
    Ok(output) => output
    Err(message) => return Failure(message)
  }
  let flags = match query_flags_of(invocation) {
    Ok(flags) => flags
    Err(message) => return Failure(message)
  }
  let query = match build_query(invocation, flags) {
    Ok(query) => query
    Err(message) => return Failure(message)
  }
  let options = match scan_options_of(invocation) {
    Ok(options) => options
    Err(message) => return Failure(message)
  }
  // Plain name order streams and lets the engine stop at the limit. Every
  // other order needs the complete match set before it can choose the first
  // `limit` results.
  // Name order streams in either direction: forward walks the canonical order,
  // `--reverse` walks it backwards, so both stop at the limit. Every other
  // order needs the complete match set before choosing the first hits.
  let stream_order = order.streams_name_order()
  let reverse_name = stream_order && order.reverse
  if engine is ScanEngine &&
    flag_set(matches, "live") &&
    stream_order &&
    !reverse_name &&
    output_supports_stream(output) {
    let compiled = @exec.compile_scan_with(query, options, compat~) catch {
      err => return Failure("error: \{err.message()}")
    }
    if !compiled.needs_folder_totals() {
      match streaming_output {
        Some(sink) =>
          return run_live_stream(
            invocation,
            query,
            compiled,
            output,
            order.limit,
            sink,
          )
        None => ()
      }
    }
  }
  let collect_limit = if stream_order && !flag_set(matches, "stats") {
    order.limit
  } else {
    0
  }
  let eager = match load_fast_fields_of(invocation) {
    Ok(fields) => fields
    Err(message) => return Failure(message)
  }
  let source_started = @env.now()
  let source = match query_source(invocation, eager) {
    Ok(source) => source
    Err(message) => return Failure(message)
  }
  let source_ms = elapsed_ms(source_started)
  let live = source_is_live(source)
  let store = source_store(source)
  let mut hits : Array[@core.EntryRef] = []
  let mut index_ms : Int64? = None
  let mut plan = ""
  let mut exec_ms = 0L
  let mut total_matches = 0
  let mut candidate_count = 0
  let mut ids_shape = "n/a"
  match engine {
    ScanEngine => {
      let exec_started = @env.now()
      let scan_options = @exec.ScanOptions::new(limit=collect_limit)
      let executed = if reverse_name {
        Ok(
          @exec.exec_scan_ordered_stats(
            store,
            query,
            scan_options,
            true,
            compat~,
          ),
        ) catch {
          err => Err("error: \{err.message()}")
        }
      } else {
        Ok(
          @exec.exec_scan_ordered_stats(
            store,
            query,
            scan_options,
            false,
            compat~,
          ),
        ) catch {
          err => Err("error: \{err.message()}")
        }
      }
      let execution = match executed {
        Ok(execution) => execution
        Err(message) => return Failure(message)
      }
      hits = execution.hits
      total_matches = execution.total_matches
      candidate_count = execution.candidates
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = "(scan#\{candidate_count} source=universe reason=scan-engine \{execution.description})"
      }
    }
    BitmapEngine => {
      let index = match source {
        Live(store, _) => {
          let build_started = @env.now()
          let index = live_index(invocation, store, eager~)
          index_ms = Some(elapsed_ms(build_started))
          index
        }
        Persisted(index) => index
      }
      let exec_started = @env.now()
      let executed = Ok(@exec.exec_indexed_with_stats(index, query, compat~)) catch {
        err => Err("error: \{err.message()}")
      }
      let execution = match executed {
        Ok(execution) => execution
        Err(message) => return Failure(message)
      }
      let ids = execution.ids
      total_matches = ids.cardinality()
      candidate_count = execution.candidates
      ids_shape = match ids {
        @ids.Sorted(_) => "sorted"
        @ids.Bitmap(_) => "bitmap"
      }
      hits = hits_of_ids(store, ids, collect_limit, reverse=reverse_name)
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = execution.description
      }
    }
  }
  if stream_order &&
    flag_set(matches, "stats") &&
    order.limit > 0 &&
    hits.length() > order.limit {
    hits = hits[:order.limit].to_owned()
  }
  if !stream_order {
    hits = @exec.order_hits(store, hits, order)
  }
  let diagnostics = search_diagnostics(
    matches,
    query,
    plan,
    store,
    total_matches,
    candidate_count,
    hits.length(),
    ids_shape,
    source_ms,
    index_ms,
    exec_ms,
    live,
  )
  let mut diagnostics = diagnostics
  if flag_set(matches, "verbose") && !flag_set(matches, "quiet") {
    match source {
      Live(_, report) => {
        if !diagnostics.is_empty() {
          diagnostics = "\{diagnostics}\n"
        }
        diagnostics = "\{diagnostics}skipped: hidden=\{report.skipped_hidden} excluded=\{report.skipped_excluded} mount=\{report.skipped_mount}\nissues: \{report.issues.length()}"
        for issue in report.issues {
          diagnostics = "\{diagnostics}\nissue: \{@utf8.decode_lossy(issue.path)}: \{issue.message}"
        }
      }
      Persisted(_) => ()
    }
  }
  let rendered = @exec.format_hits(store, hits, output)
  let mut diagnostics = diagnostics
  match rendered.warning() {
    Some(warning) => diagnostics = append_warning(diagnostics, warning)
    None => ()
  }
  if hits.is_empty() {
    NoMatch(b"", diagnostics)
  } else if diagnostics.is_empty() {
    Success(rendered.stdout_bytes())
  } else {
    SuccessWith(rendered.stdout_bytes(), diagnostics)
  }
}

///|
/// Compile the scan plan for `--explain`. Search already compiled the same
/// query, so a failure here is not expected; reporting an error is safer than
/// turning a successful search into a crash.
fn explain_scan_plan(
  query : @query.Query,
  options : @exec.ScanOptions,
  compat : Bool,
) -> String {
  let explained = Ok(@exec.explain_query(query, options~, compat~)) catch {
    err => Err(err.message())
  }
  match explained {
    Ok(plan) => plan
    Err(message) => "error: \{message}"
  }
}

///|
/// Run `count` with the selected engine.
async fn run_count(invocation : Invocation) -> CliResult {
  let matches = invocation.matches
  let compat = flag_set(matches, "compat")
  let engine = match engine_of(invocation) {
    Ok(engine) => engine
    Err(message) => return Failure(message)
  }
  let flags = match query_flags_of(invocation) {
    Ok(flags) => flags
    Err(message) => return Failure(message)
  }
  let query = match build_query(invocation, flags) {
    Ok(query) => query
    Err(message) => return Failure(message)
  }
  let eager = match load_fast_fields_of(invocation) {
    Ok(fields) => fields
    Err(message) => return Failure(message)
  }
  let source_started = @env.now()
  let source = match query_source(invocation, eager) {
    Ok(source) => source
    Err(message) => return Failure(message)
  }
  let scan_ms = elapsed_ms(source_started)
  let live = source_is_live(source)
  let store = source_store(source)
  let options = @exec.ScanOptions::new()
  let mut count = 0
  let mut index_ms : Int64? = None
  let mut plan = ""
  let mut exec_ms = 0L
  let mut candidate_count = 0
  let mut ids_shape = "n/a"
  match engine {
    ScanEngine => {
      let exec_started = @env.now()
      let counted = Ok(
        @exec.exec_count_with_stats(store, query, options~, compat~),
      ) catch {
        err => Err("error: \{err.message()}")
      }
      let execution = match counted {
        Ok(execution) => execution
        Err(message) => return Failure(message)
      }
      count = execution.count
      candidate_count = execution.candidates
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = "(scan#\{candidate_count} source=universe reason=scan-engine \{explain_scan_plan(query, options, compat)})"
      }
    }
    BitmapEngine => {
      let index = match source {
        Live(store, _) => {
          let build_started = @env.now()
          let index = live_index(invocation, store, eager~)
          index_ms = Some(elapsed_ms(build_started))
          index
        }
        Persisted(index) => index
      }
      let exec_started = @env.now()
      let counted = Ok(@exec.exec_indexed_with_stats(index, query, compat~)) catch {
        err => Err("error: \{err.message()}")
      }
      let execution = match counted {
        Ok(execution) => execution
        Err(message) => return Failure(message)
      }
      count = execution.ids.cardinality()
      candidate_count = execution.candidates
      ids_shape = match execution.ids {
        @ids.Sorted(_) => "sorted"
        @ids.Bitmap(_) => "bitmap"
      }
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = execution.description
      }
    }
  }
  let out = StringBuilder()
  if flag_set(matches, "explain") {
    out.write_string("query: \{query.describe()}\n")
    out.write_string("plan: \{plan}\n")
  }
  if flag_set(matches, "stats") {
    if live {
      out.write_string("scan: \{scan_ms} ms\n")
    } else {
      out.write_string("load: \{scan_ms} ms\n")
    }
    match index_ms {
      Some(ms) => out.write_string("index: \{ms} ms\n")
      None => ()
    }
    out.write_string("entries: \{store.entry_count()}\n")
    out.write_string("candidates: \{candidate_count}\n")
    out.write_string("matches: \{count}\n")
    out.write_string("ids: \{ids_shape}\n")
    out.write_string("search: \{exec_ms} ms\n")
  }
  let mut diagnostics = trim_trailing_newline(out.to_string())
  if flag_set(matches, "verbose") && !flag_set(matches, "quiet") {
    match source {
      Live(_, report) => {
        if !diagnostics.is_empty() {
          diagnostics = "\{diagnostics}\n"
        }
        diagnostics = "\{diagnostics}skipped: hidden=\{report.skipped_hidden} excluded=\{report.skipped_excluded} mount=\{report.skipped_mount}\nissues: \{report.issues.length()}"
        for issue in report.issues {
          diagnostics = "\{diagnostics}\nissue: \{@utf8.decode_lossy(issue.path)}: \{issue.message}"
        }
      }
      Persisted(_) => ()
    }
  }
  let text = text_line(count.to_string())
  if count == 0 {
    NoMatch(text, diagnostics)
  } else if diagnostics.is_empty() {
    Success(text)
  } else {
    SuccessWith(text, diagnostics)
  }
}
