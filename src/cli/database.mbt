///|
/// Environment value visible to an invocation.
///
/// The map passed to `parse` wins so tests can redirect the database without
/// touching the process environment; the process environment is the product
/// fallback.
fn environment_value(invocation : Invocation, name : String) -> String? {
  match invocation.env.get(name) {
    Some(value) => if value.is_empty() { None } else { Some(value) }
    None =>
      match @env.get_env_var(name) {
        Some(value) => if value.is_empty() { None } else { Some(value) }
        None => None
      }
  }
}

///|
/// Expand a leading `~` or `~/` against `$HOME`.
///
/// Only the two documented forms are expanded; `~user` and a tilde in the
/// middle of a path stay literal, matching the configuration rules.
fn expand_home(path : String, invocation : Invocation) -> String {
  if path == "~" {
    match environment_value(invocation, "HOME") {
      Some(home) => home
      None => path
    }
  } else if path.has_prefix("~/") {
    match environment_value(invocation, "HOME") {
      Some(home) => "\{home}\{path[1:]}"
      None => path
    }
  } else {
    path
  }
}

///|
/// Resolve the database path for a command.
///
/// Order: `-D/--database`, `MOONSEARCH_DATABASE`, then
/// `$XDG_DATA_HOME/moonsearch/index.msdb` (or
/// `$HOME/.local/share/moonsearch/index.msdb`). The explicit option and the
/// environment variable are already parsed by argparse; the XDG default is
/// resolved here because it is not a command-line value.
fn database_path(invocation : Invocation) -> Result[String, String] {
  match first_option_value(invocation.matches, "database") {
    Some(path) => {
      let expanded = expand_home(path, invocation)
      if expanded.is_empty() {
        Err("error: the database path is empty")
      } else {
        Ok(expanded)
      }
    }
    None =>
      match environment_value(invocation, "MOONSEARCH_DATABASE") {
        Some(path) => Ok(expand_home(path, invocation))
        None => {
          let data_home = match environment_value(invocation, "XDG_DATA_HOME") {
            Some(path) => path
            None =>
              match environment_value(invocation, "HOME") {
                Some(home) => "\{home}/.local/share"
                None =>
                  return Err(
                    "error: cannot determine the database path; pass --database <PATH> or set MOONSEARCH_DATABASE",
                  )
              }
          }
          let base = if data_home.has_suffix("/") {
            data_home[:data_home.length() - 1].to_owned()
          } else {
            data_home
          }
          Ok("\{base}/moonsearch/index.msdb")
        }
      }
  }
}
