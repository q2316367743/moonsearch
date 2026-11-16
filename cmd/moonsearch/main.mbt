///|
/// Write result text to stdout.
///
/// The CLI renders newline-separated records without a final newline, so the
/// built-in `println` supplies it. NUL-terminated output must keep its exact
/// bytes, including the final NUL, so it is written directly instead of gaining
/// a newline that would break `xargs -0`.
async fn write_stdout(text : String) -> Unit {
  if text.is_empty() {
    return
  }
  if text.get_char(text.length() - 1) is Some('\u{0}') {
    @stdio.stdout.write(@utf8.encode(text[:])[:])
  } else {
    println(text)
  }
}

///|
/// Entry point: forward argv to the CLI package and translate the result into
/// stdout/stderr and a process exit code.
async fn main {
  let argv = @env.args()
  let rest : Array[String] = if argv.length() > 1 {
    argv[1:].to_owned()
  } else {
    []
  }
  let result : @cli.CliResult = @cli.run(rest, env=@env.get_env_vars())
  match result {
    @cli.Success(text) => {
      write_stdout(text)
      @env.exit(result.exit_code())
    }
    @cli.SuccessWith(out, err) => {
      write_stdout(out)
      if err.length() > 0 {
        eprintln(err)
      }
      @env.exit(result.exit_code())
    }
    @cli.NoMatch(out, err) => {
      write_stdout(out)
      if err.length() > 0 {
        eprintln(err)
      }
      @env.exit(result.exit_code())
    }
    @cli.Failure(text) => {
      eprintln(text)
      @env.exit(result.exit_code())
    }
  }
}
