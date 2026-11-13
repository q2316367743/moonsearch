///|
/// A compiled execution plan over id sets.
///
/// `Query` describes what the user asked for; `Expr` describes how to compute
/// the answer. Every node evaluates to an `Ids` set over the store-wide id space
/// from `@core.Store::global_id`, so the executor never looks at the original
/// query text again.
///
/// Leaves name where the candidate ids come from:
///
/// - `Const` — a set already materialized by the dictionary or a range index;
/// - `Trigram` — posting candidates that still need a byte-level name check;
/// - `Scan` — a predicate with no supporting index, evaluated over the universe;
/// - `Filter` — a pushed-down predicate over the result of another node, which
///   is what the optimizer produces for `And(indexed, Scan(pred))`.
pub enum Expr {
  Const(ConstLeaf)
  Trigram(TrigramLeaf)
  Scan(ScanLeaf)
  Filter(ScanLeaf, Expr)
  And(Expr, Expr)
  Or(Expr, Expr)
  Not(Expr)
}

///|
/// A precomputed set together with the term text it came from.
///
/// The label is diagnostic only: constant folding keeps the original terms so
/// `--explain` still shows what the user asked for after the sets were merged.
pub struct ConstLeaf {
  priv ids : @ids.Ids
  priv label : String
}

///|
/// The ids of a constant leaf. Treat the result as read-only.
pub fn ConstLeaf::ids(self : ConstLeaf) -> @ids.Ids {
  self.ids
}

///|
/// The term text behind a constant leaf, for `--explain`.
pub fn ConstLeaf::label(self : ConstLeaf) -> String {
  self.label
}

///|
/// A name term resolved through the trigram postings.
///
/// `candidates` is a superset of the matches after the term's kind and
/// visibility filters were applied; every candidate still goes through the same
/// `ScanTerm` predicate the scan engine uses.
pub struct TrigramLeaf {
  priv term : ScanTerm
  priv needle : Bytes
  priv candidates : @ids.Ids
  priv keys : Int32
}

///|
/// Candidate ids for the trigram leaf. Read-only.
pub fn TrigramLeaf::candidates(self : TrigramLeaf) -> @ids.Ids {
  self.candidates
}

///|
/// Number of postings the lookup intersected (at most the trigram limit).
pub fn TrigramLeaf::key_count(self : TrigramLeaf) -> Int32 {
  self.keys
}

///|
/// The needle the postings were looked up with, for diagnostics.
pub fn TrigramLeaf::needle(self : TrigramLeaf) -> BytesView {
  self.needle[:]
}

///|
/// A predicate the index cannot narrow, plus the reason it degraded.
///
/// Reasons are stable tokens for `--explain`: `short-needle`, `stop-grams`,
/// `no-trigram`, `path`, `regex`, `glob`, `childfilecount`,
/// `childfoldercount`, `contenttype`, and `no-index`.
pub struct ScanLeaf {
  priv term : ScanTerm
  priv reason : String
}

///|
/// Why this leaf has no index support.
pub fn ScanLeaf::reason(self : ScanLeaf) -> String {
  self.reason
}

///|
/// Options for one indexed compile/evaluation.
///
/// `now` and `zone` resolve `dm:` deterministically in tests; the CLI leaves
/// them empty, which uses the current clock and the host's local time zone.
/// `optimize` is exposed so tests can compare a plan before and after the
/// optimizer without rebuilding the index.
pub(all) struct PlanOptions {
  now : Int64?
  zone : @time.Zone?
  optimize : Bool
}

///|
/// Build plan options.
pub fn PlanOptions::new(
  now~ : Int64? = None,
  zone~ : @time.Zone? = None,
  optimize~ : Bool = true,
) -> PlanOptions {
  { now, zone, optimize, }
}

///|
/// What part of the entry space a query subtree can match.
///
/// This is the plan's static type domain. It prunes whole branches before any
/// set is built: `file:` combined with `folder:` is `Never`, which compiles to
/// the empty set without touching the index.
priv enum Domain {
  FilesOnly
  FoldersOnly
  Both
  Never
}

