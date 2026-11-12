///|
/// Outcome of one CLI invocation.
///
/// `Success` carries the text written to stdout, `Failure` the text written to
/// stderr. `SuccessWith` is used when a command also has diagnostics for
/// stderr (`--verbose`, `--stats`, warnings) while still succeeding. Keeping
/// text as a value makes help and error output assertable in tests and leaves
/// stream handling to `cmd/moonsearch`.
pub(all) enum CliResult {
  Success(String)
  SuccessWith(String, String)
  /// The command matched nothing. The payloads are written to stdout (a count
  /// for `count`, empty for `search`) and stderr (diagnostics), and the exit
  /// code is 1.
  NoMatch(String, String)
  Failure(String)
}

///|
/// Process exit code for this result.
pub fn CliResult::exit_code(self : CliResult) -> Int32 {
  match self {
    Success(_) => @core.EXIT_OK
    SuccessWith(_, _) => @core.EXIT_OK
    NoMatch(_, _) => @core.EXIT_NO_MATCH
    Failure(_) => @core.EXIT_ERROR
  }
}

///|
/// Run one subcommand.
async fn execute(invocation : Invocation) -> CliResult {
  match invocation.command {
    Index => run_index(invocation)
    Update => run_index(invocation)
    Search => run_search(invocation)
    Count => run_count(invocation)
    Info => Failure("error: 'info' is not implemented yet")
  }
}

///|
/// Parse and run a command line.
///
/// `argv` excludes the program name. Help and version requests succeed and
/// return the text to print on stdout.
pub async fn run(
  argv : ArrayView[String],
  env~ : Map[String, String] = Map([]),
) -> CliResult {
  match parse(argv, env~) {
    Ok(Run(invocation)) => execute(invocation)
    Ok(ShowHelp(text)) => Success(text)
    Ok(ShowVersion(text)) => Success(text)
    Err(text) => Failure(text)
  }
}
