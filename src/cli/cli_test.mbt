///|
/// Extract the text a successful invariant writes to stdout.
fn stdout_of(result : @cli.CliResult) -> String {
  match result {
    @cli.Success(text) => text
    @cli.SuccessWith(out, _) => out
    @cli.NoMatch(_, _) => abort("expected success, got NoMatch")
    @cli.Failure(text) => abort("expected success, got: \{text}")
  }
}

///|
/// Parse a command line that must produce a runnable invocation.
fn run_ok(argv : Array[String]) -> @cli.Invocation {
  match @cli.parse(argv) {
    Ok(@cli.Run(invocation)) => invocation
    Ok(@cli.ShowHelp(_)) => abort("expected an invocation, got help")
    Ok(@cli.ShowVersion(_)) => abort("expected an invocation, got version")
    Err(message) => abort(message)
  }
}

///|
/// Look up the first value of an option.
fn first_value(invocation : @cli.Invocation, name : String) -> String? {
  match invocation.matches.values.get(name) {
    Some(values) => values.get(0)
    None => None
  }
}

///|
async test "top-level help is stable" {
  inspect(
    stdout_of(@cli.run([])),
    content=(
      #|Usage: moonsearch [options] [command]
      #|
      #|Fast file search over a persistent inverted index
      #|
      #|Commands:
      #|  index   Scan the configured roots and write the index
      #|  update  Rescan the configured roots and rebuild the index
      #|  search  Search the index (default)
      #|  count   Print the number of matches
      #|  info    Show index statistics
      #|  help    Print help for the subcommand(s).
      #|
      #|Options:
      #|  -h, --help                 Show help information.
      #|  -V, --version              Show version information.
      #|  --no-config                Do not read the configuration file
      #|  -v, --verbose              Print detailed progress information
      #|  -q, --quiet                Only print results and errors
      #|  --stats                    Print timings and index sizes to stderr
      #|  --explain                  Print the execution plan to stderr
      #|  -D, --database <database>  Path to the index database [env: MOONSEARCH_DATABASE]
      #|  --config <config>          Path to the configuration file [env: MOONSEARCH_CONFIG]
    ),
  )
}

///|
async test "index help is stable" {
  inspect(
    stdout_of(@cli.run(["index", "--help"])),
    content=(
      #|Usage: moonsearch index [options] [roots...]
      #|
      #|Scan the configured roots and write the index
      #|
      #|Arguments:
      #|  roots...  Root directories to index; may be repeated
      #|
      #|Options:
      #|  -h, --help                         Show help information.
      #|  -V, --version                      Show version information.
      #|  --no-config                        Do not read the configuration file
      #|  -v, --verbose                      Print detailed progress information
      #|  -q, --quiet                        Only print results and errors
      #|  --stats                            Print timings and index sizes to stderr
      #|  --explain                          Print the execution plan to stderr
      #|  -D, --database <database>          Path to the index database [env: MOONSEARCH_DATABASE]
      #|  --config <config>                  Path to the configuration file [env: MOONSEARCH_CONFIG]
      #|  --exclude-hidden                   Skip names that start with a dot
      #|  --one-file-system                  Do not cross file system boundaries
      #|  --no-default-excludes              Do not skip /proc, /sys, /dev, and /run
      #|  --allow-nested-roots               Allow roots that are nested inside each other
      #|  --no-trigram                       Do not build the trigram index
      #|  -r, --root <root>                  Root directory to index; may be repeated
      #|  -x, --exclude <exclude>            Exclude pattern; may be repeated
      #|  --exclude-scope <exclude-scope>    Pattern scope: full_path or basename [default: full_path]
      #|  --exclude-target <exclude-target>  Pattern target: both, files, or folders [default: both]
      #|  --fast-fields <fast-fields>        Range fields loaded eagerly: size,mtime [default: size,mtime]
    ),
  )
}

///|
async test "update help is stable" {
  inspect(
    stdout_of(@cli.run(["update", "--help"])),
    content=(
      #|Usage: moonsearch update [options] [roots...]
      #|
      #|Rescan the configured roots and rebuild the index
      #|
      #|Arguments:
      #|  roots...  Root directories to index; may be repeated
      #|
      #|Options:
      #|  -h, --help                         Show help information.
      #|  -V, --version                      Show version information.
      #|  --no-config                        Do not read the configuration file
      #|  -v, --verbose                      Print detailed progress information
      #|  -q, --quiet                        Only print results and errors
      #|  --stats                            Print timings and index sizes to stderr
      #|  --explain                          Print the execution plan to stderr
      #|  -D, --database <database>          Path to the index database [env: MOONSEARCH_DATABASE]
      #|  --config <config>                  Path to the configuration file [env: MOONSEARCH_CONFIG]
      #|  --exclude-hidden                   Skip names that start with a dot
      #|  --one-file-system                  Do not cross file system boundaries
      #|  --no-default-excludes              Do not skip /proc, /sys, /dev, and /run
      #|  --allow-nested-roots               Allow roots that are nested inside each other
      #|  --no-trigram                       Do not build the trigram index
      #|  -r, --root <root>                  Root directory to index; may be repeated
      #|  -x, --exclude <exclude>            Exclude pattern; may be repeated
      #|  --exclude-scope <exclude-scope>    Pattern scope: full_path or basename [default: full_path]
      #|  --exclude-target <exclude-target>  Pattern target: both, files, or folders [default: both]
      #|  --fast-fields <fast-fields>        Range fields loaded eagerly: size,mtime [default: size,mtime]
    ),
  )
}

///|
async test "search help is stable" {
  inspect(
    stdout_of(@cli.run(["search", "--help"])),
    content=(
      #|Usage: moonsearch search [options] [query...]
      #|
      #|Search the index
      #|
      #|Arguments:
      #|  query...  Search query; bare terms are joined with single spaces
      #|
      #|Options:
      #|  -h, --help                   Show help information.
      #|  -V, --version                Show version information.
      #|  --no-config                  Do not read the configuration file
      #|  -v, --verbose                Print detailed progress information
      #|  -q, --quiet                  Only print results and errors
      #|  --stats                      Print timings and index sizes to stderr
      #|  --explain                    Print the execution plan to stderr
      #|  -D, --database <database>    Path to the index database [env: MOONSEARCH_DATABASE]
      #|  --config <config>            Path to the configuration file [env: MOONSEARCH_CONFIG]
      #|  -c, --case-sensitive         Match the query case-sensitively
      #|  -e, --exact                  Match whole names instead of substrings
      #|  -p, --search-path            Match against full paths instead of names
      #|  -r, --regex                  Treat the whole query as a regular expression
      #|  --live                       Scan the configured roots instead of reading the index
      #|  --auto-index                 Build the index first when the database is missing
      #|  --compat                     Reproduce upstream query error recovery
      #|  --reverse                    Reverse the result order
      #|  --folders-first              Print folders before files
      #|  -0, --null                   Terminate every result with NUL instead of a newline
      #|  --json                       Print one JSON object per result
      #|  --basename                   Print only the entry name
      #|  --type <type>                Restrict the result kind: any, file, or folder [default: any]
      #|  --engine <engine>            Execution engine: scan or bitmap [default: scan]
      #|  --root <root>                Root directory for a live scan; may be repeated
      #|  --sort <sort>                Result order: name, path, size, mtime, ext, or type [default: name]
      #|  -n, --limit <limit>          Maximum number of results; 0 means unlimited [default: 0]
      #|  --format <format>            Custom output template for each match
      #|  --relative-to <relative-to>  Print paths relative to this directory
    ),
  )
}

