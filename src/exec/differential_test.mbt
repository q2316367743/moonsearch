// S13 differential runner: every query in the three-layer corpus must produce
// the same result on the indexed engine and the scan engine.
//
// The comparison is stronger than set equality: both results are expanded in
// the store's canonical order, so an indexed plan that returns the right ids
// but loses the order contract still fails. Both the optimized and the
// unoptimized plan trees are checked, and `exec_indexed_count` must agree with
// the number of scan hits.
//
// Fixtures cover an empty store, a hand-written store, deterministic random
// trees, unicode names, and a store whose names all share the same trigrams
// (which forces the stop-gram degradation). `--no-trigram` indexes are
// compared on the same corpus to keep the degraded candidate path honest.

///|
/// Fixed clock for the differential corpus: 2024-03-20 00:00:00 UTC.
const DIFF_NOW : Int64 = 1710892800L

///|
/// Fixed seed for every deterministic fixture and generated query.
const DIFF_SEED : UInt64 = 20241118UL

///|
/// Scan options with the pinned clock.
fn diff_scan_options() -> @exec.ScanOptions {
  @exec.ScanOptions::new(now=Some(DIFF_NOW), zone=Some(@time.utc_zone))
}

///|
/// Plan options with the pinned clock.
fn diff_plan_options(optimize~ : Bool) -> @exec.PlanOptions {
  @exec.PlanOptions::new(
    now=Some(DIFF_NOW),
    zone=Some(@time.utc_zone),
    optimize~,
  )
}

///|
/// Parse a corpus query or fail with its text.
fn diff_parse(text : String) -> @query.Query {
  @query.parse(text) catch {
    err => abort("corpus query '\{text}' failed to parse: \{err.message()}")
  }
}

///|
/// Run the scan engine and return the matching ids in canonical order.
fn diff_scan_ids(
  store : @core.Store,
  query : @query.Query,
) -> Array[Int32] raise @query.QueryError {
  let hits = @exec.exec_scan_with(store, query, options=diff_scan_options())
  let ids : Array[Int32] = []
  for entry in hits {
    ids.push(store.global_id(entry))
  }
  ids
}

///|
/// Expand an id set into the store's canonical order.
fn diff_canonical(store : @core.Store, ids : @ids.Ids) -> Array[Int32] {
  let ordered : Array[Int32] = []
  for entry in store.entries_in_order() {
    let id = store.global_id(entry)
    if ids.contains(id) {
      ordered.push(id)
    }
  }
  ordered
}

///|
/// Comma-joined ids for failure messages, so a mismatch is readable without
/// relying on the deprecated `Show` implementation of arrays.
fn diff_ids_text(ids : Array[Int32]) -> String {
  let parts : Array[String] = []
  for id in ids {
    parts.push(id.to_string())
  }
  parts.join(",")
}

///|
/// Assert that one query agrees on both engines, in both plan modes, and that
/// the count path agrees too.
fn diff_check(index : @index.Index, label : String, text : String) -> Unit {
  let store = index.store()
  let query = diff_parse(text)
  let expected = diff_scan_ids(store, query) catch {
    err => abort("scan failed for '\{text}' on \{label}: \{err.message()}")
  }
  // The scan engine returns canonical order; compare the sets in id order and
  // the order separately.
  let expected_sorted = @ids.Ids::from_sorted(expected).to_sorted_ids()
  for optimize in [false, true] {
    let result = @exec.exec_indexed(
      index,
      query,
      options=diff_plan_options(optimize~),
    ) catch {
      err =>
        abort(
          "indexed plan (optimize=\{optimize}) failed for '\{text}' on \{label}: \{err.message()}",
        )
    }
    let sorted = result.to_sorted_ids()
    if sorted != expected_sorted {
      abort(
        "set mismatch on \{label} for '\{text}' (optimize=\{optimize}): scan=\{diff_ids_text(expected_sorted)} indexed=\{diff_ids_text(sorted)}",
      )
    }
    let ordered = diff_canonical(store, result)
    if ordered != expected {
      abort(
        "order mismatch on \{label} for '\{text}' (optimize=\{optimize}): scan=\{diff_ids_text(expected)} indexed=\{diff_ids_text(ordered)}",
      )
    }
    let count = @exec.exec_indexed_count(
      index,
      query,
      options=diff_plan_options(optimize~),
    ) catch {
      err =>
        abort(
          "indexed count failed for '\{text}' on \{label}: \{err.message()}",
        )
    }
    if count != expected.length() {
      abort(
        "count mismatch on \{label} for '\{text}' (optimize=\{optimize}): scan=\{expected.length()} indexed=\{count}",
      )
    }
  }
}

