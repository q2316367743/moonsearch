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
  let configured = invocation.config.engine.unwrap_or("scan")
  match
    explicit_option_value(invocation.matches, "engine").unwrap_or(configured) {
    "scan" => Ok(ScanEngine)
    "bitmap" => Ok(BitmapEngine)
    other => Err("error: --engine must be scan or bitmap, got '\{other}'")
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
  Live(@core.Store)
  /// The persisted index loaded from the database.
  Persisted(@index.Index)
}

///|
/// The store backing a query source.
fn source_store(source : QuerySource) -> @core.Store {
  match source {
    Live(store) => store
    Persisted(index) => index.store()
  }
}

///|
/// Whether the source was scanned during this invocation.
fn source_is_live(source : QuerySource) -> Bool {
  match source {
    Live(_) => true
    Persisted(_) => false
  }
}

///|
/// Scan the configured roots into a store.
async fn scan_store(invocation : Invocation) -> Result[@core.Store, String] {
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
    Ok(report) => Ok(report.store)
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
async fn query_source(invocation : Invocation) -> Result[QuerySource, String] {
  let matches = invocation.matches
  if flag_set(matches, "live") {
    let store = match scan_store(invocation) {
      Ok(store) => store
      Err(message) => return Err(message)
    }
    return Ok(Live(store))
  }
  let database = match database_path(invocation) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let exists = @fs.exists(database) catch { _ => false }
  if exists {
    let loaded : Result[@index.Index, String] = Ok(
      @index.Index::read_database(database),
    ) catch {
      err => Err("error: \{err.message()}")
    }
    return match loaded {
      Ok(index) => Ok(Persisted(index))
      Err(message) => Err(message)
    }
  }
  if flag_set(matches, "auto-index") {
    let store = match scan_store(invocation) {
      Ok(store) => store
      Err(message) => return Err(message)
    }
    let index = live_index(invocation, store)
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
/// The product default is `--fast-fields size,mtime`: the other range fields
/// materialize on first use inside the query compiler. The trigram postings are
/// built because a name term is the common case; `--no-trigram` belongs to the
/// index command, which is where an index shape is chosen.
fn live_index(invocation : Invocation, store : @core.Store) -> @index.Index {
  let eager = match invocation.config.fast_fields {
    Some(fields) => @index.RangeFieldSet::of(fields)
    None =>
      @index.RangeFieldSet::of([
        @index.RangeField::Size,
        @index.RangeField::MTime,
      ])
  }
  @index.Index::build(
    store,
    eager~,
    trigram=invocation.config.trigram.unwrap_or(true),
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
    out.write_string("matches: \{hit_count}\n")
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
/// Run `search` with the selected engine.
async fn run_search(invocation : Invocation) -> CliResult {
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
  let collect_limit = if stream_order { order.limit } else { 0 }
  let source_started = @env.now()
  let source = match query_source(invocation) {
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
  match engine {
    ScanEngine => {
      let exec_started = @env.now()
      let scan_options = @exec.ScanOptions::new(limit=collect_limit)
      let executed = if reverse_name {
        Ok(
          @exec.exec_scan_reverse_with(
            store,
            query,
            options=scan_options,
            compat~,
          ),
        ) catch {
          err => Err("error: \{err.message()}")
        }
      } else {
        Ok(@exec.exec_scan_with(store, query, options=scan_options, compat~)) catch {
          err => Err("error: \{err.message()}")
        }
      }
      hits = match executed {
        Ok(hits) => hits
        Err(message) => return Failure(message)
      }
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = explain_scan_plan(query, options, compat)
      }
    }
    BitmapEngine => {
      let index = match source {
        Live(store) => {
          let build_started = @env.now()
          let index = live_index(invocation, store)
          index_ms = Some(elapsed_ms(build_started))
          index
        }
        Persisted(index) => index
      }
      let exec_started = @env.now()
      let executed = Ok(@exec.exec_indexed(index, query, compat~)) catch {
        err => Err("error: \{err.message()}")
      }
      let ids = match executed {
        Ok(ids) => ids
        Err(message) => return Failure(message)
      }
      hits = hits_of_ids(store, ids, collect_limit, reverse=reverse_name)
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = explain_bitmap_plan(index, query, compat)
      }
    }
  }
  if !stream_order {
    hits = @exec.order_hits(store, hits, order)
  }
  let diagnostics = search_diagnostics(
    matches,
    query,
    plan,
    store,
    hits.length(),
    source_ms,
    index_ms,
    exec_ms,
    live,
  )
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
/// Compile the indexed plan for `--explain`.
fn explain_bitmap_plan(
  index : @index.Index,
  query : @query.Query,
  compat : Bool,
) -> String {
  let explained = Ok(@exec.explain_indexed(index, query, compat~)) catch {
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
  let source_started = @env.now()
  let source = match query_source(invocation) {
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
  match engine {
    ScanEngine => {
      let exec_started = @env.now()
      let counted = Ok(@exec.exec_count_with(store, query, options~, compat~)) catch {
        err => Err("error: \{err.message()}")
      }
      count = match counted {
        Ok(count) => count
        Err(message) => return Failure(message)
      }
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = explain_scan_plan(query, options, compat)
      }
    }
    BitmapEngine => {
      let index = match source {
        Live(store) => {
          let build_started = @env.now()
          let index = live_index(invocation, store)
          index_ms = Some(elapsed_ms(build_started))
          index
        }
        Persisted(index) => index
      }
      let exec_started = @env.now()
      let counted = Ok(@exec.exec_indexed_count(index, query, compat~)) catch {
        err => Err("error: \{err.message()}")
      }
      count = match counted {
        Ok(count) => count
        Err(message) => return Failure(message)
      }
      exec_ms = elapsed_ms(exec_started)
      if flag_set(matches, "explain") {
        plan = explain_bitmap_plan(index, query, compat)
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
    out.write_string("matches: \{count}\n")
    out.write_string("search: \{exec_ms} ms\n")
  }
  let diagnostics = trim_trailing_newline(out.to_string())
  let text = text_line(count.to_string())
  if count == 0 {
    NoMatch(text, diagnostics)
  } else if diagnostics.is_empty() {
    Success(text)
  } else {
    SuccessWith(text, diagnostics)
  }
}