///|
async test "count help is stable" {
  inspect(
    stdout_of(@cli.run(["count", "--help"])),
    content=(
      #|Usage: moonsearch count [options] [query...]
      #|
      #|Print the number of matches
      #|
      #|Arguments:
      #|  query...  Search query; bare terms are joined with single spaces
      #|
      #|Options:
      #|  -h, --help                 Show help information.
      #|  -V, --version              Show version information.
      #|  --no-config                Do not read the configuration file
      #|  -v, --verbose              Print detailed progress information
      #|  -q, --quiet                Only print results and errors
      #|  --stats                    Print timings and index sizes to stderr
      #|  --explain                  Print the execution plan to stderr
      #|  -D, --database <database>  Path to the index database [env: MOONSEARCH_DATABASE]
      #|  --config <config>          Path to the configuration file [env: MOONSEARCH_CONFIG]
      #|  -c, --case-sensitive       Match the query case-sensitively
      #|  -e, --exact                Match whole names instead of substrings
      #|  -p, --search-path          Match against full paths instead of names
      #|  -r, --regex                Treat the whole query as a regular expression
      #|  --live                     Scan the configured roots instead of reading the index
      #|  --auto-index               Build the index first when the database is missing
      #|  --compat                   Reproduce upstream query error recovery
      #|  --type <type>              Restrict the result kind: any, file, or folder [default: any]
      #|  --engine <engine>          Execution engine: scan or bitmap [default: scan]
      #|  --root <root>              Root directory for a live scan; may be repeated
    ),
  )
}

///|
async test "info help is stable" {
  inspect(
    stdout_of(@cli.run(["info", "--help"])),
    content=(
      #|Usage: moonsearch info [options]
      #|
      #|Show index statistics
      #|
      #|Options:
      #|  -h, --help                 Show help information.
      #|  -V, --version              Show version information.
      #|  --no-config                Do not read the configuration file
      #|  -v, --verbose              Print detailed progress information
      #|  -q, --quiet                Only print results and errors
      #|  --stats                    Print timings and index sizes to stderr
      #|  --explain                  Print the execution plan to stderr
      #|  -D, --database <database>  Path to the index database [env: MOONSEARCH_DATABASE]
      #|  --config <config>          Path to the configuration file [env: MOONSEARCH_CONFIG]
      #|  --verify                   Verify every section checksum before reporting
    ),
  )
}

///|
async test "version" {
  inspect(stdout_of(@cli.run(["--version"])), content="moonsearch 0.1.0")
}

///|
async test "no arguments prints help and succeeds" {
  let empty = @cli.run([])
  assert_eq(empty.exit_code(), 0)
  assert_eq(stdout_of(empty), stdout_of(@cli.run(["--help"])))
}

///|
async test "bare query dispatches to search" {
  let invocation = run_ok(["ext:pdf"])
  assert_eq(invocation.command.name(), "search")
  assert_eq(invocation.query, "ext:pdf")
}

///|
async test "positional query terms are joined with single spaces" {
  let invocation = run_ok(["report", "pdf"])
  assert_eq(invocation.query, "report pdf")
}

///|
async test "double dash allows a leading-hyphen query" {
  let invocation = run_ok(["--", "-foo"])
  assert_eq(invocation.query, "-foo")
}

///|
async test "explicit subcommands are recognised" {
  assert_eq(run_ok(["index", "-r", "/tmp"]).command.name(), "index")
  assert_eq(run_ok(["update"]).command.name(), "update")
  assert_eq(run_ok(["search"]).command.name(), "search")
  assert_eq(run_ok(["count"]).command.name(), "count")
  assert_eq(run_ok(["info"]).command.name(), "info")
}

///|
async test "repeated index roots are kept in order" {
  let invocation = run_ok(["index", "-r", "/tmp", "--root", "/var"])
  let roots = invocation.matches.values.get("root").unwrap()
  assert_eq(roots.join(","), "/tmp,/var")
}

///|
async test "global option works after the subcommand" {
  let invocation = run_ok(["search", "-D", "/tmp/db.msdb"])
  assert_eq(first_value(invocation, "database"), Some("/tmp/db.msdb"))
}

///|
async test "database path can come from the environment" {
  let parsed = @cli.parse(
    ["search"],
    env=Map([("MOONSEARCH_DATABASE", "/tmp/env.msdb")]),
  )
  match parsed {
    Ok(@cli.Run(invocation)) =>
      assert_eq(first_value(invocation, "database"), Some("/tmp/env.msdb"))
    Ok(_) => abort("expected an invocation")
    Err(message) => abort(message)
  }
}

///|
async test "unknown options are usage errors" {
  match @cli.parse(["search", "--bogus"]) {
    Err(message) => {
      assert_true(message.contains("unexpected argument '--bogus'"))
      assert_eq(@cli.Failure(message).exit_code(), 2)
    }
    Ok(_) => abort("expected a parse error")
  }
}

///|
async test "missing option values are usage errors" {
  match @cli.parse(["search", "--database"]) {
    Err(message) => assert_true(message.contains("a value is required"))
    Ok(_) => abort("expected a parse error")
  }
}

///|
async test "count rejects search-only ordering options" {
  match @cli.parse(["count", "--sort", "size"]) {
    Err(_) => ()
    Ok(_) => abort("count must not accept --sort")
  }
}

///|
async test "exit code mapping" {
  assert_eq(@cli.Success("").exit_code(), 0)
  assert_eq(@cli.NoMatch("", "").exit_code(), 1)
  assert_eq(@cli.Failure("error").exit_code(), 2)
}

