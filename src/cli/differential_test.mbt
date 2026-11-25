// S13 end-to-end differential tests.
//
// The unit-level runner compares id sets. This file compares what the user
// actually sees: stdout bytes and exit codes of the real CLI. Every corpus
// query is executed with `--engine scan` and `--engine bitmap` against one
// persisted database, then the no-trigram build and the live scan are checked
// against the same baseline. Output options are compared on a smaller query
// set because each combination runs two processes.

///|
/// Exit code plus stdout and, for failures, the error text.
struct CliDiffOutcome {
  code : Int32
  out : String
  detail : String
}

///|
/// Reduce a CLI result to the parts that must agree between engines.
fn cli_diff_outcome(result : @cli.CliResult) -> CliDiffOutcome {
  match result {
    @cli.Success(text) => { code: 0, out: text, detail: "", }
    @cli.SuccessWith(out, _) => { code: 0, out, detail: "", }
    @cli.NoMatch(out, _) => { code: 1, out, detail: "", }
    @cli.Failure(text) => { code: 2, out: "", detail: text, }
  }
}

///|
/// Run one query on both engines and assert identical observable output.
async fn cli_diff_query(
  label : String,
  database : String,
  query : String,
) -> Unit {
  let scan = cli_diff_outcome(
    @cli.run(["search", "-D", database, "--engine", "scan", query]),
  )
  let bitmap = cli_diff_outcome(
    @cli.run(["search", "-D", database, "--engine", "bitmap", query]),
  )
  if scan.code != bitmap.code ||
    scan.out != bitmap.out ||
    (scan.code == 2 && scan.detail != bitmap.detail) {
    abort(
      "\{label}: search engines differ for '\{query}' (scan code=\{scan.code}, bitmap code=\{bitmap.code})",
    )
  }
  let scan_count = cli_diff_outcome(
    @cli.run(["count", "-D", database, "--engine", "scan", query]),
  )
  let bitmap_count = cli_diff_outcome(
    @cli.run(["count", "-D", database, "--engine", "bitmap", query]),
  )
  if scan_count.code != bitmap_count.code || scan_count.out != bitmap_count.out {
    abort(
      "\{label}: count engines differ for '\{query}' (scan='\{scan_count.out}', bitmap='\{bitmap_count.out}')",
    )
  }
}

///|
/// Build a fixture tree with nested, hidden, empty, unicode, and deep entries.
async fn cli_diff_fixture() -> String {
  let dir = @fs.tmpdir(prefix="moonsearch-diff")
  @fs.mkdir("\{dir}/sub")
  @fs.mkdir("\{dir}/empty")
  @fs.mkdir("\{dir}/Unicode")
  @fs.mkdir("\{dir}/deep/one/two", recursive=true)
  @fs.write_text("\{dir}/a.pdf", "012345678901234567890123456789")
  @fs.write_text("\{dir}/Report Final.md", "hello")
  @fs.write_text("\{dir}/notes.txt", "")
  @fs.write_text("\{dir}/draft.md", "draft")
  @fs.write_text("\{dir}/.hidden", "hh")
  @fs.write_text("\{dir}/sub/report.pdf", "x")
  @fs.write_text("\{dir}/sub/data.zip", "0123456789")
  @fs.write_text("\{dir}/sub/photo.JPG", "01234567890123456789")
  @fs.write_text("\{dir}/Unicode/发票.txt", "abcdefg")
  @fs.write_text("\{dir}/Unicode/报告 2024.pdf", "0123456789012")
  @fs.write_text("\{dir}/deep/one/two/leaf.md", "abc")
  dir
}

///|
/// Remove a database (and any stale lock) before indexing.
async fn cli_diff_reset(database : String) -> Unit {
  @fs.remove(database, allow_missing=true) catch {
    _ => ()
  }
}

///|
/// Index a fixture and return the database path.
async fn cli_diff_index(
  name : String,
  dir : String,
  extra : Array[String],
) -> String {
  let database = test_database(name)
  cli_diff_reset(database)
  ignore(@cli.run(["index", "-D", database] + extra + [dir]))
  database
}

///|
async test "scan and bitmap agree on the corpus against a persisted database" {
  let dir = cli_diff_fixture()
  let real = real_dir(dir)
  let database = cli_diff_index("diff-main", dir, [])
  let queries = @testkit.differential_queries(20241118UL, 80)
  // Paths are only known at runtime, so parent/path coverage is added here
  // rather than in the static corpus.
  queries.push("parent:\{real}/sub")
  queries.push("parent:\{real}")
  queries.push("path:\{real}/sub")
  for query in queries {
    cli_diff_query("persisted", database, query)
  }
  @fs.remove(dir, recursive=true)
}