///|
/// Intersection of two domains.
fn Domain::meet(self : Domain, other : Domain) -> Domain {
  match (self, other) {
    (Never, _) | (_, Never) => Never
    (Both, domain) | (domain, Both) => domain
    (FilesOnly, FilesOnly) => FilesOnly
    (FoldersOnly, FoldersOnly) => FoldersOnly
    (FilesOnly, FoldersOnly) | (FoldersOnly, FilesOnly) => Never
  }
}

///|
/// Union of two domains.
fn Domain::union(self : Domain, other : Domain) -> Domain {
  match (self, other) {
    (Never, domain) | (domain, Never) => domain
    (Both, _) | (_, Both) => Both
    (FilesOnly, FilesOnly) => FilesOnly
    (FoldersOnly, FoldersOnly) => FoldersOnly
    (FilesOnly, FoldersOnly) | (FoldersOnly, FilesOnly) => Both
  }
}

///|
/// Domain of a kind filter.
fn kind_domain(filter : @query.KindFilter) -> Domain {
  match filter {
    @query.AnyKind => Both
    @query.FilesOnly => FilesOnly
    @query.FoldersOnly => FoldersOnly
  }
}

///|
/// Domain of one term: its body's natural domain narrowed by its kind flags.
///
/// `ext:` and `contenttype:` never match folders, the child-count fields never
/// match files, and `--type`/`file:`/`folder:` narrow whatever the body allows.
/// Visibility does not restrict the kind, so it contributes `Both`.
fn domain_of_term(term : @query.Term) -> Domain {
  let body = match term.body() {
    @query.Kind(kind) => kind_domain(kind)
    @query.Extensions(_) | @query.TypeCategory(_) | @query.ContentType(_) =>
      FilesOnly
    @query.ChildCount(_)
    | @query.ChildFileCount(_)
    | @query.ChildFolderCount(_)
    | @query.Empty => FoldersOnly
    _ => Both
  }
  body.meet(kind_domain(term.flags().kind))
}

///|
/// Domain of a query tree.
///
/// `And` intersects, `Or` unions, and `Not` is always `Both`: a negation is
/// complemented over every entry, exactly like the scan engine.
fn domain_of_query(query : @query.Query) -> Domain {
  match query {
    @query.MatchAll => Both
    @query.MatchNone => Never
    @query.Term(term) => domain_of_term(term)
    @query.And(left, right) =>
      domain_of_query(left).meet(domain_of_query(right))
    @query.Or(left, right) =>
      domain_of_query(left).union(domain_of_query(right))
    @query.Not(_) => Both
  }
}

///|
/// Everything a compile needs besides the query itself.
///
/// `Ranges` is a value with lazily built fields; holding one copy per compile
/// keeps a field built by an early term available to later terms of the same
/// query. A live CLI index rebuilds a lazy field on a later query because the
/// in-memory index is not shared across compiles; S12 loads the fields from the
/// persisted database.
priv struct PlanContext {
  store : @core.Store
  dict : @index.Dict
  ranges : @index.Ranges
  trigram : @index.TrigramIndex?
  now : Int64
  zone : @time.Zone
}

///|
/// Compile a query into an execution plan.
///
/// With `options.optimize` the tree is passed through constant folding, type
/// domain pruning, cardinality-based reordering, and predicate pushdown. With
/// it disabled the tree is the direct translation, which the tests use as the
/// "before" side of the equivalence check.
pub fn compile_indexed(
  index : @index.Index,
  query : @query.Query,
  options~ : PlanOptions = PlanOptions::new(),
) -> Expr raise @query.QueryError {
  let context = plan_context(index, options)
  let expr = compile_plan(context, query)
  if options.optimize {
    optimize_plan(expr, {
      universe: context.dict.all(),
      total: context.store.entry_count(),
    })
  } else {
    expr
  }
}

///|
/// Evaluate a query with the indexed engine.
///
/// The result is a set of store-wide ids; turning it into ordered output is the
/// caller's job (`search` walks the canonical order and checks membership).
pub fn exec_indexed(
  index : @index.Index,
  query : @query.Query,
  options~ : PlanOptions = PlanOptions::new(),
) -> @ids.Ids raise @query.QueryError {
  let expr = compile_indexed(index, query, options~)
  evaluate_plan(expr, { store: index.store(), universe: index.dict().all(), })
}