///|
async test "search without a database explains how to create one" {
  let database = test_database("missing")
  @fs.remove(database, allow_missing=true) catch {
    _ => ()
  }
  let result = @cli.run(["search", "-D", database, "report"])
  assert_eq(result.exit_code(), 2)
  match result {
    @cli.Failure(text) => {
      assert_true(text.contains("no index database"))
      assert_true(text.contains("moonsearch index"))
    }
    _ => abort("expected a failure")
  }
}

///|
/// Database path used by an end-to-end test.
///
/// Index commands write a real database; tests keep it under the build
/// directory so it never pollutes the source tree and parallel tests use
/// distinct files.
fn test_database(name : String) -> String {
  "_build/test-db/\{name}.msdb"
}

///|
/// Create a small fixture tree for end-to-end index tests.
async fn make_fixture(prefix : String) -> String {
  let dir = @fs.tmpdir(prefix~)
  @fs.mkdir("\{dir}/sub")
  @fs.write_text("\{dir}/a.txt", "hello")
  @fs.write_text("\{dir}/sub/b.pdf", "x")
  @fs.symlink(target="\{dir}/sub", "\{dir}/link")
  dir
}

///|
async test "index scans a real directory tree" {
  let dir = make_fixture("moonsearch-index")
  let result = @cli.run(["index", "-D", test_database("scan"), dir])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.Success(text) =>
      // Root + sub are folders; a.txt, b.pdf, and the symlink are files.
      // The symlink is not followed, so it contributes no bytes.
      assert_eq(text, "roots: 1\nfolders: 2\nfiles: 3\nbytes: 6")
    @cli.SuccessWith(out, diagnostics) =>
      abort("unexpected diagnostics: \{out}\n\{diagnostics}")
    _ => abort("expected the index command to succeed")
  }
}

///|
async test "a written database drives search, count, and info without the roots" {
  let dir = make_fixture("moonsearch-persist")
  let real = real_dir(dir)
  let database = test_database("persist")
  @fs.remove(database, allow_missing=true) catch {
    _ => ()
  }
  let indexed = @cli.run(["index", "-D", database, dir])
  assert_eq(index_stdout(indexed), "roots: 1\nfolders: 2\nfiles: 3\nbytes: 6")
  let info = @cli.run(["info", "-D", database, "--verify"])
  @fs.remove(dir, recursive=true)
  match info {
    @cli.Success(text) => {
      assert_true(text.contains("format: MSDB 2.0"))
      assert_true(text.contains("folders: 2"))
      assert_true(text.contains("files: 3"))
      assert_true(text.contains("checksum: verified"))
      assert_true(text.contains("postings="))
    }
    _ => abort("expected database info")
  }
  let search = @cli.run(["search", "-D", database, "a.txt"])
  let bitmap = @cli.run([
    "search", "-D", database, "--engine", "bitmap", "ext:pdf",
  ])
  let count = @cli.run(["count", "-D", database, "ext:pdf"])
  match search {
    @cli.Success(text) => assert_eq(text, "\{real}/a.txt")
    _ => abort("expected a match from the persisted index")
  }
  match bitmap {
    @cli.Success(text) => assert_eq(text, "\{real}/sub/b.pdf")
    _ => abort("expected the bitmap engine to read the persisted index")
  }
  match count {
    @cli.Success(text) => assert_eq(text, "1")
    _ => abort("expected a count from the persisted index")
  }
}

///|
async test "a persisted index keeps unbuilt range fields lazy" {
  let dir = make_fixture("moonsearch-lazy-fields")
  let real = real_dir(dir)
  let database = test_database("lazy-fields")
  ignore(@cli.run(["index", "-D", database, "--fast-fields", "size", dir]))
  let depth = @cli.run([
    "search", "-D", database, "--engine", "bitmap", "--type", "folder", "depth:0",
  ])
  @fs.remove(dir, recursive=true)
  match depth {
    @cli.Success(text) => assert_eq(text, real)
    _ => abort("expected the root to match depth:0 from the persisted store")
  }
}

///|
async test "index uses the XDG data directory by default" {
  let home = @fs.tmpdir(prefix="moonsearch-home")
  let data = "\{home}/data"
  let dir = make_fixture("moonsearch-xdg")
  let real = real_dir(dir)
  let indexed = @cli.run(
    ["index", dir],
    env=Map([("XDG_DATA_HOME", data), ("HOME", home)]),
  )
  let database = "\{data}/moonsearch/index.msdb"
  let exists = @fs.exists(database)
  let search = @cli.run(["search", "-D", database, "a.txt"])
  @fs.remove(dir, recursive=true)
  @fs.remove(home, recursive=true)
  assert_eq(index_stdout(indexed), "roots: 1\nfolders: 2\nfiles: 3\nbytes: 6")
  assert_true(exists)
  match search {
    @cli.Success(text) => assert_eq(text, "\{real}/a.txt")
    _ => abort("expected a match from the default database")
  }
}

///|
async test "a held writer lock rejects a second index run" {
  @fs.mkdir("_build/test-db", recursive=true, allow_existing=true)
  let dir = make_fixture("moonsearch-lock")
  let database = test_database("lock")
  let lock_path = "\{database}.lock"
  let lock = @fs.open(lock_path, mode=WriteOnly, create_mode=OpenOrCreate)
  assert_true(lock.try_lock(Exclusive))
  let result = @cli.run(["index", "-D", database, dir])
  lock.close()
  @fs.remove(dir, recursive=true)
  assert_eq(result.exit_code(), 2)
  match result {
    @cli.Failure(text) => assert_true(text.contains("another process"))
    _ => abort("expected the held lock to reject the writer")
  }
}

///|
async test "a corrupt database is rejected without crashing" {
  @fs.mkdir("_build/test-db", recursive=true, allow_existing=true)
  let database = test_database("corrupt")
  @fs.write_binary(database, b"MSDB but not really"[:])
  let search = @cli.run(["search", "-D", database, "a.txt"])
  let info = @cli.run(["info", "-D", database, "--verify"])
  assert_eq(search.exit_code(), 2)
  assert_eq(info.exit_code(), 2)
  match search {
    @cli.Failure(text) => assert_true(text.contains("database"))
    _ => abort("expected a database failure")
  }
  match info {
    @cli.Failure(text) => assert_true(text.contains("database"))
    _ => abort("expected a database failure")
  }
}

