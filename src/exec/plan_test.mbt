///|
/// Build the shared exec fixture as an indexed engine input.
///
/// Every range field is eager so the compile-shape tests never depend on lazy
/// materialization, and `trigram=false` models a `--no-trigram` build.
fn plan_index(trigram~ : Bool = true) -> @index.Index {
  let store = test_store() catch {
    err => abort("plan fixture failed: \{err.message()}")
  }
  @index.Index::build(store, eager=@index.RangeFieldSet::all(), trigram~)
}

///|
/// Plan options with the fixed test clock.
fn plan_options(optimize~ : Bool = true) -> @exec.PlanOptions {
  @exec.PlanOptions::new(
    now=Some(TEST_NOW),
    zone=Some(@time.utc_zone),
    optimize~,
  )
}

///|
/// Compile a query against an index.
fn plan_of(
  index : @index.Index,
  text : String,
  optimize~ : Bool = true,
) -> @exec.Expr {
  @exec.compile_indexed(index, query_of(text), options=plan_options(optimize~)) catch {
    err => abort("compile '\{text}' failed: \{err.message()}")
  }
}

///|
/// Evaluate a query with the indexed engine.
fn plan_ids(
  index : @index.Index,
  text : String,
  optimize~ : Bool = true,
) -> @ids.Ids {
  @exec.exec_indexed(index, query_of(text), options=plan_options(optimize~)) catch {
    err => abort("indexed query '\{text}' failed: \{err.message()}")
  }
}

///|
/// Evaluate a query with the scan engine and return the same id-set form.
fn plan_scan_ids(index : @index.Index, text : String) -> @ids.Ids {
  let store = index.store()
  let options = @exec.ScanOptions::new(
    now=Some(TEST_NOW),
    zone=Some(@time.utc_zone),
  )
  let hits = @exec.exec_scan_with(store, query_of(text), options~) catch {
    err => abort("scan query '\{text}' failed: \{err.message()}")
  }
  let ids : Array[Int32] = []
  for entry in hits {
    ids.push(store.global_id(entry))
  }
  @ids.Ids::from_sorted(ids, total=store.entry_count())
}

///|
/// Assert that a plan node is a constant with exactly the expected ids.
fn assert_plan_const(
  expr : @exec.Expr,
  expected : @ids.Ids,
  label : String,
) -> Unit {
  match expr {
    @exec.Const(leaf) =>
      if leaf.ids().to_sorted_ids() != expected.to_sorted_ids() {
        abort("constant plan for \{label} does not match the expected set")
      }
    _ => abort("expected a constant plan for \{label}")
  }
}

///|
/// Assert that a plan node is a scan leaf with the expected degradation reason.
fn assert_plan_scan(expr : @exec.Expr, reason : String, label : String) -> Unit {
  match expr {
    @exec.Scan(leaf) =>
      if leaf.reason() != reason {
        abort(
          "scan plan for \{label} degraded to \{leaf.reason()}, expected \{reason}",
        )
      }
    _ => abort("expected a scan plan for \{label}")
  }
}