///|
/// Count matches without materializing them in canonical order.
///
/// This is the indexed form of `count`: the answer is the cardinality of the
/// final set, not a walk over the store.
pub fn exec_indexed_count(
  index : @index.Index,
  query : @query.Query,
  options~ : PlanOptions = PlanOptions::new(),
) -> Int32 raise @query.QueryError {
  exec_indexed(index, query, options~).cardinality()
}

///|
/// Render a plan for `--explain`.
///
/// Every node carries its estimated cardinality and every degraded leaf carries
/// its reason, so a user can see which terms used an index and which fell back
/// to a scan.
pub fn explain_indexed(
  index : @index.Index,
  query : @query.Query,
  options~ : PlanOptions = PlanOptions::new(),
) -> String raise @query.QueryError {
  let expr = compile_indexed(index, query, options~)
  describe_plan(expr, index.entry_count())
}

///|
/// Resolve the clock and zone once per compile.
fn plan_context(index : @index.Index, options : PlanOptions) -> PlanContext {
  {
    store: index.store(),
    dict: index.dict(),
    ranges: index.ranges(),
    trigram: index.trigram(),
    now: match options.now {
      Some(value) => value
      None => @util.current_unix_seconds()
    },
    zone: match options.zone {
      Some(zone) => zone
      None => @util.local_zone()
    },
  }
}

///|
/// Compile one query node.
///
/// A `Never` domain is answered with the empty set before any child is visited.
/// This is the plan's type-domain pruning: `file:*.pdf folder:` never scans.
fn compile_plan(
  context : PlanContext,
  query : @query.Query,
) -> Expr raise @query.QueryError {
  if domain_of_query(query) is Never {
    return none_expr()
  }
  match query {
    @query.MatchAll => all_expr(context.dict.all())
    @query.MatchNone => none_expr()
    @query.Term(term) => compile_leaf(context, term)
    @query.And(left, right) =>
      Expr::And(compile_plan(context, left), compile_plan(context, right))
    @query.Or(left, right) =>
      Expr::Or(compile_plan(context, left), compile_plan(context, right))
    @query.Not(inner) => Expr::Not(compile_plan(context, inner))
  }
}

///|
/// Compile one term into an indexed leaf, a trigram leaf, or a scan leaf.
fn compile_leaf(
  context : PlanContext,
  term : @query.Term,
) -> Expr raise @query.QueryError {
  let scan = compile_term(term, context.now, context.zone)
  match scan.body {
    Name(matcher) => compile_name_leaf(context, scan, matcher)
    Kind(kind) => make_const(context, scan, kind_ids(context.dict, kind))
    Visibility(filter) =>
      make_const(context, scan, visibility_ids(context.dict, filter))
    Category(category, _) =>
      make_const(context, scan, context.dict.type_category(category))
    Extensions(list) =>
      make_const(context, scan, context.dict.lookup_extensions(list))
    Size(comparison) =>
      make_const(context, scan, range_ids(context.ranges.size(), comparison))
    Modified(comparison) =>
      make_const(context, scan, range_ids(context.ranges.mtime(), comparison))
    Depth(comparison) =>
      make_const(context, scan, range_ids(context.ranges.depth(), comparison))
    ChildCount(comparison) =>
      make_const(
        context,
        scan,
        range_ids(context.ranges.child_count(), comparison),
      )
    ChildFileCount(_) => Expr::Scan(scan_leaf(scan, "childfilecount"))
    ChildFolderCount(_) => Expr::Scan(scan_leaf(scan, "childfoldercount"))
    Parent(path) => make_const(context, scan, context.ranges.parent_ids(path))
    Empty => make_const(context, scan, context.ranges.child_count().equal(0L))
    ContentType(_) => Expr::Scan(scan_leaf(scan, "contenttype"))
  }
}