///|
async test "a database without trigram degrades name queries to a scan" {
  let dir = make_fixture("moonsearch-no-trigram-db")
  let real = real_dir(dir)
  let database = test_database("no-trigram-db")
  ignore(@cli.run(["index", "-D", database, "--no-trigram", dir]))
  let info = @cli.run(["info", "-D", database])
  let search = @cli.run([
    "search", "-D", database, "--engine", "bitmap", "a.txt",
  ])
  @fs.remove(dir, recursive=true)
  match info {
    @cli.Success(text) => assert_true(text.contains("trigram: disabled"))
    _ => abort("expected database info")
  }
  match search {
    @cli.Success(text) => assert_eq(text, "\{real}/a.txt")
    _ => abort("expected a name match without the trigram index")
  }
}

///|
async test "index excludes hidden entries and glob rules end to end" {
  let dir = @fs.tmpdir(prefix="moonsearch-hidden")
  @fs.write_text("\{dir}/keep.txt", "abc")
  @fs.write_text("\{dir}/drop.tmp", "x")
  @fs.write_text("\{dir}/.secret", "x")
  let result = @cli.run([
    "index",
    "-D",
    test_database("hidden"),
    "--exclude-hidden",
    "-x",
    "*.tmp",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.Success(text) =>
      assert_eq(text, "roots: 1\nfolders: 1\nfiles: 1\nbytes: 3\nskipped: 2")
    _ => abort("expected the index command to succeed")
  }
}

///|
async test "index reports a missing root" {
  let result = @cli.run(["index", "/moonsearch/definitely/not/here"])
  match result {
    @cli.Failure(text) => {
      assert_true(text.contains("root does not exist"))
      assert_eq(result.exit_code(), 2)
    }
    _ => abort("expected an index failure")
  }
}

///|
/// Build a fixture tree with nested, hidden, empty, and symlinked entries.
async fn make_tree_fixture() -> String {
  let dir = @fs.tmpdir(prefix="moonsearch-tree")
  @fs.mkdir("\{dir}/sub")
  @fs.mkdir("\{dir}/empty")
  @fs.mkdir("\{dir}/.git")
  @fs.write_text("\{dir}/a.txt", "hello")
  @fs.write_text("\{dir}/.hidden", "hh")
  @fs.write_text("\{dir}/sub/b.pdf", "abc")
  @fs.write_text("\{dir}/.git/config", "x")
  @fs.symlink(target="\{dir}/sub", "\{dir}/link")
  dir
}

///|
/// Accept a successful index run and return its stdout.
fn index_stdout(result : @cli.CliResult) -> String {
  match result {
    @cli.Success(text) => text
    @cli.SuccessWith(_, diagnostics) =>
      abort("unexpected diagnostics: \{diagnostics}")
    @cli.NoMatch(_, _) => abort("index must not return NoMatch")
    @cli.Failure(text) => abort("index failed: \{text}")
  }
}

///|
async test "index summarises a realistic tree" {
  let dir = make_tree_fixture()
  let result = @cli.run(["index", "-D", test_database("tree"), dir])
  @fs.remove(dir, recursive=true)
  // root, sub, empty, .git; the symlink is a zero-sized file.
  assert_eq(index_stdout(result), "roots: 1\nfolders: 4\nfiles: 5\nbytes: 11")
}

///|
async test "index excludes hidden entries and their subtrees" {
  let dir = make_tree_fixture()
  let result = @cli.run([
    "index",
    "-D",
    test_database("hidden-subtree"),
    "--exclude-hidden",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  assert_eq(
    index_stdout(result),
    "roots: 1\nfolders: 3\nfiles: 3\nbytes: 8\nskipped: 2",
  )
}

///|
async test "index applies basename and target restrictions to excludes" {
  let dir = make_tree_fixture()
  let files = @cli.run([
    "index",
    "-D",
    test_database("exclude-target"),
    "-x",
    "*.pdf",
    "--exclude-scope",
    "basename",
    "--exclude-target",
    "files",
    dir,
  ])
  let folders = @cli.run([
    "index",
    "-D",
    test_database("exclude-target"),
    "-x",
    "sub",
    "--exclude-scope",
    "basename",
    "--exclude-target",
    "folders",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  assert_eq(
    index_stdout(files),
    "roots: 1\nfolders: 4\nfiles: 4\nbytes: 8\nskipped: 1",
  )
  assert_eq(
    index_stdout(folders),
    "roots: 1\nfolders: 3\nfiles: 4\nbytes: 8\nskipped: 1",
  )
}

///|
async test "index applies a fixed full-path exclusion" {
  let dir = make_tree_fixture()
  let root = @fs.realpath(dir)
  let result = @cli.run([
    "index",
    "-x",
    "fixed:\{root}/a.txt",
    "--exclude-target",
    "files",
    root,
  ])
  @fs.remove(dir, recursive=true)
  assert_eq(
    index_stdout(result),
    "roots: 1\nfolders: 4\nfiles: 4\nbytes: 6\nskipped: 1",
  )
}

///|
async test "invalid exclude settings are usage errors" {
  let scope = @cli.run(["index", "--exclude-scope", "nope", "/tmp"])
  match scope {
    @cli.Failure(text) => {
      assert_true(text.contains("--exclude-scope"))
      assert_true(text.contains("got 'nope'"))
    }
    _ => abort("expected a scope failure")
  }
  let target = @cli.run(["index", "--exclude-target", "nope", "/tmp"])
  match target {
    @cli.Failure(text) => {
      assert_true(text.contains("--exclude-target"))
      assert_true(text.contains("got 'nope'"))
    }
    _ => abort("expected a target failure")
  }
  let regex = @cli.run(["index", "-x", "regex:^tmp$", "/tmp"])
  match regex {
    @cli.Failure(text) => assert_true(text.contains("not implemented"))
    _ => abort("expected a regex failure")
  }
}

///|
async test "nested roots require an explicit opt-in" {
  let dir = make_tree_fixture()
  let rejected = @cli.run(["index", dir, "\{dir}/sub"])
  let accepted = @cli.run([
    "index",
    "-D",
    test_database("nested"),
    "--allow-nested-roots",
    dir,
    "\{dir}/sub",
  ])
  @fs.remove(dir, recursive=true)
  match rejected {
    @cli.Failure(text) => {
      assert_true(text.contains("is inside"))
      assert_true(text.contains("--allow-nested-roots"))
    }
    _ => abort("expected nested roots to be rejected")
  }
  // The subtree is indexed twice: once under the parent and once as a root.
  assert_eq(index_stdout(accepted), "roots: 2\nfolders: 5\nfiles: 6\nbytes: 14")
}

///|
async test "duplicate roots are normalised before scanning" {
  let dir = make_tree_fixture()
  let result = @cli.run([
    "index",
    "-D",
    test_database("duplicate-roots"),
    dir,
    "\{dir}/",
    "\{dir}/.",
  ])
  @fs.remove(dir, recursive=true)
  assert_eq(index_stdout(result), "roots: 1\nfolders: 4\nfiles: 5\nbytes: 11")
}

///|
async test "a file used as a root is rejected" {
  let dir = @fs.tmpdir(prefix="moonsearch-file-root")
  let file = "\{dir}/plain"
  @fs.write_text(file, "x")
  let result = @cli.run(["index", file])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.Failure(text) => assert_true(text.contains("not a directory"))
    _ => abort("expected a root failure")
  }
}

///|
async test "indexing an empty directory reports zero files" {
  let dir = @fs.tmpdir(prefix="moonsearch-empty")
  let result = @cli.run(["index", "-D", test_database("empty-dir"), dir])
  @fs.remove(dir, recursive=true)
  assert_eq(index_stdout(result), "roots: 1\nfolders: 1\nfiles: 0\nbytes: 0")
}

///|
async test "quiet suppresses the summary but keeps success" {
  let dir = make_tree_fixture()
  let result = @cli.run(["index", "-D", test_database("quiet"), "--quiet", dir])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "")
      assert_eq(diagnostics, "")
      assert_eq(result.exit_code(), 0)
    }
    _ => abort("expected a quiet success")
  }
}

///|
async test "stats and verbose write diagnostics to stderr" {
  let dir = make_tree_fixture()
  let root = @fs.realpath(dir)
  let database = test_database("diagnostics")
  let stats = @cli.run(["index", "-D", database, "--stats", dir])
  let verbose = @cli.run(["index", "-D", database, "--verbose", dir])
  let both = @cli.run(["index", "-D", database, "--verbose", "--stats", dir])
  @fs.remove(dir, recursive=true)
  match stats {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "roots: 1\nfolders: 4\nfiles: 5\nbytes: 11")
      assert_true(diagnostics.contains("scan:"))
      assert_true(diagnostics.contains("names:"))
      assert_true(diagnostics.contains("dict: "))
      assert_true(diagnostics.contains("categories"))
      // The default fast fields are built eagerly; the others stay lazy.
      assert_true(diagnostics.contains("ranges: size="))
      assert_true(diagnostics.contains("mtime="))
      assert_false(diagnostics.contains("depth="))
      assert_false(diagnostics.contains("parent="))
      // The trigram postings are built unless --no-trigram is passed.
      assert_true(diagnostics.contains("trigram: "))
      assert_true(diagnostics.contains("keys, "))
      assert_true(diagnostics.contains("postings, "))
      assert_true(diagnostics.contains("skipped: hidden=0 excluded=0 mount=0"))
      assert_true(diagnostics.contains("issues: 0"))
      // Without --verbose the per-root line is absent.
      assert_false(diagnostics.contains("root: "))
    }
    _ => abort("expected stats diagnostics")
  }
  match verbose {
    @cli.SuccessWith(_, diagnostics) => {
      assert_true(
        diagnostics.contains("root: \{root} (files: 5, folders: 3, bytes: 11)"),
      )
      assert_false(diagnostics.contains("scan:"))
    }
    _ => abort("expected verbose diagnostics")
  }
  match both {
    @cli.SuccessWith(_, diagnostics) => {
      assert_true(diagnostics.contains("root: \{root}"))
      assert_true(diagnostics.contains("scan:"))
    }
    _ => abort("expected verbose and stats diagnostics")
  }
}

