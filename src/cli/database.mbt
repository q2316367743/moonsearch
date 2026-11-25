///|
/// Effective environment for path expansion and configuration lookup.
///
/// The map supplied to `run` wins over the process environment, including when
/// a test explicitly supplies an empty value to mark a variable as unset.
fn effective_environment(invocation : Invocation) -> Map[String, String] {
  let env = @env.get_env_vars()
  for name, value in invocation.env {
    env[name] = value
  }
  env
}

///|
/// Non-empty environment value.
fn environment_value(env : Map[String, String], name : String) -> String? {
  match env.get(name) {
    Some(value) => if value.is_empty() { None } else { Some(value) }
    None => None
  }
}

///|
/// Expand a command-line or environment path with the configuration whitelist.
fn expand_path(
  path : String,
  env : Map[String, String],
) -> Result[String, String] {
  try @config.expand_path(path, env) catch {
    err => Err("error: \{err.message()}")
  } noraise {
    value => Ok(value)
  }
}

///|
/// Data directory behind the default database path.
///
/// Order: `$XDG_DATA_HOME`, `$HOME/.local/share`, `%LOCALAPPDATA%` (the usual
/// Windows data root), then `%USERPROFILE%/.local/share`.
fn resolve_data_home(lookup : (String) -> String?) -> Result[String, String] {
  match lookup("XDG_DATA_HOME") {
    Some(path) => Ok(path)
    None =>
      match lookup("HOME") {
        Some(home) => Ok("\{home}/.local/share")
        None =>
          match lookup("LOCALAPPDATA") {
            Some(path) => Ok(path)
            None =>
              match lookup("USERPROFILE") {
                Some(home) => Ok("\{home}/.local/share")
                None =>
                  Err(
                    "error: cannot determine the database path; pass --database <PATH> or set MOONSEARCH_DATABASE",
                  )
              }
          }
      }
  }
}

///|
/// Resolve the database path for a command.
///
/// Order: `-D/--database`, `MOONSEARCH_DATABASE`, the configuration file, then
/// the platform data directory joined with `moonsearch/index.msdb`.
fn database_path(invocation : Invocation) -> Result[String, String] {
  let env = effective_environment(invocation)
  match explicit_option_value(invocation.matches, "database") {
    Some(path) => expand_path(path, env)
    None =>
      match environment_value(env, "MOONSEARCH_DATABASE") {
        Some(path) => expand_path(path, env)
        None =>
          match invocation.config.database {
            Some(path) => Ok(path)
            None =>
              match
                resolve_data_home(fn(name) { environment_value(env, name) }) {
                Ok(data_home) => {
                  let base = if data_home.has_suffix("/") {
                    data_home[:data_home.length() - 1].to_owned()
                  } else {
                    data_home
                  }
                  Ok("\{base}/moonsearch/index.msdb")
                }
                Err(message) => Err(message)
              }
          }
      }
  }
}