///|
/// Run a whole corpus against one index.
fn diff_run(
  index : @index.Index,
  label : String,
  queries : Array[String],
) -> Unit {
  for text in queries {
    diff_check(index, label, text)
  }
}

///|
/// The corpus with the clock-dependent date layer appended.
fn diff_corpus(seed : UInt64, generated : Int32) -> Array[String] {
  let queries = @testkit.differential_queries(seed, generated)
  for text in @testkit.date_queries() {
    queries.push(text)
  }
  queries
}

///|
/// Word vocabulary for synthetic fixtures.
fn diff_words() -> Array[String] {
  [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india",
    "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo",
    "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu",
    "report", "draft", "final", "photo", "invoice", "notes", "archive", "readme",
    "config", "data", "backup",
  ]
}

///|
/// Extension vocabulary, mixing case so extension folding is exercised.
fn diff_extensions() -> Array[String] {
  ["txt", "pdf", "jpg", "JPG", "md", "zip", "mp4", "rs", "json", "TXT"]
}

///|
/// One unique, varied name: optional hidden prefix, optional unicode base,
/// a serial number, and an extension.
fn diff_random_name(rng : @testkit.Rng, serial : Int32) -> String {
  let hidden = rng.chance(8)
  let mut name = if hidden { "." } else { "" }
  if rng.chance(5) {
    name = name + "发票" + serial.to_string()
  } else {
    name = name + rng.pick(diff_words()) + "-" + serial.to_string()
  }
  if rng.chance(12) {
    name = name + ".TXT"
  } else {
    name = name + "." + rng.pick(diff_extensions())
  }
  name
}

///|
/// Build a deterministic synthetic tree.
///
/// The generator keeps child counts, subtree sizes, hidden flags, and root
/// statistics consistent, so every range and dictionary field has meaningful
/// values. Names are unique because the serial number is part of the name.
fn diff_random_store(
  seed : UInt64,
  entries : Int32,
) -> @core.Store raise @index.IndexError {
  let rng = @testkit.Rng::new(seed)
  let builder = @index.Builder::new()
  ignore(builder.add_root(b"/rand", false, 1700000000L))
  let folder_sizes : Array[Int64] = [0L]
  let folder_parents : Array[Int32] = [@core.NO_PARENT]
  let direct_files : Array[Int32] = [0]
  let direct_folders : Array[Int32] = [0]
  let mut serial = 0
  let mut file_total = 0
  for _ in 0..<entries {
    let parent = rng.below(builder.folder_count())
    let mtime = 1700000000L + rng.below(4000000).to_int64()
    serial = serial + 1
    let name = diff_random_name(rng, serial)
    if rng.chance(30) {
      let flags : UInt16 = if name.get_char(0) is Some('.') {
        @core.ENTRY_FLAG_HIDDEN
      } else {
        0
      }
      ignore(builder.add_folder(parent, @utf8.encode(name), mtime, flags~))
      folder_sizes.push(0L)
      folder_parents.push(parent)
      direct_files.push(0)
      direct_folders.push(0)
      direct_folders[parent] = direct_folders[parent] + 1
    } else {
      let size = if rng.chance(10) { 0L } else { rng.below(200000).to_int64() }
      let flags : UInt16 = if name.get_char(0) is Some('.') {
        @core.ENTRY_FLAG_HIDDEN
      } else {
        0
      }
      ignore(builder.add_file(parent, @utf8.encode(name), size, mtime, flags~))
      file_total = file_total + 1
      direct_files[parent] = direct_files[parent] + 1
      // Folder size is the whole subtree, so add to every ancestor.
      let mut slot = parent
      while slot >= 0 {
        folder_sizes[slot] = folder_sizes[slot] + size
        slot = folder_parents[slot]
      }
    }
  }
  for folder in 0..<builder.folder_count() {
    builder.set_child_counts(
      folder,
      direct_files[folder].reinterpret_as_uint(),
      direct_folders[folder].reinterpret_as_uint(),
    )
    builder.add_folder_size(folder, folder_sizes[folder])
  }
  builder.set_root_stats(
    0,
    file_total.reinterpret_as_uint(),
    (builder.folder_count() - 1).reinterpret_as_uint(),
    folder_sizes[0],
  )
  builder.finish(built_at=1700000000L)
}

