///|
/// Outcome of one CLI invocation.
///
/// `Success` carries the text written to stdout, `Failure` the text written to
/// stderr. Keeping text as a value makes help and error output assertable in
/// tests and leaves stream handling to `cmd/moonsearch`.
pub(all) enum CliResult {
  Success(String)
  NoMatch
  Failure(String)
}

///|
/// Process exit code for this result.
pub fn CliResult::exit_code(self : CliResult) -> Int32 {
  match self {
    Success(_) => @core.EXIT_OK
    NoMatch => @core.EXIT_NO_MATCH
    Failure(_) => @core.EXIT_ERROR
  }
}

///|
/// Run one subcommand.
///
/// S01 only fixes the CLI contract; every command reports that its
/// implementation is still pending.
fn execute(invocation : Invocation) -> CliResult {
  let name = invocation.command.name()
  Failure("error: '\{name}' is not implemented yet")
}

///|
/// Parse and run a command line.
///
/// `argv` excludes the program name. Help and version requests succeed and
/// return the text to print on stdout.
pub fn run(
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
