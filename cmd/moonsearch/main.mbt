///|
/// Write exact stdout bytes. Record terminators are chosen by the formatter;
/// the entry point never decodes names or appends a newline.
async fn write_stdout(bytes : Bytes) -> Unit {
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
  let result : @cli.CliResult = @cli.run(rest, env=@env.get_env_vars())
  match result {
    @cli.Success(out) => {
      write_stdout(out)
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