///|
/// A store whose names are mostly unicode, mixed case, and spaces.
fn diff_unicode_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/uni", false, 1700000000L)
  let docs = builder.add_folder(root, b"文档", 1700000100L)
  let names : Array[String] = [
    "发票.pdf", "报告 2024.txt", "résumé.md", "café.txt", "emoji-😀.txt",
    "ÜBER.TXT", "straße.txt", ".秘密", "naïve-file.rs",
  ]
  for index in 0..<names.length() {
    let flags : UInt16 = if names[index].get_char(0) is Some('.') {
      @core.ENTRY_FLAG_HIDDEN
    } else {
      0
    }
    ignore(
      builder.add_file(
        root,
        @utf8.encode(names[index]),
        10L + index.to_int64(),
        1700000200L,
        flags~,
      ),
    )
  }
  ignore(builder.add_file(docs, b"readme.txt", 7L, 1700000300L))
  builder.set_child_counts(docs, 1U, 0U)
  builder.set_child_counts(root, 9U, 1U)
  builder.add_folder_size(docs, 7L)
  builder.add_folder_size(root, 133L)
  builder.set_root_stats(0, 10U, 1U, 133L)
  builder.finish(built_at=1700000000L)
}

///|
/// A store where every name shares the same trigrams, so a query for those
/// trigrams has no usable posting and must fall back to a scan.
fn diff_stop_gram_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/sg", false, 1700000000L)
  for index in 0..<20 {
    ignore(
      builder.add_file(
        root,
        @utf8.encode("testcase-\{index}.txt"),
        1L,
        1700000000L,
      ),
    )
  }
  builder.set_child_counts(root, 20U, 0U)
  builder.add_folder_size(root, 20L)
  builder.set_root_stats(0, 20U, 0U, 20L)
  builder.finish(built_at=1700000000L)
}

///|
/// Build an index over a fixture, failing the test on an internal error.
fn diff_index(store : @core.Store, trigram~ : Bool = true) -> @index.Index {
  @index.Index::build(store, eager=@index.RangeFieldSet::all(), trigram~)
}

///|
test "indexed and scan engines agree on the hand-written fixture" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let index = diff_index(store)
  diff_run(index, "hand-written", diff_corpus(DIFF_SEED, 160))
}

///|
test "indexed and scan engines agree on deterministic random trees" {
  for seed in [1UL, 42UL, 20241118UL] {
    let store = diff_random_store(seed, 50) catch {
      err => abort("random fixture \{seed} failed: \{err.message()}")
    }
    let index = diff_index(store)
    diff_run(index, "random-\{seed}", diff_corpus(seed, 100))
  }
}

///|
test "indexed and scan engines agree on an empty store" {
  let names = @core.NamePool::new()
  let store = @core.Store::new(
    names~,
    folders=[],
    files=[],
    roots=[],
    built_at=0L,
  )
  let index = diff_index(store)
  diff_run(index, "empty", diff_corpus(DIFF_SEED, 100))
}

///|
test "indexed and scan engines agree on unicode names" {
  let store = diff_unicode_store() catch {
    err => abort("unicode fixture failed: \{err.message()}")
  }
  let index = diff_index(store)
  diff_run(index, "unicode", diff_corpus(DIFF_SEED, 100))
}