///|
async test "--no-trigram disables the posting build" {
  let dir = make_tree_fixture()
  let result = @cli.run([
    "index",
    "-D",
    test_database("no-trigram"),
    "--stats",
    "--no-trigram",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(_, diagnostics) => {
      assert_true(diagnostics.contains("trigram: disabled"))
      // The dictionary and range indexes are still built.
      assert_true(diagnostics.contains("dict: "))
      assert_true(diagnostics.contains("ranges: size="))
    }
    _ => abort("expected stats with a disabled trigram index")
  }
}

///|
async test "fast-fields selects the range indexes built eagerly" {
  let dir = make_tree_fixture()
  let result = @cli.run([
    "index",
    "-D",
    test_database("fast-fields"),
    "--stats",
    "--fast-fields",
    "size,depth,parent",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(_, diagnostics) => {
      assert_true(diagnostics.contains("ranges: size="))
      assert_true(diagnostics.contains("depth="))
      assert_true(diagnostics.contains("parent="))
      // mtime was not selected, so it is neither built nor reported.
      assert_false(diagnostics.contains("mtime="))
    }
    _ => abort("expected stats with range indexes")
  }
}

///|
async test "an unknown fast field is rejected before scanning" {
  let dir = make_tree_fixture()
  let result = @cli.run(["index", "--fast-fields", "size,bogus", dir])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.Failure(text) => {
      assert_true(text.contains("bogus"))
      assert_eq(result.exit_code(), 2)
    }
    _ => abort("expected an invalid fast-fields failure")
  }
}

///|
async test "one-file-system warns when the backend has no device ids" {
  let dir = make_tree_fixture()
  let result = @cli.run([
    "index",
    "-D",
    test_database("one-file-system"),
    "--one-file-system",
    dir,
  ])
  let quiet = @cli.run([
    "index",
    "-D",
    test_database("one-file-system"),
    "--quiet",
    "--one-file-system",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "roots: 1\nfolders: 4\nfiles: 5\nbytes: 11")
      assert_true(diagnostics.contains("--one-file-system has no effect"))
    }
    _ => abort("expected the one-file-system warning")
  }
  match quiet {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "")
      assert_true(diagnostics.contains("has no effect"))
    }
    _ => abort("expected the warning even with --quiet")
  }
}

///|
async test "unicode and long names are indexed end to end" {
  let dir = @fs.tmpdir(prefix="moonsearch-names")
  let long = StringBuilder()
  for _ in 0..<240 {
    long.write_string("n")
  }
  long.write_string(".txt")
  @fs.write_text("\{dir}/发票 2024.pdf", "ab")
  @fs.write_text("\{dir}/\{long.to_string()}", "c")
  let result = @cli.run(["index", "-D", test_database("unicode"), dir])
  @fs.remove(dir, recursive=true)
  assert_eq(index_stdout(result), "roots: 1\nfolders: 1\nfiles: 2\nbytes: 3")
}

///|
async test "index accepts a mix of option and positional roots" {
  let first = @fs.tmpdir(prefix="moonsearch-root-a")
  let second = @fs.tmpdir(prefix="moonsearch-root-b")
  @fs.write_text("\{first}/a", "1")
  @fs.write_text("\{second}/b", "22")
  let result = @cli.run([
    "index",
    "-D",
    test_database("mixed-roots"),
    "-r",
    first,
    second,
  ])
  @fs.remove(first, recursive=true)
  @fs.remove(second, recursive=true)
  assert_eq(index_stdout(result), "roots: 2\nfolders: 2\nfiles: 2\nbytes: 3")
}

