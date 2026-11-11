///|
/// Extract the text a successful invariant writes to stdout.
fn stdout_of(result : @cli.CliResult) -> String {
  match result {
    @cli.Success(text) => text
    @cli.NoMatch => abort("expected success, got NoMatch")
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
test "top-level help is stable" {
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
test "index help is stable" {
  inspect(
    stdout_of(@cli.run(["index", "--help"])),
    content=(
      #|Usage: moonsearch index [options]
      #|
      #|Scan the configured roots and write the index
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
test "update help is stable" {
  inspect(
    stdout_of(@cli.run(["update", "--help"])),
    content=(
      #|Usage: moonsearch update [options]
      #|
      #|Rescan the configured roots and rebuild the index
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
test "search help is stable" {
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
      #|  --engine <engine>            Execution engine: bitmap (default) or scan [default: bitmap]
      #|  --sort <sort>                Result order: name, path, size, mtime, ext, or type [default: name]
      #|  -n, --limit <limit>          Maximum number of results; 0 means unlimited [default: 0]
      #|  --format <format>            Custom output template for each match
      #|  --relative-to <relative-to>  Print paths relative to this directory
    ),
  )
}

///|
test "count help is stable" {
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
      #|  --engine <engine>          Execution engine: bitmap (default) or scan [default: bitmap]
    ),
  )
}

///|
test "info help is stable" {
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
    ),
  )
}

///|
test "version" {
  inspect(stdout_of(@cli.run(["--version"])), content="moonsearch 0.1.0")
}

///|
test "no arguments prints help and succeeds" {
  let empty = @cli.run([])
  assert_eq(empty.exit_code(), 0)
  assert_eq(stdout_of(empty), stdout_of(@cli.run(["--help"])))
}

///|
test "bare query dispatches to search" {
  let invocation = run_ok(["ext:pdf"])
  assert_eq(invocation.command.name(), "search")
  assert_eq(invocation.query, "ext:pdf")
}

///|
test "positional query terms are joined with single spaces" {
  let invocation = run_ok(["report", "pdf"])
  assert_eq(invocation.query, "report pdf")
}

///|
test "double dash allows a leading-hyphen query" {
  let invocation = run_ok(["--", "-foo"])
  assert_eq(invocation.query, "-foo")
}

///|
test "explicit subcommands are recognised" {
  assert_eq(run_ok(["index", "-r", "/tmp"]).command.name(), "index")
  assert_eq(run_ok(["update"]).command.name(), "update")
  assert_eq(run_ok(["search"]).command.name(), "search")
  assert_eq(run_ok(["count"]).command.name(), "count")
  assert_eq(run_ok(["info"]).command.name(), "info")
}

///|
test "repeated index roots are kept in order" {
  let invocation = run_ok(["index", "-r", "/tmp", "--root", "/var"])
  let roots = invocation.matches.values.get("root").unwrap()
  assert_eq(roots.join(","), "/tmp,/var")
}

///|
test "global option works after the subcommand" {
  let invocation = run_ok(["search", "-D", "/tmp/db.msdb"])
  assert_eq(first_value(invocation, "database"), Some("/tmp/db.msdb"))
}

///|
test "database path can come from the environment" {
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
test "unknown options are usage errors" {
  match @cli.parse(["search", "--bogus"]) {
    Err(message) => {
      assert_true(message.contains("unexpected argument '--bogus'"))
      assert_eq(@cli.Failure(message).exit_code(), 2)
    }
    Ok(_) => abort("expected a parse error")
  }
}

///|
test "missing option values are usage errors" {
  match @cli.parse(["search", "--database"]) {
    Err(message) => assert_true(message.contains("a value is required"))
    Ok(_) => abort("expected a parse error")
  }
}

///|
test "count rejects search-only ordering options" {
  match @cli.parse(["count", "--sort", "size"]) {
    Err(_) => ()
    Ok(_) => abort("count must not accept --sort")
  }
}

///|
test "exit code mapping" {
  assert_eq(@cli.Success("").exit_code(), 0)
  assert_eq(@cli.NoMatch.exit_code(), 1)
  assert_eq(@cli.Failure("error").exit_code(), 2)
}

///|
test "pending subcommands report a usage error" {
  let result = @cli.run(["search", "report"])
  assert_eq(result.exit_code(), 2)
  match result {
    @cli.Failure(text) => assert_true(text.contains("not implemented"))
    _ => abort("expected a failure")
  }
}
