///|
/// Parse `--type`.
fn kind_filter_of(
  matches : @argparse.Matches,
) -> Result[@query.KindFilter, String] {
  match first_option_value(matches, "type").unwrap_or("any") {
    "any" => Ok(@query.AnyKind)
    "file" | "files" => Ok(@query.FilesOnly)
    "folder" | "folders" => Ok(@query.FoldersOnly)
    other => Err("error: --type must be any, file, or folder, got '\{other}'")
  }
}

///|
/// Build the initial term flags from the command line.
fn query_flags_of(matches : @argparse.Matches) -> Result[@query.Flags, String] {
  let kind = match kind_filter_of(matches) {
    Ok(kind) => kind
    Err(message) => return Err(message)
  }
  Ok(
    @query.Flags::new(
      case_sensitive=flag_set(matches, "case-sensitive"),
      exact=flag_set(matches, "exact"),
      search_path=flag_set(matches, "search-path"),
      regex=flag_set(matches, "regex"),
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
  if flags.regex {
    let query = if text.is_empty() && !(flags.kind is @query.AnyKind) {
      @query.kind_query(flags.kind)
    } else {
      @query.name_query(text, flags~)
    }
    return Ok(query)
  }
  let compat = flag_set(invocation.matches, "compat")
  let parsed = Ok(@query.parse(text, flags~, compat~)) catch {
    err => Err("error: \{err.message()}")
  }
  parsed
}

///|
/// Reject the bitmap engine until S06 lands.
fn check_engine(matches : @argparse.Matches) -> Result[Unit, String] {
  match first_option_value(matches, "engine").unwrap_or("scan") {
    "scan" => Ok(())
    "bitmap" =>
      Err("error: the bitmap engine is not implemented yet; pass --engine scan")
    other => Err("error: --engine must be scan or bitmap, got '\{other}'")
  }
}

///|
/// Reject output features that belong to S11.
///
/// The default name order and `--limit` are implemented; everything else warns
/// instead of silently producing the wrong format.
fn check_output_options(matches : @argparse.Matches) -> Result[Unit, String] {
  let sort = first_option_value(matches, "sort").unwrap_or("name")
  if sort != "name" {
    return Err(
      "error: --sort \{sort} is not implemented yet; only name order is available",
    )
  }
  let flags : Array[String] = [
    "reverse", "folders-first", "null", "json", "basename",
  ]
  for name in flags {
    if flag_set(matches, name) {
      return Err("error: --\{name} is not implemented yet")
    }
  }
  if first_option_value(matches, "format") is Some(_) {
    return Err("error: --format is not implemented yet")
  }
  if first_option_value(matches, "relative-to") is Some(_) {
    return Err("error: --relative-to is not implemented yet")
  }
  Ok(())
}

///|
/// Build scan options from `--limit`.
fn scan_options_of(
  matches : @argparse.Matches,
) -> Result[@exec.ScanOptions, String] {
  let text = first_option_value(matches, "limit").unwrap_or("0")
  let limit = match @query.parse_count(text) {
    Some(value) =>
      if value >= 0L && value <= 2147483647L {
        value.to_int()
      } else {
        return Err(
          "error: --limit must be a non-negative integer, got '\{text}'",
        )
      }
    None =>
      return Err("error: --limit must be a non-negative integer, got '\{text}'")
  }
  Ok(@exec.ScanOptions::new(limit~))
}

///|
/// Produce the store a query runs against.
///
/// Until persistence lands in S12 the only usable source is a live scan, so
/// `--live` and `--auto-index` both mean "scan the configured roots now". A
/// plain search reports how to get a store instead of failing obscurely.
async fn store_for_query(
  invocation : Invocation,
) -> Result[@core.Store, String] {
  let matches = invocation.matches
  if !(flag_set(matches, "live") || flag_set(matches, "auto-index")) {
    return Err(
      "error: the index is not persisted yet (S12); pass --live --root <PATH> to scan roots for this query",
    )
  }
  let config = match scan_config_of(invocation) {
    Ok(config) => config
    Err(message) => return Err(message)
  }
  let outcome = Ok(@index.scan(config, @platform.system_source())) catch {
    err => Err("error: \{err.message()}")
  }
  match outcome {
    Ok(report) => Ok(report.store)
    Err(message) => Err(message)
  }
}

///|
/// Milliseconds elapsed since `started`.
fn elapsed_ms(started : UInt64) -> Int64 {
  (@env.now() - started).reinterpret_as_int64()
}

///|
/// Render hits as newline-separated full paths.
fn format_hits(store : @core.Store, hits : Array[@core.EntryRef]) -> String {
  let out = StringBuilder()
  let mut index = 0
  while index < hits.length() {
    if index > 0 {
      out.write_char('\n')
    }
    out.write_string(@utf8.decode_lossy(store.entry_path(hits[index])))
    index = index + 1
  }
  out.to_string()
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
    }
    out.write_string("entries: \{store.entry_count()}\n")
    out.write_string("matches: \{hit_count}\n")
    out.write_string("search: \{exec_ms} ms\n")
  }
  trim_trailing_newline(out.to_string())
}