///|
/// Compile a name term.
///
/// Only a plain name substring or whole-name term can use the postings. A path
/// term can match text that lives in a parent directory name, a glob and a
/// regex are not literal substrings, and a needle shorter than one trigram has
/// no posting, so all of those stay scan leaves.
fn compile_name_leaf(
  context : PlanContext,
  scan : ScanTerm,
  matcher : NameMatcher,
) -> Expr {
  if matcher.path {
    return Expr::Scan(scan_leaf(scan, "path"))
  }
  match matcher.kind {
    Regex => return Expr::Scan(scan_leaf(scan, "regex"))
    Glob => return Expr::Scan(scan_leaf(scan, "glob"))
    Substring | Exact => ()
  }
  if matcher.needle.length() < 3 {
    return Expr::Scan(scan_leaf(scan, "short-needle"))
  }
  match context.trigram {
    None => Expr::Scan(scan_leaf(scan, "no-trigram"))
    Some(index) => {
      let lookup = index.lookup(matcher.needle[:])
      if lookup.is_missing() {
        // A required trigram does not occur in any name, so the exact answer is
        // the empty set; no candidate needs verifying.
        return none_expr()
      }
      match lookup.candidates() {
        Some(candidates) => {
          let filtered = apply_scan_flags(candidates, scan, context.dict)
          if filtered.is_empty() {
            none_expr()
          } else {
            Expr::Trigram({
              term: scan,
              needle: matcher.needle,
              candidates: filtered,
              keys: lookup.key_count(),
            })
          }
        }
        None =>
          if lookup.stop_gram_count() > 0 {
            Expr::Scan(scan_leaf(scan, "stop-grams"))
          } else {
            Expr::Scan(scan_leaf(scan, "no-index"))
          }
      }
    }
  }
}

///|
/// Build a constant leaf, applying the term's kind and visibility filters.
fn make_const(context : PlanContext, scan : ScanTerm, ids : @ids.Ids) -> Expr {
  Expr::Const({
    ids: apply_scan_flags(ids, scan, context.dict),
    label: explain_term(scan),
  })
}

///|
/// Intersect a candidate set with the term's kind and visibility sets.
fn apply_scan_flags(
  ids : @ids.Ids,
  term : ScanTerm,
  dict : @index.Dict,
) -> @ids.Ids {
  let mut result = ids
  match term.kind {
    @query.FilesOnly => result = result.intersect(dict.files_all())
    @query.FoldersOnly => result = result.intersect(dict.folders_all())
    @query.AnyKind => ()
  }
  match term.visibility {
    @query.HiddenOnly => result = result.intersect(dict.hidden())
    @query.VisibleOnly => result = result.intersect(dict.visible())
    @query.AnyVisibility => ()
  }
  result.normalize(dict.entry_count())
}

///|
/// The set selected by a kind filter.
fn kind_ids(dict : @index.Dict, filter : @query.KindFilter) -> @ids.Ids {
  match filter {
    @query.AnyKind => dict.all()
    @query.FilesOnly => dict.files_all()
    @query.FoldersOnly => dict.folders_all()
  }
}

///|
/// The set selected by a visibility filter.
fn visibility_ids(
  dict : @index.Dict,
  filter : @query.VisibilityFilter,
) -> @ids.Ids {
  match filter {
    @query.AnyVisibility => dict.all()
    @query.HiddenOnly => dict.hidden()
    @query.VisibleOnly => dict.visible()
  }
}

///|
/// Translate a parsed comparison into the matching range-index operation.
fn range_ids(
  index : @index.RangeIndex,
  comparison : @query.Comparison,
) -> @ids.Ids {
  match comparison.op {
    @query.Equal => index.equal(comparison.lo)
    @query.Greater => index.greater_than(comparison.lo)
    @query.GreaterEqual => index.at_least(comparison.lo)
    @query.Smaller => index.less_than(comparison.lo)
    @query.SmallerEqual => index.at_most(comparison.lo)
    @query.Range => index.range(comparison.lo, comparison.hi)
  }
}

///|
/// Build a scan leaf.
fn scan_leaf(term : ScanTerm, reason : String) -> ScanLeaf {
  { term, reason, }
}

///|
/// Build the empty-set leaf.
fn none_expr() -> Expr {
  Expr::Const({ ids: @ids.Ids::empty(), label: "(none)", })
}

///|
/// Build the universe leaf.
fn all_expr(universe : @ids.Ids) -> Expr {
  Expr::Const({ ids: universe, label: "(all)", })
}

///|
/// Whether a node is a constant empty set.
fn empty_const(expr : Expr) -> Bool {
  match expr {
    Const(leaf) => leaf.ids.is_empty()
    _ => false
  }
}

