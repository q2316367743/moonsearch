///|
/// Read and validate an explicitly selected configuration file.
///
/// Missing files, permission failures, malformed JSON, unknown fields, and
/// invalid values are all errors; an explicit `--config` is never ignored.
pub async fn load_explicit(
  path : StringView,
  env~ : Map[String, String] = Map([]),
) -> Config raise ConfigError {
  let expanded = try expand_path(path, env) catch {
    err => raise ConfigError::Read(err.message())
  } noraise {
    value => value
  }
  let text = @fs.read_text(expanded) catch {
    err =>
      raise ConfigError::Read("cannot read configuration \{expanded}: \{err}")
  }
  try parse(text, env~) catch {
    err =>
      raise ConfigError::Invalid("configuration \{expanded}: \{err.message()}")
  } noraise {
    value => value
  }
}

///|
/// Load the default XDG configuration when it exists.
///
/// The default file is optional. Not having one is normal; an invalid file at
/// the default path is still an error rather than a reason to silently fall
/// back to defaults.
pub async fn load_default(
  env~ : Map[String, String] = Map([]),
) -> Config raise ConfigError {
  match default_config_path(env) {
    Some(path) => {
      let exists = try @fs.exists(path) catch {
        err =>
          raise ConfigError::Read("cannot access configuration \{path}: \{err}")
      } noraise {
        value => value
      }
      if exists {
        load_explicit(path, env~)
      } else {
        Config::default()
      }
    }
    None => Config::default()
  }
}
