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
/// Home directory for `~` expansion: `$HOME` on Unix, `%USERPROFILE%` on
/// Windows.
fn resolve_home(lookup : (String) -> String?) -> String? {
  match lookup("HOME") {
    Some(home) => Some(home)
    None => lookup("USERPROFILE")
  }
}

///|
/// Expand a leading `~` or `~/` against the home directory.
///
/// Only the two documented forms are expanded; `~user` and a tilde in the
/// middle of a path stay literal, matching the configuration rules.
fn expand_home(path : String, invocation : Invocation) -> String {
  if path == "~" {
    match resolve_home(fn(name) { environment_value(invocation, name) }) {
      Some(home) => home
      None => path
    }
  } else if path.has_prefix("~/") {
    match resolve_home(fn(name) { environment_value(invocation, name) }) {
      Some(home) => "\{home}\{path[1:]}"
      None => path
    }
  } else {
    path
  }
}

///|
/// Data directory behind the default database path.
///
/// Order: `$XDG_DATA_HOME`, `$HOME/.local/share`, `%LOCALAPPDATA%` (the usual
/// Windows data root), then `%USERPROFILE%/.local/share`. `lookup` is the
/// environment accessor; it should report unset or empty variables as `None`,
/// which lets tests drive the resolver without touching the process
/// environment.
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
/// Order: `-D/--database`, `MOONSEARCH_DATABASE`, then the platform data
/// directory (`$XDG_DATA_HOME`, `$HOME/.local/share`, or `%LOCALAPPDATA%` on
/// Windows) joined with `moonsearch/index.msdb`. The explicit option and the
/// environment variable are already parsed by argparse; the default is
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
        None =>
          match
            resolve_data_home(fn(name) { environment_value(invocation, name) }) {
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