///|
/// Whether a node is a constant covering the whole index.
fn full_const(expr : Expr, total : Int32) -> Bool {
  match expr {
    Const(leaf) => leaf.ids.cardinality() == total
    _ => false
  }
}

///|
/// Context for one optimization pass.
priv struct OptimizeContext {
  universe : @ids.Ids
  total : Int32
}

///|
/// Rewrite a plan into an equivalent but cheaper one.
///
/// The passes are:
///
/// 1. constant folding — merge adjacent constants, absorb empty with `And`,
///    absorb the universe with `Or`, and complement a constant negation;
/// 2. reordering — evaluate the smaller `And` side first so the intersection
///    turns empty as early as possible;
/// 3. predicate pushdown — move a `Scan` leaf out of an `And` and turn it into a
///    `Filter` over the other side, so globs and regexes only visit candidates
///    the index already narrowed.
fn optimize_plan(expr : Expr, context : OptimizeContext) -> Expr {
  match expr {
    Const(_) | Trigram(_) | Scan(_) => expr
    Not(inner) => optimize_not(optimize_plan(inner, context), context)
    And(left, right) =>
      optimize_and(
        optimize_plan(left, context),
        optimize_plan(right, context),
        context,
      )
    Or(left, right) =>
      optimize_or(
        optimize_plan(left, context),
        optimize_plan(right, context),
        context,
      )
    Filter(predicate, source) => {
      let source = optimize_plan(source, context)
      if empty_const(source) {
        none_expr()
      } else {
        Expr::Filter(predicate, source)
      }
    }
  }
}

///|
/// Optimize an `And` node.
fn optimize_and(left : Expr, right : Expr, context : OptimizeContext) -> Expr {
  if empty_const(left) || empty_const(right) {
    return none_expr()
  }
  if full_const(left, context.total) {
    return right
  }
  if full_const(right, context.total) {
    return left
  }
  match (left, right) {
    (Const(a), Const(b)) => {
      let ids = a.ids.intersect(b.ids).normalize(context.total)
      if ids.is_empty() {
        none_expr()
      } else {
        Expr::Const({ ids, label: "(and \{a.label} \{b.label})", })
      }
    }
    (Scan(predicate), _) => Expr::Filter(predicate, right)
    (_, Scan(predicate)) => Expr::Filter(predicate, left)
    _ =>
      if estimate_plan(right, context.total) <
        estimate_plan(left, context.total) {
        Expr::And(right, left)
      } else {
        Expr::And(left, right)
      }
  }
}

///|
/// Optimize an `Or` node.
fn optimize_or(left : Expr, right : Expr, context : OptimizeContext) -> Expr {
  if empty_const(left) {
    return right
  }
  if empty_const(right) {
    return left
  }
  if full_const(left, context.total) || full_const(right, context.total) {
    return all_expr(context.universe)
  }
  match (left, right) {
    (Const(a), Const(b)) => {
      let ids = a.ids.union(b.ids).normalize(context.total)
      Expr::Const({ ids, label: "(or \{a.label} \{b.label})", })
    }
    _ =>
      if estimate_plan(right, context.total) <
        estimate_plan(left, context.total) {
        Expr::Or(right, left)
      } else {
        Expr::Or(left, right)
      }
  }
}

///|
/// Optimize a `Not` node.
///
/// A constant complement becomes another constant, and double negation
/// collapses. A non-constant negation stays over the whole universe, matching
/// the scan engine's `Both` domain.
fn optimize_not(inner : Expr, context : OptimizeContext) -> Expr {
  match inner {
    Const(leaf) => {
      let ids = context.universe.difference(leaf.ids).normalize(context.total)
      if ids.is_empty() {
        none_expr()
      } else if ids.cardinality() == context.total {
        all_expr(context.universe)
      } else {
        Expr::Const({ ids, label: "(not \{leaf.label})", })
      }
    }
    Not(inner) => inner
    _ => Expr::Not(inner)
  }
}

///|
/// Cardinality estimate of a plan node.
///
/// Estimates drive `And`/`Or` ordering only; they never affect the result.
/// Constants are exact, a trigram leaf is the candidate count, a scan is the
/// whole index, an `And` takes the smaller side, an `Or` adds (capped at the
/// index size), and a `Not` subtracts from the index size.
pub fn Expr::estimate(self : Expr, total : Int32) -> Int32 {
  estimate_plan(self, total)
}