///|
async test "global options work before the subcommand" {
  let dir = @fs.tmpdir(prefix="moonsearch-global")
  let result = @cli.run([
    "-D",
    test_database("global-before"),
    "--quiet",
    "index",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(out, _) => assert_eq(out, "")
    _ => abort("expected a quiet success")
  }
}

///|
async test "parse results distinguish help, version, and runs" {
  assert_true(@cli.parse([]) is Ok(@cli.ShowHelp(_)))
  assert_true(@cli.parse(["--version"]) is Ok(@cli.ShowVersion(_)))
  assert_true(@cli.parse(["help"]) is Ok(@cli.ShowHelp(_)))
  assert_true(@cli.parse(["index", "-r", "/tmp"]) is Ok(@cli.Run(_)))
}

///|
async test "commands without a database report errors" {
  let database = test_database("missing-commands")
  @fs.remove(database, allow_missing=true) catch {
    _ => ()
  }
  let search = @cli.run(["search", "-D", database, "report"])
  let count = @cli.run(["count", "-D", database, "report"])
  let info = @cli.run(["info", "-D", database])
  for result in [search, count] {
    assert_eq(result.exit_code(), 2)
    match result {
      @cli.Failure(text) => assert_true(text.contains("no index database"))
      _ => abort("expected a failure")
    }
  }
  assert_eq(info.exit_code(), 2)
  match info {
    @cli.Failure(text) => assert_true(text.contains("does not exist"))
    _ => abort("expected a failure")
  }
}

///|
async test "success results map to the success exit code" {
  assert_eq(@cli.SuccessWith("out", "err").exit_code(), 0)
}

///|
async test "update is the same scan as index" {
  let dir = make_tree_fixture()
  let result = @cli.run(["update", "-D", test_database("update"), dir])
  @fs.remove(dir, recursive=true)
  assert_eq(index_stdout(result), "roots: 1\nfolders: 4\nfiles: 5\nbytes: 11")
}

///|
async test "index without roots is a usage error" {
  let result = @cli.run(["index"])
  assert_eq(result.exit_code(), 2)
  match result {
    @cli.Failure(text) => {
      assert_true(text.contains("no roots configured"))
      assert_true(text.contains("--root"))
    }
    _ => abort("expected a usage failure")
  }
}

///|
async test "command-line errors surface as failures" {
  match @cli.run(["search", "--bogus"]) {
    @cli.Failure(text) => assert_true(text.contains("unexpected argument"))
    _ => abort("expected an argument failure")
  }
}

///|
async test "verbose and the one-file-system warning combine" {
  let dir = make_tree_fixture()
  let result = @cli.run([
    "index",
    "-D",
    test_database("verbose-warning"),
    "--verbose",
    "--stats",
    "--one-file-system",
    dir,
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "roots: 1\nfolders: 4\nfiles: 5\nbytes: 11")
      assert_true(diagnostics.contains("root: "))
      assert_true(diagnostics.contains("--one-file-system has no effect"))
      assert_true(diagnostics.contains("skipped: hidden=0 excluded=0 mount=0"))
    }
    _ => abort("expected verbose diagnostics with a warning")
  }
}

///|
async test "unreadable directories are reported in the summary and warnings" {
  let dir = @fs.tmpdir(prefix="moonsearch-cli-perm")
  let locked = "\{dir}/locked"
  @fs.mkdir(locked)
  @fs.write_text("\{locked}/secret", "x")
  @fs.write_text("\{dir}/open.txt", "hi")
  @fs.chmod(locked, 0o000)
  let denied = !@fs.can_read(locked)
  let result = @cli.run([
    "index",
    "-D",
    test_database("unreadable"),
    "--verbose",
    dir,
  ])
  @fs.chmod(locked, 0o755)
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(out, diagnostics) =>
      if denied {
        assert_eq(out, "roots: 1\nfolders: 2\nfiles: 1\nbytes: 2\nissues: 1")
        assert_true(diagnostics.contains("warning:"))
        assert_true(diagnostics.contains("locked"))
        assert_true(diagnostics.contains("permission denied"))
      } else {
        // Running as root: the directory stays readable.
        assert_eq(out, "roots: 1\nfolders: 2\nfiles: 2\nbytes: 3")
        assert_false(diagnostics.contains("warning:"))
      }
    _ => abort("expected a scan with diagnostics")
  }
}

///|
/// The scanner normalises roots with `realpath`; on macOS `/tmp` becomes
/// `/private/tmp`, so expected paths must use the same form.
async fn real_dir(dir : String) -> String {
  @fs.realpath(dir) catch {
    _ => dir
  }
}

///|
async test "search --live runs the scan engine end to end" {
  let dir = make_fixture("moonsearch-search")
  let real = real_dir(dir)
  let result = @cli.run(["search", "--live", "--root", dir, "a.txt"])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.Success(text) => assert_eq(text, "\{real}/a.txt")
    _ => abort("expected a match")
  }
}

///|
async test "search --live reports hits, misses, and counts" {
  let dir = make_fixture("moonsearch-search-count")
  let real = real_dir(dir)
  let pdf = @cli.run(["search", "--live", "--root", dir, "ext:pdf"])
  let missing = @cli.run(["search", "--live", "--root", dir, "ext:mp4"])
  let count = @cli.run(["count", "--live", "--root", dir, "ext:pdf"])
  let zero = @cli.run(["count", "--live", "--root", dir, "ext:mp4"])
  @fs.remove(dir, recursive=true)
  match pdf {
    @cli.Success(text) => assert_eq(text, "\{real}/sub/b.pdf")
    _ => abort("expected the pdf to match")
  }
  assert_eq(missing.exit_code(), 1)
  match missing {
    @cli.NoMatch(out, err) => {
      assert_eq(out, "")
      assert_eq(err, "")
    }
    _ => abort("expected a no-match result")
  }
  match count {
    @cli.Success(text) => assert_eq(text, "1")
    _ => abort("expected a count")
  }
  assert_eq(zero.exit_code(), 1)
  match zero {
    @cli.NoMatch(out, _) => assert_eq(out, "0")
    _ => abort("expected a zero count with no-match exit code")
  }
}