///|
/// Run `search` on the scan engine.
async fn run_search(invocation : Invocation) -> CliResult {
  let matches = invocation.matches
  match check_engine(matches) {
    Ok(_) => ()
    Err(message) => return Failure(message)
  }
  match check_output_options(matches) {
    Ok(_) => ()
    Err(message) => return Failure(message)
  }
  let flags = match query_flags_of(matches) {
    Ok(flags) => flags
    Err(message) => return Failure(message)
  }
  let query = match build_query(invocation, flags) {
    Ok(query) => query
    Err(message) => return Failure(message)
  }
  let options = match scan_options_of(matches) {
    Ok(options) => options
    Err(message) => return Failure(message)
  }
  let live = flag_set(matches, "live") || flag_set(matches, "auto-index")
  let scan_started = @env.now()
  let store = match store_for_query(invocation) {
    Ok(store) => store
    Err(message) => return Failure(message)
  }
  let scan_ms = elapsed_ms(scan_started)
  let exec_started = @env.now()
  let executed = Ok(@exec.exec_scan_with(store, query, options~)) catch {
    err => Err("error: \{err.message()}")
  }
  let hits = match executed {
    Ok(hits) => hits
    Err(message) => return Failure(message)
  }
  let exec_ms = elapsed_ms(exec_started)
  let plan = if flag_set(matches, "explain") {
    explain_plan(query, options)
  } else {
    ""
  }
  let diagnostics = search_diagnostics(
    matches,
    query,
    plan,
    store,
    hits.length(),
    scan_ms,
    exec_ms,
    live,
  )
  let text = format_hits(store, hits)
  if hits.is_empty() {
    NoMatch("", diagnostics)
  } else if diagnostics.is_empty() {
    Success(text)
  } else {
    SuccessWith(text, diagnostics)
  }
}

///|
/// Compile the plan for `--explain`. Search already compiled the same query, so
/// a failure here is not expected; reporting an empty plan is safer than
/// turning a successful search into an error.
fn explain_plan(query : @query.Query, options : @exec.ScanOptions) -> String {
  let explained = Ok(@exec.explain_query(query, options~)) catch {
    err => Err(err.message())
  }
  match explained {
    Ok(plan) => plan
    Err(message) => "error: \{message}"
  }
}

///|
/// Run `count` on the scan engine.
async fn run_count(invocation : Invocation) -> CliResult {
  let matches = invocation.matches
  match check_engine(matches) {
    Ok(_) => ()
    Err(message) => return Failure(message)
  }
  let flags = match query_flags_of(matches) {
    Ok(flags) => flags
    Err(message) => return Failure(message)
  }
  let query = match build_query(invocation, flags) {
    Ok(query) => query
    Err(message) => return Failure(message)
  }
  let live = flag_set(matches, "live") || flag_set(matches, "auto-index")
  let scan_started = @env.now()
  let store = match store_for_query(invocation) {
    Ok(store) => store
    Err(message) => return Failure(message)
  }
  let scan_ms = elapsed_ms(scan_started)
  let options = @exec.ScanOptions::new()
  let exec_started = @env.now()
  let counted = Ok(@exec.exec_count_with(store, query, options~)) catch {
    err => Err("error: \{err.message()}")
  }
  let count = match counted {
    Ok(count) => count
    Err(message) => return Failure(message)
  }
  let exec_ms = elapsed_ms(exec_started)
  let out = StringBuilder()
  if flag_set(matches, "explain") {
    out.write_string("query: \{query.describe()}\n")
    out.write_string("plan: \{explain_plan(query, options)}\n")
  }
  if flag_set(matches, "stats") {
    if live {
      out.write_string("scan: \{scan_ms} ms\n")
    }
    out.write_string("entries: \{store.entry_count()}\n")
    out.write_string("matches: \{count}\n")
    out.write_string("search: \{exec_ms} ms\n")
  }
  let diagnostics = trim_trailing_newline(out.to_string())
  let text = count.to_string()
  if count == 0 {
    NoMatch(text, diagnostics)
  } else if diagnostics.is_empty() {
    Success(text)
  } else {
    SuccessWith(text, diagnostics)
  }
}