///|
test "indexed fields compile to the dictionary and range sets" {
  let index = plan_index()
  let dict = index.dict()
  let ranges = index.ranges()
  assert_plan_const(plan_of(index, "file:"), dict.files_all(), "file:")
  assert_plan_const(plan_of(index, "folder:"), dict.folders_all(), "folder:")
  assert_plan_const(plan_of(index, "hidden:"), dict.hidden(), "hidden:")
  assert_plan_const(plan_of(index, "nohidden:"), dict.visible(), "nohidden:")
  assert_plan_const(
    plan_of(index, "doc:"),
    dict.type_category(@util.TypeCategory::Doc),
    "doc:",
  )
  assert_plan_const(
    plan_of(index, "ext:pdf"),
    dict.extension(b"pdf"[:]),
    "ext:pdf",
  )
  assert_plan_const(
    plan_of(index, "ext:txt;md"),
    dict.lookup_extensions([b"txt", b"md"]),
    "ext:txt;md",
  )
  // An empty extension is a real bucket, not the empty set.
  assert_plan_const(plan_of(index, "ext:"), dict.extension(b""[:]), "ext:")
  assert_plan_const(
    plan_of(index, "size:>1500"),
    ranges.size().greater_than(1500L),
    "size:>1500",
  )
  assert_plan_const(
    plan_of(index, "size:1kb..2kb"),
    ranges.size().range(1000L, 2000L),
    "size:1kb..2kb",
  )
  assert_plan_const(
    plan_of(index, "depth:2"),
    ranges.depth().equal(2L),
    "depth:2",
  )
  assert_plan_const(
    plan_of(index, "childcount:0"),
    ranges.child_count().equal(0L),
    "childcount:0",
  )
  assert_plan_const(
    plan_of(index, "empty:"),
    ranges.child_count().equal(0L),
    "empty:",
  )
  assert_plan_const(
    plan_of(index, "parent:/root/docs"),
    ranges.parent_ids(b"/root/docs"[:]),
    "parent:/root/docs",
  )
  let march = @util.resolve_date_span("2024-03", TEST_NOW, @time.utc_zone).unwrap()
  assert_plan_const(
    plan_of(index, "dm:2024-03"),
    ranges.mtime().range(march.start, march.end),
    "dm:2024-03",
  )
}

///|
test "term flags narrow the compiled constant" {
  let index = plan_index()
  let dict = index.dict()
  let ranges = index.ranges()
  // `ext:` never matches folders, so the folder modifier leaves nothing.
  assert_plan_const(
    plan_of(index, "folder:ext:pdf"),
    @ids.Ids::empty(),
    "folder:ext:pdf",
  )
  assert_plan_const(
    plan_of(index, "file:size:>1500"),
    ranges.size().greater_than(1500L).intersect(dict.files_all()),
    "file:size:>1500",
  )
  assert_plan_const(
    plan_of(index, "hidden:file:"),
    dict.hidden().intersect(dict.files_all()),
    "hidden:file:",
  )
  // `file:` and `folder:` cannot both hold, so the domain is pruned to empty.
  assert_plan_const(
    plan_of(index, "file:*.pdf folder:"),
    @ids.Ids::empty(),
    "file:*.pdf folder:",
  )
}

///|
test "name terms choose trigram or scan by capability" {
  let index = plan_index()
  match plan_of(index, "report") {
    @exec.Trigram(leaf) => {
      assert_true(leaf.key_count() > 0)
      let lookup = index.trigram().unwrap().lookup(b"report"[:])
      let expected = lookup.candidates().unwrap()
      assert_eq(leaf.candidates().to_sorted_ids(), expected.to_sorted_ids())
    }
    _ => abort("expected a trigram plan for report")
  }
  // Exact matching is a subset of substring matching, so it reuses the postings.
  match plan_of(index, "exact:report") {
    @exec.Trigram(_) => ()
    _ => abort("expected a trigram plan for exact:report")
  }
  // Case folding only broadens the candidate set.
  match plan_of(index, "case:REPORT") {
    @exec.Trigram(_) => ()
    _ => abort("expected a trigram plan for case:REPORT")
  }
  assert_plan_scan(plan_of(index, "re"), "short-needle", "re")
  assert_plan_scan(plan_of(index, "*.pdf"), "glob", "*.pdf")
  assert_plan_scan(plan_of(index, "regex:\"^photo\""), "regex", "regex")
  assert_plan_scan(plan_of(index, "path:docs"), "path", "path:docs")
  assert_plan_scan(
    plan_of(index, "childfilecount:2"),
    "childfilecount",
    "childfilecount:2",
  )
  assert_plan_scan(
    plan_of(index, "childfoldercount:3"),
    "childfoldercount",
    "childfoldercount:3",
  )
  assert_plan_scan(
    plan_of(index, "contenttype:pdf"),
    "contenttype",
    "contenttype:pdf",
  )
  // A trigram that occurs in no name proves the answer is empty.
  assert_plan_const(plan_of(index, "zzzz"), @ids.Ids::empty(), "zzzz")
}

