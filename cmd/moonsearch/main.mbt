///|
/// Whether a stdout error means the downstream pipe closed normally.
fn is_broken_pipe(error : @io.WriterError) -> Bool {
  let os_error = match error {
    @io.WriterError::TransportError(inner, context=_) => inner
    @io.WriterError::.. => return false
  }
  match os_error {
    @os_error.OsError(_, raw_code=code, context=_) => code == 32 || code == 109
    _ => false
  }
}

///|
/// Exit quietly for EPIPE; retain the ordinary CLI error for other IO failures.
fn output_failure(error : @io.WriterError) -> Unit {
  if is_broken_pipe(error) {
    @env.exit(@core.EXIT_OK)
  }
  let message = match error {
    @io.WriterError::TransportError(inner, context=_) => inner.to_string()
    @io.WriterError::.. => "stdout write failed"
  }
  eprintln("error: \{message}")
  @env.exit(@core.EXIT_ERROR)
}

///|
/// Write exact stdout bytes. Record terminators are chosen by the formatter;
/// the entry point never decodes names or appends a newline.
async fn write_stdout(bytes : Bytes) -> Unit raise @io.WriterError {
  if !bytes.is_empty() {
    @stdio.stdout.write(bytes[:])
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
  let result : @cli.CliResult = @cli.run_streaming(
    rest,
    @stdio.stdout,
    env=@env.get_env_vars(),
  )
  match result {
    @cli.Success(out) => {
      write_stdout(out) catch {
        err => output_failure(err)
      }
      @env.exit(result.exit_code())
    }
    @cli.SuccessWith(out, err) => {
      write_stdout(out) catch {
        write_err => output_failure(write_err)
      }
      if err.length() > 0 {
        eprintln(err)
      }
      @env.exit(result.exit_code())
    }
    @cli.NoMatch(out, err) => {
      write_stdout(out) catch {
        write_err => output_failure(write_err)
      }
      if err.length() > 0 {
        eprintln(err)
      }
      @env.exit(result.exit_code())
    }
    @cli.Streamed(code, err) => {
      if err.length() > 0 {
        eprintln(err)
      }
      @env.exit(code)
    }
    @cli.OutputFailure(error) => output_failure(error)
    @cli.Failure(text) => {
      eprintln(text)
      @env.exit(result.exit_code())
    }
  }
}
