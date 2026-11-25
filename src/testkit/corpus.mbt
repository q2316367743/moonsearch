// Query corpora shared by the differential, property, and end-to-end tests.
//
// S13 asks for three layers:
//
// 1. `semantic_queries` — handwritten cases covering the query language and
//    its boundaries (the upstream `test_query.c` checklist, rewritten);
// 2. `generated_queries` — deterministic quickcheck-style queries built from
//    the same leaf vocabulary, so every run explores new boolean shapes;
// 3. `explain_queries` — the supplement derived from `--explain` coverage:
//    one query per plan node kind and per degradation reason.
//
// `date_queries` and `edge_queries` are additional handwritten layers. Date
// queries are kept separate because their outcome depends on the current
// clock: the exec tests pin a clock, while the CLI differential tests only use
// absolute dates so two engine runs cannot straddle a calendar boundary.
//
// Every string returned here must parse. The exec tests turn a parse failure
// into a test failure, which keeps the generator honest.

///|
/// Handwritten semantic corpus: fields, modifiers, booleans, and boundaries.
pub fn semantic_queries() -> Array[String] {
  [
    // Empty query and plain names.
    "", "report", "REPORT", "notes", "photo", "readme.md", "a", "ab", "zzzz", "发票",
    "case:发票", "nocase:发票", "report/", "/root/docs/report.pdf",
    // Name matching modes.
     "case:REPORT", "case:report", "nocase:REPORT", "exact:readme.md", "exact:report",
    "case:exact:README.MD", "exact:发票", "path:docs", "path:/root/docs", "path:report",
    "nopath:/root", "path:regex:\"docs/.*\\.pdf$\"",
    // Globs and regular expressions, including escaped wildcard literals.
     "*.pdf", "*.PDF", "?.txt", "photo*", "*.pdf OR *.txt", "*.hidden", ".hidden",
    "index\\*", "a\\?b", "\\*literal\\*", "regex:\"^report\"", "regex:\"\\.pdf$\"",
    "regex:\"^photo\"", "regex:\"^IMG_[0-9]+\"", "regex:\"\\.(jpg|png)$\"", "regex:\"^REPORT\"",
    "case:regex:\"^REPORT\"",
    // Extensions and categories.
     "ext:pdf", "ext:JPG", "ext:pdf;txt", "ext:PDF;TXT", "ext:", "ext:jpg;", "ext:mp4",
    "folder:ext:pdf", "file:ext:pdf", "doc:", "app:", "archive:", "audio:", "pic:",
    "video:", "file:hidden:doc:",
    // Kind and visibility modifiers, standalone and grouped.
     "file:", "folder:", "hidden:", "nohidden:", "folder:docs", "folder:report",
    "file:report", "hidden:.hidden", "file:(report OR notes)", "folder:(docs OR media)",
    "hidden:(.hidden OR .git)", "!(file:report OR folder:docs)", "!folder:docs",
    // Sizes, counts, and ranges.
     "size:>1500", "size:>=1500", "size:<1500", "size:<=1500", "size:1500", "size:..100",
    "size:==1500", "size: = = 1500", "size:1kb..2kb", "size:>1mb", "size:0", "size:>0",
    "size:>10mb", "file:size:2000", "folder:size:>1000", "depth:0", "depth:1", "depth:<=2",
    "depth:>2", "depth:0..1", "folder:depth:1", "childcount:0", "childcount:>0",
    "childcount:0..2", "childfilecount:2", "childfoldercount:3", "empty:",
    // Paths and content types.
     "parent:/root/docs", "parent:/root/", "parent:/", "parent:/nope", "parent:/root/media",
    "contenttype:pdf", "contenttype:image", "contenttype:text", "contenttype:application",
    "contenttype:nonsense",
    // Absolute dates.
     "dm:2024", "dm:2024-03", "dm:2024-02", "dm:>=2024-03-01", "dm:<2024-02-01",
    "dm:2024-01..2024-03", "dm:2024-03-20",
    // Boolean algebra, precedence, aliases, and negation.
     "pdf OR txt", "pdf AND txt", "pdf && txt", "pdf || txt", "ext:pdf ext:txt",
    "!pdf", "!!pdf", "!(pdf)", "!pdf !txt", "(pdf OR txt) !draft", "(report OR notes) (pdf OR txt)",
    "pdf size:>1500", "report pdf", "*.pdf size:>1kb", "*.pdf report", "file:*.pdf folder:",
    "!size:>1000", "!(hidden: OR .hidden)",
  ]
}

///|
/// Handwritten date corpus whose result depends on "now".
///
/// Exec tests pin the clock, so these queries are deterministic there. The CLI
/// differential runner leaves them out: two engine runs seconds apart must not
/// be able to disagree because the day rolled over between them.
pub fn date_queries() -> Array[String] {
  [
    "dm:today", "dm:yesterday", "dm:lastweek", "dm:lastmonth", "dm:thisyear", "dm:>=today",
    "dm:<today", "dm:lastweek..yesterday", "dm:..yesterday", "dm:last3days", "dm:pastweek",
    "dm:past3days", "dm:pastfiveweeks",
  ]
}