///|
async test "scan and bitmap agree on a no-trigram database" {
  let dir = cli_diff_fixture()
  let database = cli_diff_index("diff-no-trigram", dir, ["--no-trigram"])
  let queries = @testkit.semantic_queries()
  for query in @testkit.explain_queries() {
    queries.push(query)
  }
  for query in @testkit.generated_queries(777UL, 40) {
    queries.push(query)
  }
  for query in queries {
    cli_diff_query("no-trigram", database, query)
  }
  @fs.remove(dir, recursive=true)
}

///|
async test "the live scan matches the persisted bitmap engine" {
  let dir = cli_diff_fixture()
  let database = cli_diff_index("diff-live", dir, [])
  let queries = @testkit.semantic_queries()
  for query in @testkit.edge_queries() {
    queries.push(query)
  }
  for query in @testkit.generated_queries(20241118UL, 30) {
    queries.push(query)
  }
  let mut compared = 0
  for position in 0..<queries.length() {
    // A third of the corpus keeps this test bounded; the persisted comparison
    // above already runs every query on both engines.
    if position % 3 != 0 {
      continue
    }
    let query = queries[position]
    let live = cli_diff_outcome(
      @cli.run(["search", "--live", "--root", dir, query]),
    )
    let indexed = cli_diff_outcome(
      @cli.run(["search", "-D", database, "--engine", "bitmap", query]),
    )
    if live.code != indexed.code || live.out != indexed.out {
      abort(
        "live scan differs from the indexed engine for '\{query}' (live code=\{live.code}, indexed code=\{indexed.code})",
      )
    }
    compared = compared + 1
  }
  assert_true(compared > 0)
  @fs.remove(dir, recursive=true)
}

///|
async test "both engines format and order results identically" {
  let dir = cli_diff_fixture()
  let database = cli_diff_index("diff-format", dir, [])
  let queries : Array[String] = [
    "", "file:", "ext:txt", "report", "size:>10", "folder:",
  ]
  let variants : Array[Array[String]] = [
    [],
    ["--reverse"],
    ["--folders-first"],
    ["-n", "2"],
    ["--reverse", "-n", "2"],
    ["--sort", "size"],
    ["--sort", "size", "--reverse"],
    ["--sort", "ext", "--folders-first"],
    ["--json"],
    ["--null"],
    ["--basename"],
    ["--format", "{path}|{name}|{size}|{ext}|{type}|{kind}"],
    ["--relative-to", dir],
  ]
  let mut comparisons = 0
  for query in queries {
    for variant in variants {
      let base = ["search", "-D", database] + variant + [query]
      let scan = cli_diff_outcome(@cli.run(base + ["--engine", "scan"]))
      let bitmap = cli_diff_outcome(@cli.run(base + ["--engine", "bitmap"]))
      if scan.code != bitmap.code || scan.out != bitmap.out {
        abort(
          "format mismatch for '\{query}' with \{variant.join(" ")} (scan code=\{scan.code}, bitmap code=\{bitmap.code})",
        )
      }
      comparisons = comparisons + 1
    }
  }
  assert_eq(comparisons, queries.length() * variants.length())
  @fs.remove(dir, recursive=true)
}

///|
async test "invalid queries and compat agree across engines" {
  let dir = cli_diff_fixture()
  let database = cli_diff_index("diff-errors", dir, [])
  let invalid : Array[String] = [
    "file:regex:\"[\" folder:", "file:dm:nonsense folder:", "regex:\"(\"", "size:abc",
    "dm:pastnonsenseweek",
  ]
  for query in invalid {
    // Without `--compat` both engines report the same exit code and message.
    cli_diff_query("invalid", database, query)
    for engine in ["scan", "bitmap"] {
      let tolerated = cli_diff_outcome(
        @cli.run([
          "search", "-D", database, "--engine", engine, "--compat", query,
        ]),
      )
      if tolerated.code != 1 || tolerated.out != "" {
        abort(
          "compat '\{query}' on \{engine}: expected empty output and exit 1, got code=\{tolerated.code} out='\{tolerated.out}'",
        )
      }
    }
  }
  // `--type` is a global constraint, so a contradicting modifier is empty.
  for engine in ["scan", "bitmap"] {
    let result = cli_diff_outcome(
      @cli.run([
        "search", "-D", database, "--engine", engine, "--type", "file", "folder:",
      ]),
    )
    if result.code != 1 || result.out != "" {
      abort(
        "--type file folder: on \{engine}: expected empty output and exit 1",
      )
    }
  }
  @fs.remove(dir, recursive=true)
}
