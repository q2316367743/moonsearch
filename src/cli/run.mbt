///|
/// Outcome of one CLI invocation.
///
/// `Success` carries the exact bytes written to stdout, `Failure` the text
/// written to stderr. `SuccessWith` adds diagnostics (`--verbose`, `--stats`,
/// warnings) while still succeeding. Byte payloads keep Unix names lossless and
/// leave stream handling to `cmd/moonsearch`.
pub(all) enum CliResult {
  Success(Bytes)
  SuccessWith(Bytes, String)
  /// The command matched nothing. The payloads are written to stdout (a count
  /// for `count`, empty for `search`) and stderr (diagnostics), and the exit
  /// code is 1.
  NoMatch(Bytes, String)
  Failure(String)
}

///|
/// Encode one complete output line, matching the former `println` behavior.
fn text_line(text : String) -> Bytes {
  if text.is_empty() {
    return b""
  }
  let out = @buffer.Buffer()
  out.write_string_utf8(text)
  out.write_byte(b'\n')
  out.to_bytes()
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
    Info => run_info(invocation)
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
    Ok(ShowHelp(text)) => Success(text_line(text))
    Ok(ShowVersion(text)) => Success(text_line(text))
    Err(text) => Failure(text)
  }
}
