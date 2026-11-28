///|
/// Options for one scan-engine evaluation.
///
/// `limit` stops after that many hits (0 means unlimited). `now` and `zone` make
/// date queries deterministic in tests; the CLI leaves them empty, which uses
/// the current clock and the host's local time zone.
pub(all) struct ScanOptions {
  limit : Int32
  now : Int64?
  zone : @time.Zone?
}

///|
/// Build scan options.
pub fn ScanOptions::new(
  limit~ : Int32 = 0,
  now~ : Int64? = None,
  zone~ : @time.Zone? = None,
) -> ScanOptions {
  { limit, now, zone, }
}

///|
/// Compile once with the same clock and zone used by scan execution.
pub fn compile_scan_with(
  query : @query.Query,
  options : ScanOptions,
  compat~ : Bool = false,
) -> CompiledScan raise @query.QueryError {
  compile_scan(query, resolved_now(options), resolved_zone(options), compat~)
}

///|
/// Evaluate a query with the linear scan engine and return the matching entries
/// in canonical order.
///
/// This is the S05 baseline: it walks every entry once, applies the compiled
/// predicate, and keeps the hits in canonical order. The bitmap engine added in
/// S06 must return the same set, which makes this function the oracle for the
/// cross-check tests.
pub fn exec_scan(
  store : @core.Store,
  query : @query.Query,
) -> Array[@core.EntryRef] raise @query.QueryError {
  exec_scan_with(store, query)
}

///|
/// Evaluate a query with explicit options.
///
/// The walk is streaming: an expression that is `None` never touches the store,
/// and a non-zero limit stops as soon as enough entries matched.
pub fn exec_scan_with(
  store : @core.Store,
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
  compat~ : Bool = false,
) -> Array[@core.EntryRef] raise @query.QueryError {
  exec_scan_ordered(store, query, options, false, compat~)
}

///|
/// Evaluate a query in reverse canonical order.
///
/// `--sort name --reverse` uses this path: walking the canonical order
/// backwards keeps the same streaming and early-stop behavior as forward name
/// order, instead of collecting every match and sorting it.
pub fn exec_scan_reverse_with(
  store : @core.Store,
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
  compat~ : Bool = false,
) -> Array[@core.EntryRef] raise @query.QueryError {
  exec_scan_ordered(store, query, options, true, compat~)
}

///|
/// Counts produced by one scan evaluation.
pub(all) struct ScanExecution {
  hits : Array[@core.EntryRef]
  candidates : Int32
  total_matches : Int32
  stopped_early : Bool
  description : String
}

///|
/// Forward or backward streaming scan.
fn exec_scan_ordered(
  store : @core.Store,
  query : @query.Query,
  options : ScanOptions,
  reverse : Bool,
  compat~ : Bool = false,
) -> Array[@core.EntryRef] raise @query.QueryError {
  exec_scan_ordered_stats(store, query, options, reverse, compat~).hits
}

///|
/// Forward or backward streaming scan with deterministic counters.
pub fn exec_scan_ordered_stats(
  store : @core.Store,
  query : @query.Query,
  options : ScanOptions,
  reverse : Bool,
  compat~ : Bool = false,
) -> ScanExecution raise @query.QueryError {
  let compiled = compile_scan(
    query,
    resolved_now(options),
    resolved_zone(options),
    compat~,
  )
  let hits : Array[@core.EntryRef] = []
  if compiled.expr is None {
    return {
      hits,
      candidates: 0,
      total_matches: 0,
      stopped_early: false,
      description: compiled.describe(),
    }
  }
  let mut candidates = 0
  let mut stopped_early = false
  let order = store.entries_in_order()
  let mut index = if reverse { order.length() - 1 } else { 0 }
  while index >= 0 && index < order.length() {
    let entry = order[index]
    candidates = candidates + 1
    if compiled.matches(EntryView::of_store(store, entry)) {
      hits.push(entry)
      if options.limit > 0 && hits.length() >= options.limit {
        stopped_early = index > 0 &&
          (if reverse { true } else { index + 1 < order.length() })
        break
      }
    }
    index = index + (if reverse { -1 } else { 1 })
  }
  {
    hits,
    candidates,
    total_matches: hits.length(),
    stopped_early,
    description: compiled.describe(),
  }
}

///|
/// Count matches without building a result array.
///
/// `--count` maps to this: the answer is a number, so there is no reason to
/// collect entries. `MatchAll` short-circuits to the entry count.
pub fn exec_count(
  store : @core.Store,
  query : @query.Query,
) -> Int32 raise @query.QueryError {
  exec_count_with(store, query)
}

///|
/// Count result plus the number of entries whose predicate was evaluated.
pub(all) struct CountExecution {
  count : Int32
  candidates : Int32
}

///|
/// Count matches with explicit options.
pub fn exec_count_with(
  store : @core.Store,
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
  compat~ : Bool = false,
) -> Int32 raise @query.QueryError {
  exec_count_with_stats(store, query, options~, compat~).count
}

///|
/// Count matches and report the evaluated predicate candidates.
pub fn exec_count_with_stats(
  store : @core.Store,
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
  compat~ : Bool = false,
) -> CountExecution raise @query.QueryError {
  let compiled = compile_scan(
    query,
    resolved_now(options),
    resolved_zone(options),
    compat~,
  )
  match compiled.expr {
    None => { count: 0, candidates: 0, }
    All => { count: store.entry_count(), candidates: 0, }
    _ => {
      let mut count = 0
      let mut candidates = 0
      for entry in store.entries_in_order() {
        candidates = candidates + 1
        if compiled.matches(EntryView::of_store(store, entry)) {
          count = count + 1
        }
      }
      { count, candidates, }
    }
  }
}

///|
/// Render the compiled plan, for `--explain`.
pub fn explain_query(
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
  compat~ : Bool = false,
) -> String raise @query.QueryError {
  let compiled = compile_scan(
    query,
    resolved_now(options),
    resolved_zone(options),
    compat~,
  )
  compiled.describe()
}

///|
/// Unix seconds to resolve dates against.
fn resolved_now(options : ScanOptions) -> Int64 {
  match options.now {
    Some(value) => value
    None => @util.current_unix_seconds()
  }
}

///|
/// Time zone to resolve dates in.
fn resolved_zone(options : ScanOptions) -> @time.Zone {
  match options.zone {
    Some(zone) => zone
    None => @util.local_zone()
  }
}