///|
test "a no-trigram index falls back to scanning for names" {
  let index = plan_index(trigram=false)
  assert_plan_scan(plan_of(index, "report"), "no-trigram", "report")
  // Field terms are still indexed without postings.
  assert_plan_const(
    plan_of(index, "ext:pdf"),
    index.dict().extension(b"pdf"[:]),
    "ext:pdf",
  )
}

///|
test "optimized and unoptimized plans agree with the scan engine" {
  let index = plan_index()
  let queries : Array[String] = [
    "", "report", "REPORT", "case:REPORT", "exact:readme.md", "exact:report", "*.pdf",
    "*.PDF", "?hidden", "photo*", "regex:\"^photo\"", "regex:\"\\.pdf$\"", "path:docs",
    "/root/media", "media", "ext:pdf", "ext:JPG", "ext:txt;md", "ext:", "folder:ext:pdf",
    "size:>1500", "size:..100", "size:1kb..2kb", "file:size:2000", "depth:0", "depth:1",
    "depth:<=2", "depth:>2", "childcount:0", "childcount:>0", "empty:", "childfilecount:2",
    "childfoldercount:3", "parent:/root/docs", "parent:/root/", "parent:/", "contenttype:pdf",
    "contenttype:image", "contenttype:text", "dm:2024-03", "dm:2024-02", "dm:>=2024-03-01",
    "dm:<2024-02-01", "pdf OR txt", "ext:pdf ext:txt", "!pdf", "(pdf OR txt) !draft",
    "folder:docs", "folder:report", "file:hidden:doc:", "hidden:", "nohidden:", "doc:",
    "pic:", "pdf size:>1500", "report pdf", "*.pdf size:>1kb", "*.pdf report", "file:*.pdf folder:",
  ]
  for text in queries {
    let expected = plan_scan_ids(index, text).to_sorted_ids()
    let raw = plan_ids(index, text, optimize=false).to_sorted_ids()
    if raw != expected {
      abort("unoptimized plan mismatch for '\{text}'")
    }
    let optimized = plan_ids(index, text, optimize=true).to_sorted_ids()
    if optimized != expected {
      abort("optimized plan mismatch for '\{text}'")
    }
    let count = @exec.exec_indexed_count(
      index,
      query_of(text),
      options=plan_options(),
    ) catch {
      err => abort("indexed count '\{text}' failed: \{err.message()}")
    }
    assert_eq(count, expected.length())
  }
}

///|
test "a no-trigram index still matches the scan engine" {
  let index = plan_index(trigram=false)
  for
    text in [
      "", "report", "exact:report", "*.pdf", "path:docs", "ext:pdf", "!pdf", "report pdf",
      "size:>1500", "dm:2024-03",
    ] {
    let expected = plan_scan_ids(index, text).to_sorted_ids()
    let optimized = plan_ids(index, text).to_sorted_ids()
    if optimized != expected {
      abort("no-trigram mismatch for '\{text}'")
    }
  }
}

///|
test "the optimizer folds constants and prunes impossible domains" {
  let index = plan_index()
  // Two extension sets cannot both match.
  match plan_of(index, "ext:pdf ext:txt") {
    @exec.Const(leaf) => assert_eq(leaf.ids().cardinality(), 0)
    _ => abort("expected the intersection to fold to a constant")
  }
  // A file-only term and a folder-only term are disjoint domains.
  match plan_of(index, "file:report folder:") {
    @exec.Const(leaf) => assert_eq(leaf.ids().cardinality(), 0)
    _ => abort("expected the domain contradiction to be empty")
  }
  // A constant negation becomes another constant.
  match plan_of(index, "!ext:pdf") {
    @exec.Const(leaf) => {
      assert_eq(leaf.ids().cardinality(), index.entry_count() - 1)
      assert_false(leaf.ids().contains(4))
    }
    _ => abort("expected the negation to fold to a constant")
  }
  // `pdf OR ext:mp4` drops the empty side.
  match plan_of(index, "pdf OR ext:mp4") {
    @exec.Trigram(_) => ()
    _ => abort("expected the empty OR side to be absorbed")
  }
}