///|
async test "search --live supports limits, node kinds, and regex mode" {
  let dir = make_fixture("moonsearch-search-modes")
  let real = real_dir(dir)
  let limited = @cli.run(["search", "--live", "--root", dir, "-n", "2"])
  let folders = @cli.run(["search", "--live", "--root", dir, "--type", "folder"])
  let regex = @cli.run(["search", "--live", "--root", dir, "--regex", "^a"])
  @fs.remove(dir, recursive=true)
  match limited {
    @cli.Success(text) => assert_eq(text.split("\n").count(), 2)
    _ => abort("expected a limited result")
  }
  match folders {
    @cli.Success(text) => {
      assert_true(text.contains("\{real}/sub"))
      assert_true(!text.contains("a.txt"))
    }
    _ => abort("expected folder results")
  }
  match regex {
    @cli.Success(text) => assert_eq(text, "\{real}/a.txt")
    _ => abort("expected the regex to match a.txt")
  }
}

///|
async test "search --live explains the plan and prints statistics" {
  let dir = make_fixture("moonsearch-search-explain")
  let real = real_dir(dir)
  let result = @cli.run([
    "search", "--live", "--root", dir, "--explain", "--stats", "ext:pdf",
  ])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "\{real}/sub/b.pdf")
      assert_true(diagnostics.contains("query: (ext \"pdf\")"))
      assert_true(diagnostics.contains("plan: (ext \"pdf\")"))
      assert_true(diagnostics.contains("entries: "))
      assert_true(diagnostics.contains("matches: 1"))
      assert_true(diagnostics.contains("search: "))
    }
    _ => abort("expected search output with diagnostics")
  }
}

///|
async test "search validates output options before scanning" {
  let dir = make_fixture("moonsearch-search-options")
  let sort = @cli.run(["search", "--live", "--root", dir, "--sort", "bogus"])
  let json_template = @cli.run([
    "search", "--live", "--root", dir, "--json", "--format", "{path}",
  ])
  let json_basename = @cli.run([
    "search", "--live", "--root", dir, "--json", "--basename",
  ])
  let template_basename = @cli.run([
    "search", "--live", "--root", dir, "--basename", "--format", "{path}",
  ])
  let unknown = @cli.run([
    "search", "--live", "--root", dir, "--format", "{bogus}",
  ])
  let unterminated = @cli.run([
    "search", "--live", "--root", dir, "--format", "{path",
  ])
  let relative = @cli.run([
    "search", "--live", "--root", dir, "--relative-to", "/no/such/dir",
  ])
  let missing_root = @cli.run(["search", "--live", "x"])
  @fs.remove(dir, recursive=true)
  match sort {
    @cli.Failure(text) => {
      assert_true(text.contains("--sort"))
      assert_true(text.contains("bogus"))
    }
    _ => abort("expected the sort to be rejected")
  }
  match json_template {
    @cli.Failure(text) => assert_true(text.contains("cannot be combined"))
    _ => abort("expected json with format to be rejected")
  }
  match json_basename {
    @cli.Failure(text) => assert_true(text.contains("cannot be combined"))
    _ => abort("expected json with basename to be rejected")
  }
  match template_basename {
    @cli.Failure(text) => assert_true(text.contains("cannot be combined"))
    _ => abort("expected format with basename to be rejected")
  }
  match unknown {
    @cli.Failure(text) =>
      assert_true(text.contains("unknown format placeholder"))
    _ => abort("expected an unknown placeholder to be rejected")
  }
  match unterminated {
    @cli.Failure(text) => assert_true(text.contains("unterminated"))
    _ => abort("expected an unterminated placeholder to be rejected")
  }
  match relative {
    @cli.Failure(text) => assert_true(text.contains("--relative-to"))
    _ => abort("expected a missing relative directory to be rejected")
  }
  match missing_root {
    @cli.Failure(text) => assert_true(text.contains("no roots configured"))
    _ => abort("expected the missing root to be rejected")
  }
}

///|
/// A small tree with distinct names, extensions, and sizes:
///
/// ```text
/// a.pdf     30 B
/// b.txt     20 B
/// c/d.zip   10 B
/// ```
async fn make_order_fixture() -> String {
  let dir = @fs.tmpdir(prefix="moonsearch-order")
  @fs.mkdir("\{dir}/c")
  @fs.write_text("\{dir}/a.pdf", "012345678901234567890123456789")
  @fs.write_text("\{dir}/b.txt", "01234567890123456789")
  @fs.write_text("\{dir}/c/d.zip", "0123456789")
  dir
}

///|
async test "search orders by every key with limit and reversal" {
  let dir = make_order_fixture()
  let real = real_dir(dir)
  let by_size = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--sort", "size",
  ])
  let by_ext = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--sort", "ext",
  ])
  let by_type = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--sort", "type",
  ])
  let by_path = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--sort", "path",
  ])
  let limited = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--sort", "size", "-n",
    "2",
  ])
  let reversed = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--sort", "size", "--reverse",
  ])
  let reverse_limited = @cli.run([
    "search", "--live", "--root", dir, "--type", "file", "--reverse", "-n", "2",
  ])
  @fs.remove(dir, recursive=true)
  match by_size {
    @cli.Success(text) =>
      assert_eq(text, "\{real}/c/d.zip\n\{real}/b.txt\n\{real}/a.pdf")
    _ => abort("expected size order")
  }
  match by_ext {
    @cli.Success(text) =>
      assert_eq(text, "\{real}/a.pdf\n\{real}/b.txt\n\{real}/c/d.zip")
    _ => abort("expected extension order")
  }
  match by_type {
    @cli.Success(text) =>
      assert_eq(text, "\{real}/c/d.zip\n\{real}/a.pdf\n\{real}/b.txt")
    _ => abort("expected type order")
  }
  match by_path {
    @cli.Success(text) =>
      assert_eq(text, "\{real}/a.pdf\n\{real}/b.txt\n\{real}/c/d.zip")
    _ => abort("expected path order")
  }
  match limited {
    @cli.Success(text) => assert_eq(text, "\{real}/c/d.zip\n\{real}/b.txt")
    _ => abort("expected a limited result")
  }
  match reversed {
    @cli.Success(text) =>
      assert_eq(text, "\{real}/a.pdf\n\{real}/b.txt\n\{real}/c/d.zip")
    _ => abort("expected reversed size order")
  }
  match reverse_limited {
    @cli.Success(text) => assert_eq(text, "\{real}/c/d.zip\n\{real}/b.txt")
    _ => abort("expected a limited reverse-name result")
  }
}