///|
/// Handwritten escaping and lexer-boundary cases.
///
/// All of them parse. Queries that must fail live in the query package's own
/// error tests, not in the differential corpus.
pub fn edge_queries() -> Array[String] {
  [
    "\"report\"", "\"report final\"", "\"read me\"", "\"\"", "a\\ b", "a\\!b", "a\\(b",
    "a\\)b", "\\\"quoted\\\"", "\\\\", "\\AND", "AND", "OR", "NOT", "and", "or",
    "not", "report\tand\tpdf", "report   pdf", "report\npdf", "report\r\npdf", "a\\:b",
    "size: = 1500", "size: == 1500", "size:>=1kb", "size:<1kb", "depth: = 2", "dm: = 2024-03",
    "report,notes", "report;notes", "report+notes", "[report]", "report|notes", "index\\*",
    "a\\?b", "\\\\*", "a\\\\?b",
  ]
}

///|
/// Explain-coverage supplement: one case per plan node and degradation reason.
///
/// `testkit.scan_reasons()` lists the reasons the differential tests require
/// to be observed. `no-index` is excluded: a well-formed `TrigramIndex`
/// returns that reason only if every posting was skipped without being counted
/// as a stop-gram, which the invariants forbid, so the branch is defensive.
pub fn explain_queries() -> Array[String] {
  [
    "", "report", "re", "report pdf", "pdf OR txt", "!pdf", "!(pdf OR txt)", "*.pdf",
    "regex:\"^report\"", "path:docs", "childfilecount:2", "childfoldercount:3", "contenttype:pdf",
    "ext:pdf size:>1kb report", "test",
  ]
}

///|
/// Degradation reasons the explain coverage test must observe.
pub fn scan_reasons() -> Array[String] {
  [
    "glob", "regex", "path", "short-needle", "no-trigram", "stop-grams", "childfilecount",
    "childfoldercount", "contenttype",
  ]
}

///|
/// Leaf vocabulary for the generated layer.
///
/// Entries are complete terms: flags are already attached, so the generator
/// only has to combine them. Field values are always well formed, which keeps
/// generation from depending on parser error recovery.
fn generated_leaves() -> Array[String] {
  [
    // Bare names, including short needles, case variants, unicode, and paths.
    "report", "REPORT", "notes", "photo", "docs", "media", "root", "readme.md", "a",
    "ab", "pdf", "txt", "JPG", "发票", "zzzz", "x1", "file2", "file10", "/root/docs",
    "report/",
    // Globs and regexes.
     "*.pdf", "*.txt", "photo*", "?.txt", "*.JPG", "regex:\"^report\"", "regex:\"\\.pdf$\"",
    "regex:\"^photo\"", "regex:\"^IMG_[0-9]+\"", "regex:\"\\.(jpg|png)$\"",
    // Field leaves.
     "ext:pdf", "ext:txt;md", "ext:JPG", "ext:", "ext:PDF;TXT", "size:>1500", "size:<=2kb",
    "size:1kb..2kb", "size:1000", "size:..100", "dm:2024-03", "dm:>=2024-01-15",
    "dm:2024-01..2024-03", "depth:0", "depth:<=2", "depth:>2", "childcount:0", "childcount:>0",
    "empty:", "parent:/root/docs", "contenttype:pdf", "contenttype:image", "doc:",
    "pic:", "video:", "archive:", "audio:", "app:",
    // Modifier-bearing terms and standalone modifiers.
     "file:", "folder:", "hidden:", "nohidden:", "case:report", "exact:readme.md",
    "path:docs", "nopath:root", "file:report", "folder:docs", "hidden:.hidden", "nohidden:report",
    "case:*.pdf", "exact:report", "file:*.pdf", "folder:(docs OR media)", "file:hidden:doc:",
    "file:size:>1000", "folder:depth:1", "!pdf",
  ]
}

///|
/// Build one generated expression.
///
/// Leaves are drawn from a fixed vocabulary, and the combinators are exactly
/// the query language's boolean forms. The depth bound keeps recursion and the
/// resulting query short; the parser has its own hard limit far above this.
fn generated_expr(rng : Rng, leaves : Array[String], depth : Int32) -> String {
  if depth <= 0 || rng.chance(45) {
    return rng.pick(leaves)
  }
  let left = generated_expr(rng, leaves, depth - 1)
  match rng.below(7) {
    0 => "!(\{left})"
    1 => "\{left} \{generated_expr(rng, leaves, depth - 1)}"
    2 => "\{left} AND \{generated_expr(rng, leaves, depth - 1)}"
    3 => "\{left} OR \{generated_expr(rng, leaves, depth - 1)}"
    4 => "\{left} && \{generated_expr(rng, leaves, depth - 1)}"
    5 => "\{left} || \{generated_expr(rng, leaves, depth - 1)}"
    _ => "(\{left})"
  }
}

///|
/// Generate `count` deterministic random queries.
///
/// The same seed always yields the same corpus. This is what makes a
/// differential mismatch reproducible: the failure message carries the seed
/// and the query text.
pub fn generated_queries(seed : UInt64, count : Int32) -> Array[String] {
  let rng = Rng::new(seed)
  let leaves = generated_leaves()
  let queries : Array[String] = []
  for _ in 0..<count {
    queries.push(generated_expr(rng, leaves, 3))
  }
  queries
}

///|
/// Concatenate the handwritten layers and the generated layer.
///
/// This is the corpus the exec differential runner uses. Callers that pin a
/// clock can append `date_queries` themselves.
pub fn differential_queries(seed : UInt64, generated : Int32) -> Array[String] {
  let queries = semantic_queries()
  for text in edge_queries() {
    queries.push(text)
  }
  for text in explain_queries() {
    queries.push(text)
  }
  for text in generated_queries(seed, generated) {
    queries.push(text)
  }
  queries
}
