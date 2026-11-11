///|
/// Entry point: forward argv to the CLI package and translate the result into
/// stdout/stderr and a process exit code.
fn main {
  let argv = @env.args()
  let rest : Array[String] = if argv.length() > 1 {
    argv[1:].to_owned()
  } else {
    []
  }
  let result : @cli.CliResult = @cli.run(rest, env=@env.get_env_vars())
  match result {
    @cli.Success(text) => {
      println(text)
      @env.exit(result.exit_code())
    }
    @cli.NoMatch => @env.exit(result.exit_code())
    @cli.Failure(text) => {
      eprintln(text)
      @env.exit(result.exit_code())
    }
  }
}
