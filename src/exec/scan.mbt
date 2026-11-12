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
) -> Array[@core.EntryRef] raise @query.QueryError {
  let expr = compile_query(query, resolved_now(options), resolved_zone(options))
  let hits : Array[@core.EntryRef] = []
  if expr is None {
    return hits
  }
  for entry in store.entries_in_order() {
    if eval_expr(expr, store, entry) {
      hits.push(entry)
      if options.limit > 0 && hits.length() >= options.limit {
        break
      }
    }
  }
  hits
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
/// Count matches with explicit options.
pub fn exec_count_with(
  store : @core.Store,
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
) -> Int32 raise @query.QueryError {
  let expr = compile_query(query, resolved_now(options), resolved_zone(options))
  match expr {
    None => 0
    All => store.entry_count()
    _ => {
      let mut count = 0
      for entry in store.entries_in_order() {
        if eval_expr(expr, store, entry) {
          count = count + 1
        }
      }
      count
    }
  }
}

///|
/// Render the compiled plan, for `--explain`.
pub fn explain_query(
  query : @query.Query,
  options~ : ScanOptions = ScanOptions::new(),
) -> String raise @query.QueryError {
  let expr = compile_query(query, resolved_now(options), resolved_zone(options))
  explain_expr(expr)
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