///|
test "indexed and scan engines agree when every name is a stop-gram" {
  let store = diff_stop_gram_store() catch {
    err => abort("stop-gram fixture failed: \{err.message()}")
  }
  let index = diff_index(store)
  diff_run(index, "stop-gram", diff_corpus(DIFF_SEED, 100))
  // The query that motivated the fixture really does degrade to a scan.
  let plan = @exec.compile_indexed(
    index,
    diff_parse("test"),
    options=diff_plan_options(optimize=false),
  ) catch {
    err => abort("compile failed: \{err.message()}")
  }
  match plan {
    @exec.Scan(leaf) => assert_eq(leaf.reason(), "stop-grams")
    _ => abort("expected a stop-gram scan leaf for 'test'")
  }
}

///|
test "the --no-trigram index agrees with the scan engine" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let index = diff_index(store, trigram=false)
  diff_run(index, "no-trigram", diff_corpus(DIFF_SEED, 160))
  // Every generated name query must report the degradation, not a silent
  // candidate set.
  let plan = @exec.compile_indexed(
    index,
    diff_parse("report"),
    options=diff_plan_options(optimize=false),
  ) catch {
    err => abort("compile failed: \{err.message()}")
  }
  match plan {
    @exec.Scan(leaf) => assert_eq(leaf.reason(), "no-trigram")
    _ => abort("expected a no-trigram scan leaf")
  }
}

///|
/// Add a name to a unique list unless it is already there.
fn diff_add_unique(values : Array[String], value : String) -> Unit {
  for existing in values {
    if existing == value {
      return
    }
  }
  values.push(value)
}

///|
/// Collect every plan node kind and every scan degradation reason in a tree.
fn diff_collect_explain(
  expr : @exec.Expr,
  shapes : Array[String],
  reasons : Array[String],
) -> Unit {
  match expr {
    @exec.Const(_) => diff_add_unique(shapes, "const")
    @exec.Trigram(_) => diff_add_unique(shapes, "trigram")
    @exec.Scan(leaf) => {
      diff_add_unique(shapes, "scan")
      diff_add_unique(reasons, leaf.reason())
    }
    @exec.Filter(predicate, source) => {
      diff_add_unique(shapes, "filter")
      diff_add_unique(reasons, predicate.reason())
      diff_collect_explain(source, shapes, reasons)
    }
    @exec.And(left, right) => {
      diff_add_unique(shapes, "and")
      diff_collect_explain(left, shapes, reasons)
      diff_collect_explain(right, shapes, reasons)
    }
    @exec.Or(left, right) => {
      diff_add_unique(shapes, "or")
      diff_collect_explain(left, shapes, reasons)
      diff_collect_explain(right, shapes, reasons)
    }
    @exec.Not(inner) => {
      diff_add_unique(shapes, "not")
      diff_collect_explain(inner, shapes, reasons)
    }
  }
}

///|
test "the explain corpus reaches every plan node and degradation reason" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let stop_store = diff_stop_gram_store() catch {
    err => abort("stop-gram fixture failed: \{err.message()}")
  }
  let indexes : Array[(@index.Index, String)] = [
    (diff_index(store), "indexed"),
    (diff_index(stop_store), "stop-gram"),
    (diff_index(store, trigram=false), "no-trigram"),
  ]
  let shapes : Array[String] = []
  let reasons : Array[String] = []
  for pair in indexes {
    let index = pair.0
    for text in @testkit.explain_queries() {
      let query = diff_parse(text)
      for optimize in [false, true] {
        let plan = @exec.compile_indexed(
          index,
          query,
          options=diff_plan_options(optimize~),
        ) catch {
          err => abort("explain compile failed for '\{text}': \{err.message()}")
        }
        diff_collect_explain(plan, shapes, reasons)
      }
    }
  }
  let required_shapes : Array[String] = [
    "const", "trigram", "scan", "filter", "and", "or", "not",
  ]
  for shape in required_shapes {
    if !shapes.contains(shape) {
      abort(
        "explain corpus never produced a \{shape} node; saw \{shapes.join(",")}",
      )
    }
  }
  for reason in @testkit.scan_reasons() {
    if !reasons.contains(reason) {
      abort(
        "explain corpus never degraded for reason '\{reason}'; saw \{reasons.join(",")}",
      )
    }
  }
  // `no-index` is a defensive branch: a well-formed index always counts a
  // skipped posting as a stop-gram. It must never appear unexpectedly either.
  if reasons.contains("no-index") {
    abort("the defensive 'no-index' reason was observed")
  }
}