///|
test "scan predicates are pushed below indexed candidates" {
  let index = plan_index()
  match plan_of(index, "*.pdf size:>1kb") {
    @exec.Filter(predicate, source) => {
      assert_eq(predicate.reason(), "glob")
      match source {
        @exec.Const(_) => ()
        _ => abort("expected the range set as the filter source")
      }
    }
    _ => abort("expected a filter over the size set")
  }
  match plan_of(index, "*.pdf report") {
    @exec.Filter(predicate, source) => {
      assert_eq(predicate.reason(), "glob")
      match source {
        @exec.Trigram(_) => ()
        _ => abort("expected the trigram candidates as the filter source")
      }
    }
    _ => abort("expected a filter over the trigram candidates")
  }
  // Without the optimizer the same query is a plain conjunction.
  match plan_of(index, "*.pdf size:>1kb", optimize=false) {
    @exec.And(_, _) => ()
    _ => abort("expected the unoptimized plan to keep the conjunction")
  }
}

///|
test "explain renders estimates, labels, and degradation reasons" {
  let index = plan_index()
  let total = index.entry_count()
  assert_eq(plan_of(index, "").describe(total), "(const#9 (all))")
  assert_eq(
    plan_of(index, "report").describe(total),
    "(trigram#1 keys=3 (substring \"report\" nocase))",
  )
  assert_eq(
    plan_of(index, "re").describe(total),
    "(scan#9 reason=short-needle (substring \"re\" nocase))",
  )
  assert_eq(
    plan_of(index, "path:docs").describe(total),
    "(scan#9 reason=path (substring \"docs\" nocase path))",
  )
  assert_eq(
    plan_of(index, "childfilecount:2").describe(total),
    "(scan#9 reason=childfilecount (childfilecount = 2))",
  )
  assert_eq(
    plan_of(index, "ext:pdf size:>=1kb").describe(total),
    "(const#1 (and (ext \"pdf\") (size >= 1000)))",
  )
  assert_eq(
    plan_of(index, "*.pdf size:>1kb").describe(total),
    "(filter#4 (glob \"*.pdf\" nocase) (const#4 (size > 1000)))",
  )
  assert_eq(
    plan_of(index, "*.pdf size:>1kb", optimize=false).describe(total),
    "(and#4 (scan#9 reason=glob (glob \"*.pdf\" nocase)) (const#4 (size > 1000)))",
  )
  assert_eq(
    plan_of(index, "!ext:pdf").describe(total),
    "(const#8 (not (ext \"pdf\")))",
  )
  // The tabular form is the same string `explain_indexed` returns.
  assert_eq(
    @exec.explain_indexed(
      index,
      query_of("*.pdf report"),
      options=plan_options(),
    ) catch {
      err => abort("explain failed: \{err.message()}")
    },
    "(filter#1 (glob \"*.pdf\" nocase) (trigram#1 keys=3 (substring \"report\" nocase)))",
  )
}

///|
test "an empty index compiles and evaluates every query shape" {
  let names = @core.NamePool::new()
  let store = @core.Store::new(
    names~,
    folders=[],
    files=[],
    roots=[],
    built_at=0L,
  )
  let index = @index.Index::build(store)
  assert_eq(index.entry_count(), 0)
  for text in ["", "report", "ext:pdf", "!x", "file:", "size:>0", "zzzz"] {
    assert_eq(plan_ids(index, text).cardinality(), 0)
  }
  assert_eq(plan_of(index, "").describe(0), "(const#0 (all))")
}
