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
      if text.length() > 0 {
        println(text)
      }
      @env.exit(result.exit_code())
    }
    @cli.SuccessWith(out, err) => {
      if out.length() > 0 {
        println(out)
      }
      if err.length() > 0 {
        eprintln(err)
      }
      @env.exit(result.exit_code())
    }
    @cli.NoMatch => @env.exit(result.exit_code())
    @cli.Failure(text) => {
      eprintln(text)
      @env.exit(result.exit_code())
    }
  }
}
