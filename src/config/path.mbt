///|
/// Home directory used by XDG defaults and leading-tilde expansion.
fn home_directory(env : Map[String, String]) -> String? {
  match env.get("HOME") {
    Some(home) if !home.is_empty() => Some(home)
    _ =>
      match env.get("USERPROFILE") {
        Some(home) => if home.is_empty() { None } else { Some(home) }
        None => None
      }
  }
}

///|
/// Join an XDG base directory and the moonsearch subpath.
fn xdg_path(base : String, suffix : String) -> String {
  if base.has_suffix("/") {
    "\{base}\{suffix}"
  } else {
    "\{base}/\{suffix}"
  }
}

///|
/// Default configuration path: `$XDG_CONFIG_HOME/moonsearch/config.json`, or
/// `$HOME/.config/moonsearch/config.json` when XDG_CONFIG_HOME is unset.
pub fn default_config_path(env : Map[String, String]) -> String? {
  match env.get("XDG_CONFIG_HOME") {
    Some(base) =>
      if base.is_empty() {
        match home_directory(env) {
          Some(home) => Some(xdg_path(home, ".config/moonsearch/config.json"))
          None => None
        }
      } else {
        Some(xdg_path(base, "moonsearch/config.json"))
      }
    None =>
      match home_directory(env) {
        Some(home) => Some(xdg_path(home, ".config/moonsearch/config.json"))
        None => None
      }
  }
}

///|
/// Expand a leading `~` or `~/`. Other tilde forms are rejected rather than
/// interpreted as another user's home directory.
fn expand_home(
  path : String,
  env : Map[String, String],
) -> String raise ConfigError {
  if path == "~" || path.has_prefix("~/") {
    match home_directory(env) {
      Some(home) => if path == "~" { home } else { "\{home}\{path[1:]}" }
      None => raise ConfigError::Invalid("cannot expand '~': HOME is not set")
    }
  } else if path.has_prefix("~") {
    raise ConfigError::Invalid(
      "unsupported home expansion in path '\{path}'; only '~' and '~/' are supported",
    )
  } else {
    path
  }
}

///|
/// Whether an environment variable is in the documented expansion whitelist.
fn allowed_variable(name : String) -> Bool {
  name == "HOME" || name.has_prefix("XDG_")
}

///|
/// Read an ASCII environment variable name, including an optional braced form.
fn variable_name(
  chars : Array[Char],
  start : Int32,
) -> (String, Int32) raise ConfigError {
  let mut index = start
  let braced = index < chars.length() && chars[index] == '{'
  if braced {
    index = index + 1
  }
  let name_start = index
  while index < chars.length() && is_name_char(chars[index]) {
    index = index + 1
  }
  if index == name_start {
    raise ConfigError::Invalid("invalid environment variable expansion in path")
  }
  let name = String::from_array(chars[name_start:index].to_owned())
  if braced {
    if index >= chars.length() || chars[index] != '}' {
      raise ConfigError::Invalid(
        "unterminated environment variable expansion '\{name}'",
      )
    }
    index = index + 1
  }
  (name, index)
}

///|
/// ASCII identifier character accepted in `$NAME` and `${NAME}`.
fn is_name_char(char : Char) -> Bool {
  (char >= 'a' && char <= 'z') ||
  (char >= 'A' && char <= 'Z') ||
  (char >= '0' && char <= '9') ||
  char == '_'
}

///|
/// Expand only `$HOME` and `$XDG_*`. No shell evaluation, command substitution,
/// recursive expansion, or unlisted variable is performed.
fn expand_variables(
  path : String,
  env : Map[String, String],
) -> String raise ConfigError {
  let chars : Array[Char] = []
  for char in path.iter() {
    chars.push(char)
  }
  let out : Array[Char] = []
  let mut index = 0
  while index < chars.length() {
    let char = chars[index]
    if char != '$' {
      out.push(char)
      index = index + 1
      continue
    }
    let (name, next) = variable_name(chars, index + 1)
    if !allowed_variable(name) {
      raise ConfigError::Invalid(
        "unsupported environment variable '\{name}' in path; only HOME and XDG_* are allowed",
      )
    }
    match env.get(name) {
      Some(value) =>
        if value.is_empty() {
          raise ConfigError::Invalid(
            "cannot expand '\{name}' in path: the variable is empty",
          )
        } else {
          for expanded in value.iter() {
            out.push(expanded)
          }
        }
      None =>
        raise ConfigError::Invalid(
          "cannot expand '\{name}' in path: the variable is not set",
        )
    }
    index = next
  }
  String::from_array(out)
}

///|
/// Expand a configured or command-line path with the documented whitelist.
pub fn expand_path(
  path : StringView,
  env : Map[String, String],
) -> String raise ConfigError {
  let text = "\{path}"
  if text.is_empty() {
    raise ConfigError::Invalid("path is empty")
  }
  let home_expanded = expand_home(text, env)
  expand_variables(home_expanded, env)
}