///|
/// Estimate one plan node.
fn estimate_plan(expr : Expr, total : Int32) -> Int32 {
  match expr {
    Const(leaf) => {
      let card = leaf.ids.cardinality()
      if total > 0 && card > total {
        total
      } else {
        card
      }
    }
    Trigram(leaf) => leaf.candidates.cardinality()
    Scan(_) => total
    Filter(_, source) => estimate_plan(source, total)
    And(left, right) => {
      let left_estimate = estimate_plan(left, total)
      let right_estimate = estimate_plan(right, total)
      if left_estimate < right_estimate {
        left_estimate
      } else {
        right_estimate
      }
    }
    Or(left, right) => {
      let sum = estimate_plan(left, total).to_int64() +
        estimate_plan(right, total).to_int64()
      if sum > total.to_int64() {
        total
      } else {
        sum.to_int()
      }
    }
    Not(inner) => {
      let value = total - estimate_plan(inner, total)
      if value < 0 {
        0
      } else {
        value
      }
    }
  }
}

///|
/// Render a plan as one deterministic line.
///
/// Shape: `(node#estimate ...)`. Constants keep the label of the terms that
/// produced them, trigram leaves report the intersected key count, and scan
/// leaves report their degradation reason.
fn describe_plan(expr : Expr, total : Int32) -> String {
  match expr {
    Const(leaf) => "(const#\{leaf.ids.cardinality()} \{leaf.label})"
    Trigram(leaf) =>
      "(trigram#\{leaf.candidates.cardinality()} keys=\{leaf.keys} \{explain_term(leaf.term)})"
    Scan(leaf) =>
      "(scan#\{total} reason=\{leaf.reason} \{explain_term(leaf.term)})"
    Filter(predicate, source) =>
      "(filter#\{estimate_plan(source, total)} \{explain_term(predicate.term)} \{describe_plan(source, total)})"
    And(left, right) =>
      "(and#\{estimate_plan(expr, total)} \{describe_plan(left, total)} \{describe_plan(right, total)})"
    Or(left, right) =>
      "(or#\{estimate_plan(expr, total)} \{describe_plan(left, total)} \{describe_plan(right, total)})"
    Not(inner) =>
      "(not#\{estimate_plan(expr, total)} \{describe_plan(inner, total)})"
  }
}

///|
/// Human-readable form of a plan, used by `--explain` and by tests.
pub fn Expr::describe(self : Expr, total : Int32) -> String {
  describe_plan(self, total)
}

///|
/// Evaluation context: the store plus the set every `Scan` and `Not` starts
/// from.
priv struct EvalContext {
  store : @core.Store
  universe : @ids.Ids
}

///|
/// Evaluate a plan node into an id set.
///
/// `And` short-circuits when the first side is empty. `Filter` verifies only the
/// candidates its source produced, which is the payoff of predicate pushdown.
fn evaluate_plan(expr : Expr, context : EvalContext) -> @ids.Ids {
  match expr {
    Const(leaf) => leaf.ids
    Trigram(leaf) =>
      leaf.candidates.filter(fn(id) { verify_term(leaf.term, context, id) })
    Scan(leaf) =>
      context.universe.filter(fn(id) { verify_term(leaf.term, context, id) })
    Filter(predicate, source) =>
      evaluate_plan(source, context).filter(fn(id) {
        verify_term(predicate.term, context, id)
      })
    And(left, right) => {
      let left_ids = evaluate_plan(left, context)
      if left_ids.is_empty() {
        left_ids
      } else {
        left_ids.intersect(evaluate_plan(right, context))
      }
    }
    Or(left, right) =>
      evaluate_plan(left, context).union(evaluate_plan(right, context))
    Not(inner) => context.universe.difference(evaluate_plan(inner, context))
  }
}

///|
/// Verify one candidate id with the same predicate the scan engine uses.
///
/// Candidates come from postings and range slices, so an id is expected to be
/// in range; an out-of-range id is treated as a non-match instead of panicking.
fn verify_term(term : ScanTerm, context : EvalContext, id : Int32) -> Bool {
  match context.store.entry_at(id) {
    Some(entry) => eval_term(term, context.store, entry)
    None => false
  }
}