///|
async test "folders-first groups folders ahead of files" {
  let dir = make_order_fixture()
  let real = real_dir(dir)
  let result = @cli.run(["search", "--live", "--root", dir, "--folders-first"])
  @fs.remove(dir, recursive=true)
  match result {
    @cli.Success(text) =>
      assert_eq(
        text,
        "\{real}\n\{real}/c\n\{real}/a.pdf\n\{real}/b.txt\n\{real}/c/d.zip",
      )
    _ => abort("expected folder-first output")
  }
}

///|
async test "basename, null, relative, json, and format output" {
  let dir = make_order_fixture()
  let real = real_dir(dir)
  let base = ["search", "--live", "--root", dir, "--type", "file"]
  let basename = @cli.run(base + ["--basename"])
  let nul = @cli.run(base + ["--null"])
  let relative = @cli.run(base + ["--relative-to", dir])
  let json = @cli.run(base + ["--json", "--relative-to", dir])
  let template = @cli.run(
    base +
    ["--relative-to", dir, "--format", "{path}|{size}|{ext}|{type}|{kind}"],
  )
  @fs.remove(dir, recursive=true)
  match basename {
    @cli.Success(text) => assert_eq(text, "a.pdf\nb.txt\nd.zip")
    _ => abort("expected basenames")
  }
  match nul {
    @cli.Success(text) => {
      assert_eq(
        text,
        "\{real}/a.pdf\u{0}\{real}/b.txt\u{0}\{real}/c/d.zip\u{0}",
      )
      assert_true(text.get_char(text.length() - 1) is Some('\u{0}'))
    }
    _ => abort("expected NUL-terminated output")
  }
  match relative {
    @cli.Success(text) => assert_eq(text, "a.pdf\nb.txt\nc/d.zip")
    _ => abort("expected relative paths")
  }
  match json {
    @cli.Success(text) => {
      assert_true(text.contains("\"path\":\"a.pdf\""))
      assert_true(text.contains("\"name\":\"a.pdf\""))
      assert_true(text.contains("\"size\":30"))
      assert_true(text.contains("\"ext\":\"pdf\""))
      assert_true(text.contains("\"type\":\"doc\""))
      assert_true(text.contains("\"kind\":\"file\""))
      assert_eq(text.split("\n").count(), 3)
    }
    _ => abort("expected JSON lines")
  }
  match template {
    @cli.Success(text) =>
      assert_eq(
        text, "a.pdf|30|pdf|doc|file\nb.txt|20|txt|doc|file\nc/d.zip|10|zip|archive|file",
      )
    _ => abort("expected formatted output")
  }
}

///|
async test "both engines produce byte-identical output" {
  let dir = make_order_fixture()
  let sorts = ["name", "path", "size", "mtime", "ext", "type"]
  let variants : Array[Array[String]] = [
    [],
    ["--reverse"],
    ["--folders-first"],
    ["-n", "2"],
    ["--reverse", "-n", "2"],
    ["--folders-first", "-n", "2"],
  ]
  let formats : Array[Array[String]] = [
    ["--json"],
    ["--null"],
    ["--basename"],
    ["--format", "{path}|{name}|{size}|{ext}|{type}|{kind}"],
    ["--relative-to", dir],
  ]
  let failures : Array[String] = []
  for sort in sorts {
    for variant in variants {
      let base = ["search", "--live", "--root", dir, "--sort", sort, "file:"] +
        variant
      let scan = @cli.run(base)
      let bitmap = @cli.run(base + ["--engine", "bitmap"])
      if stdout_of(scan) != stdout_of(bitmap) ||
        scan.exit_code() != bitmap.exit_code() {
        failures.push("sort=\{sort} \{variant.join(" ")}")
      }
    }
  }
  for format in formats {
    let base = ["search", "--live", "--root", dir, "file:"] + format
    let scan = @cli.run(base)
    let bitmap = @cli.run(base + ["--engine", "bitmap"])
    if stdout_of(scan) != stdout_of(bitmap) ||
      scan.exit_code() != bitmap.exit_code() {
      failures.push("format=\{format.join(" ")}")
    }
  }
  @fs.remove(dir, recursive=true)
  assert_eq(failures, [])
}

///|
async test "search --live runs the bitmap engine end to end" {
  let dir = make_fixture("moonsearch-bitmap")
  let real = real_dir(dir)
  let search = @cli.run([
    "search", "--live", "--root", dir, "--engine", "bitmap", "a.txt",
  ])
  let count = @cli.run([
    "count", "--live", "--root", dir, "--engine", "bitmap", "ext:pdf",
  ])
  let miss = @cli.run([
    "search", "--live", "--root", dir, "--engine", "bitmap", "ext:mp4",
  ])
  let explain = @cli.run([
    "search", "--live", "--root", dir, "--engine", "bitmap", "--explain", "a.txt",
  ])
  @fs.remove(dir, recursive=true)
  match search {
    @cli.Success(text) => assert_eq(text, "\{real}/a.txt")
    _ => abort("expected the bitmap engine to match a.txt")
  }
  match count {
    @cli.Success(text) => assert_eq(text, "1")
    _ => abort("expected the bitmap engine to count the pdf")
  }
  assert_eq(miss.exit_code(), 1)
  match explain {
    @cli.SuccessWith(out, diagnostics) => {
      assert_eq(out, "\{real}/a.txt")
      assert_true(diagnostics.contains("plan: (trigram#"))
      assert_true(diagnostics.contains("(substring \"a.txt\" nocase)"))
    }
    _ => abort("expected bitmap explain diagnostics")
  }
}

///|
async test "search --live accepts repeated roots and auto-index" {
  let first = @fs.tmpdir(prefix="moonsearch-root-a")
  let second = @fs.tmpdir(prefix="moonsearch-root-b")
  let database = test_database("auto-index")
  @fs.remove(database, allow_missing=true) catch {
    _ => ()
  }
  @fs.write_text("\{first}/one.txt", "1")
  @fs.write_text("\{second}/two.txt", "2")
  let first_real = real_dir(first)
  let second_real = real_dir(second)
  let result = @cli.run([
    "search", "--live", "--root", first, "--root", second, "*.txt",
  ])
  let auto = @cli.run([
    "search", "--auto-index", "-D", database, "--root", first, "--root", second,
    "*.txt",
  ])
  @fs.remove(first, recursive=true)
  @fs.remove(second, recursive=true)
  let expected = "\{first_real}/one.txt\n\{second_real}/two.txt"
  match result {
    @cli.Success(text) => assert_eq(text, expected)
    _ => abort("expected both roots to be searched")
  }
  match auto {
    @cli.Success(text) => assert_eq(text, expected)
    _ => abort("expected --auto-index to scan the roots")
  }
  assert_true(@fs.exists(database))
}
