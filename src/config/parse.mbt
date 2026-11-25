///|
/// Reject a value that is not an object.
fn expect_object(
  json : @json.Json,
  path : String,
) -> Map[String, @json.Json] raise ConfigError {
  match json {
    Object(object) => object
    _ => raise ConfigError::Invalid("\{path}: expected an object")
  }
}

///|
/// Reject unknown keys at every configuration level.
fn check_fields(
  object : Map[String, @json.Json],
  allowed : Array[String],
  path : String,
) -> Unit raise ConfigError {
  let keys : Array[String] = []
  for key, _ in object {
    keys.push(key)
  }
  keys.sort()
  for key in keys {
    let mut known = false
    for candidate in allowed {
      if key == candidate {
        known = true
      }
    }
    if !known {
      let location = if path.is_empty() { key } else { "\{path}.\{key}" }
      raise ConfigError::Invalid("unknown field '\{location}'")
    }
  }
}

///|
/// Decode a required string.
fn expect_string(json : @json.Json, path : String) -> String raise ConfigError {
  match json {
    String(value) => value
    _ => raise ConfigError::Invalid("\{path}: expected a string")
  }
}

///|
/// Decode a required boolean.
fn expect_bool(json : @json.Json, path : String) -> Bool raise ConfigError {
  match json {
    True => true
    False => false
    _ => raise ConfigError::Invalid("\{path}: expected a boolean")
  }
}

///|
/// Decode a required array.
fn expect_array(
  json : @json.Json,
  path : String,
) -> Array[@json.Json] raise ConfigError {
  match json {
    Array(values) => values
    _ => raise ConfigError::Invalid("\{path}: expected an array")
  }
}

///|
/// Decode and expand a path value.
fn expect_path(
  json : @json.Json,
  path : String,
  env : Map[String, String],
) -> String raise ConfigError {
  let text = expect_string(json, path)
  try expand_path(text, env) catch {
    err => raise ConfigError::Invalid("\{path}: \{err.message()}")
  } noraise {
    value => value
  }
}

///|
/// Parse `any`, `file`, or `folder`.
fn parse_kind(
  json : @json.Json,
  path : String,
) -> @query.KindFilter raise ConfigError {
  let text = expect_string(json, path)
  match text {
    "any" => @query.AnyKind
    "file" | "files" => @query.FilesOnly
    "folder" | "folders" => @query.FoldersOnly
    _ =>
      raise ConfigError::Invalid(
        "\{path}: expected any, file, or folder, got '\{text}'",
      )
  }
}

///|
/// Parse a visibility filter used by macro flags.
fn parse_visibility(
  json : @json.Json,
  path : String,
) -> @query.VisibilityFilter raise ConfigError {
  let text = expect_string(json, path)
  match text {
    "any" => @query.AnyVisibility
    "hidden" => @query.HiddenOnly
    "visible" | "nohidden" => @query.VisibleOnly
    _ =>
      raise ConfigError::Invalid(
        "\{path}: expected any, hidden, or visible, got '\{text}'",
      )
  }
}

///|
/// Parse an exclusion interpretation.
fn parse_exclude_kind(
  json : @json.Json,
  path : String,
) -> @index.ExcludeKind raise ConfigError {
  let text = expect_string(json, path)
  match text {
    "fixed" => @index.Fixed
    "glob" => @index.Glob
    "regex" => @index.Regex
    _ =>
      raise ConfigError::Invalid(
        "\{path}: expected fixed, glob, or regex, got '\{text}'",
      )
  }
}

///|
/// Parse an exclusion scope.
fn parse_exclude_scope(
  json : @json.Json,
  path : String,
) -> @index.ExcludeScope raise ConfigError {
  let text = expect_string(json, path)
  match text {
    "full_path" => @index.FullPath
    "basename" => @index.Basename
    _ =>
      raise ConfigError::Invalid(
        "\{path}: expected full_path or basename, got '\{text}'",
      )
  }
}

///|
/// Parse an exclusion target.
fn parse_exclude_target(
  json : @json.Json,
  path : String,
) -> @index.ExcludeTarget raise ConfigError {
  let text = expect_string(json, path)
  match text {
    "both" => @index.Both
    "files" => @index.Files
    "folders" => @index.Folders
    _ =>
      raise ConfigError::Invalid(
        "\{path}: expected both, files, or folders, got '\{text}'",
      )
  }
}

///|
/// Parse the unreadable-directory policy.
fn parse_unreadable_policy(
  json : @json.Json,
  path : String,
) -> @index.UnreadableDirectoryPolicy raise ConfigError {
  let text = expect_string(json, path)
  match text {
    "continue" => @index.Continue
    "fatal" => @index.Fatal
    _ =>
      raise ConfigError::Invalid(
        "\{path}: expected continue or fatal, got '\{text}'",
      )
  }
}

///|
/// Parse the configured roots.
fn parse_roots(
  json : @json.Json,
  env : Map[String, String],
) -> Array[RootConfig] raise ConfigError {
  let values = expect_array(json, "roots")
  let roots : Array[RootConfig] = []
  for index, value in values {
    let path = "roots[\{index}]"
    let object = expect_object(value, path)
    check_fields(object, ["path", "one_file_system"], path)
    let root_path = match object.get("path") {
      Some(value) => expect_path(value, "\{path}.path", env)
      None => raise ConfigError::Invalid("\{path}.path: missing required field")
    }
    let one_file_system = match object.get("one_file_system") {
      Some(value) => Some(expect_bool(value, "\{path}.one_file_system"))
      None => None
    }
    roots.push(RootConfig::new(path=root_path, one_file_system~))
  }
  roots
}

///|
/// Parse configured exclusion rules.
fn parse_excludes(
  json : @json.Json,
  default_scope : @index.ExcludeScope,
  default_target : @index.ExcludeTarget,
) -> Array[ExcludeConfig] raise ConfigError {
  let values = expect_array(json, "excludes")
  let excludes : Array[ExcludeConfig] = []
  for index, value in values {
    let path = "excludes[\{index}]"
    let object = expect_object(value, path)
    check_fields(object, ["pattern", "kind", "scope", "target", "active"], path)
    let pattern = match object.get("pattern") {
      Some(value) => expect_string(value, "\{path}.pattern")
      None =>
        raise ConfigError::Invalid("\{path}.pattern: missing required field")
    }
    if pattern.is_empty() {
      raise ConfigError::Invalid("\{path}.pattern: must not be empty")
    }
    let kind = match object.get("kind") {
      Some(value) => parse_exclude_kind(value, "\{path}.kind")
      None => @index.Glob
    }
    let scope = match object.get("scope") {
      Some(value) => parse_exclude_scope(value, "\{path}.scope")
      None => default_scope
    }
    let target = match object.get("target") {
      Some(value) => parse_exclude_target(value, "\{path}.target")
      None => default_target
    }
    let active = match object.get("active") {
      Some(value) => expect_bool(value, "\{path}.active")
      None => true
    }
    try
      @index.ExcludeRule::new(kind~, pattern~, scope~, target~, active~)
    catch {
      err => raise ConfigError::Invalid("\{path}: \{err.message()}")
    } noraise {
      _ => ()
    }
    excludes.push(ExcludeConfig::new(pattern~, kind~, scope~, target~, active~))
  }
  excludes
}

///|
/// Parse flags stored alongside a macro query.
fn parse_macro_flags(
  json : @json.Json,
  path : String,
) -> @query.Flags raise ConfigError {
  let object = expect_object(json, path)
  check_fields(
    object,
    ["case_sensitive", "exact", "search_path", "regex", "kind", "visibility"],
    path,
  )
  let mut flags = @query.Flags::new()
  match object.get("case_sensitive") {
    Some(value) =>
      flags = flags.with_case_sensitive(
        expect_bool(value, "\{path}.case_sensitive"),
      )
    None => ()
  }
  match object.get("exact") {
    Some(value) => flags = flags.with_exact(expect_bool(value, "\{path}.exact"))
    None => ()
  }
  match object.get("search_path") {
    Some(value) =>
      flags = flags.with_search_path(expect_bool(value, "\{path}.search_path"))
    None => ()
  }
  match object.get("regex") {
    Some(value) => flags = flags.with_regex(expect_bool(value, "\{path}.regex"))
    None => ()
  }
  match object.get("kind") {
    Some(value) => flags = flags.with_kind(parse_kind(value, "\{path}.kind"))
    None => ()
  }
  match object.get("visibility") {
    Some(value) =>
      flags = flags.with_visibility(
        parse_visibility(value, "\{path}.visibility"),
      )
    None => ()
  }
  flags
}

///|
/// Macro names are the text before `:` in a query. Restrict them to a portable
/// identifier spelling so every configured name can actually be typed.
fn valid_macro_name(name : String) -> Bool {
  if name.is_empty() {
    return false
  }
  for char in name.iter() {
    if !((char >= 'a' && char <= 'z') ||
      (char >= 'A' && char <= 'Z') ||
      (char >= '0' && char <= '9') ||
      char == '_' ||
      char == '-') {
      return false
    }
  }
  true
}

///|
/// Parse user macros. A string is shorthand for `{ "query": "..." }`; the object
/// form can additionally provide independent query flags.
fn parse_macros(json : @json.Json) -> @query.Macros raise ConfigError {
  let object = expect_object(json, "macros")
  let names : Array[String] = []
  for name, _ in object {
    names.push(name)
  }
  names.sort()
  let macros = @query.Macros::new()
  for name in names {
    let value = object.get(name).unwrap()
    if !valid_macro_name(name) {
      raise ConfigError::Invalid("macros.\{name}: invalid macro name")
    }
    if macros.get(name) is Some(_) {
      raise ConfigError::Invalid(
        "macros.\{name}: duplicate macro name (ASCII case-insensitive)",
      )
    }
    let path = "macros.\{name}"
    let (query, flags) = match value {
      String(query) => (query, @query.Flags::new())
      Object(_) => {
        let entry = expect_object(value, path)
        check_fields(entry, ["query", "flags"], path)
        let query = match entry.get("query") {
          Some(value) => expect_string(value, "\{path}.query")
          None =>
            raise ConfigError::Invalid("\{path}.query: missing required field")
        }
        let flags = match entry.get("flags") {
          Some(value) => parse_macro_flags(value, "\{path}.flags")
          None => @query.Flags::new()
        }
        (query, flags)
      }
      _ => raise ConfigError::Invalid("\{path}: expected a string or object")
    }
    macros.set(@query.Macro::new(name~, query~, flags~))
  }
  macros
}

///|
/// Parse `search` defaults.
fn parse_search(json : @json.Json) -> SearchConfig raise ConfigError {
  let object = expect_object(json, "search")
  check_fields(
    object,
    [
      "sort", "limit", "reverse", "folders_first", "type", "case_sensitive", "exact",
      "search_path", "regex",
    ],
    "search",
  )
  let mut search = SearchConfig::new()
  match object.get("sort") {
    Some(value) => {
      let sort = expect_string(value, "search.sort")
      match sort {
        "name" | "path" | "size" | "mtime" | "ext" | "type" =>
          search = { ..search, sort, }
        _ =>
          raise ConfigError::Invalid(
            "search.sort: expected name, path, size, mtime, ext, or type, got '\{sort}'",
          )
      }
    }
    None => ()
  }
  match object.get("limit") {
    Some(value) => {
      let limit = match value {
        Number(number, ..) if number >= 0.0 &&
          number <= 2147483647.0 &&
          number == number.floor() => number.to_int()
        _ =>
          raise ConfigError::Invalid(
            "search.limit: expected a non-negative 32-bit integer",
          )
      }
      search = { ..search, limit, }
    }
    None => ()
  }
  match object.get("reverse") {
    Some(value) =>
      search = { ..search, reverse: expect_bool(value, "search.reverse"), }
    None => ()
  }
  match object.get("folders_first") {
    Some(value) =>
      search = {
        ..search,
        folders_first: expect_bool(value, "search.folders_first"),
      }
    None => ()
  }
  match object.get("type") {
    Some(value) =>
      search = { ..search, kind: parse_kind(value, "search.type"), }
    None => ()
  }
  match object.get("case_sensitive") {
    Some(value) =>
      search = {
        ..search,
        case_sensitive: expect_bool(value, "search.case_sensitive"),
      }
    None => ()
  }
  match object.get("exact") {
    Some(value) =>
      search = { ..search, exact: expect_bool(value, "search.exact"), }
    None => ()
  }
  match object.get("search_path") {
    Some(value) =>
      search = {
        ..search,
        search_path: expect_bool(value, "search.search_path"),
      }
    None => ()
  }
  match object.get("regex") {
    Some(value) =>
      search = { ..search, regex: expect_bool(value, "search.regex"), }
    None => ()
  }
  search
}

///|
/// Parse a comma-separated fast-field list represented as a JSON array.
fn parse_fast_fields(
  json : @json.Json,
  path : String,
) -> Array[@index.RangeField] raise ConfigError {
  let values = expect_array(json, path)
  let fields : Array[@index.RangeField] = []
  for index, value in values {
    let field_path = "\{path}[\{index}]"
    let name = expect_string(value, field_path)
    match @index.RangeField::from_name(name) {
      Some(field) => fields.push(field)
      None =>
        raise ConfigError::Invalid(
          "\{field_path}: unknown range field '\{name}'",
        )
    }
  }
  fields
}

///|
/// Parse either `"engine": "bitmap"` or the index-oriented object form from the
/// migration plan: `{ "name": "bitmap", "trigram": true, "fast_fields": [...] }`.
fn parse_engine(
  json : @json.Json?,
) -> (String?, Array[@index.RangeField]?, Bool?) raise ConfigError {
  match json {
    None => (None, None, None)
    Some(String(name)) =>
      match name {
        "scan" | "bitmap" => (Some(name), None, None)
        _ =>
          raise ConfigError::Invalid(
            "engine: expected scan or bitmap, got '\{name}'",
          )
      }
    Some(Object(object)) => {
      check_fields(object, ["name", "trigram", "fast_fields"], "engine")
      let name = match object.get("name") {
        Some(value) => {
          let text = expect_string(value, "engine.name")
          match text {
            "scan" | "bitmap" => Some(text)
            _ =>
              raise ConfigError::Invalid(
                "engine.name: expected scan or bitmap, got '\{text}'",
              )
          }
        }
        None => None
      }
      let trigram = match object.get("trigram") {
        Some(value) => Some(expect_bool(value, "engine.trigram"))
        None => None
      }
      let fast_fields = match object.get("fast_fields") {
        Some(value) => Some(parse_fast_fields(value, "engine.fast_fields"))
        None => None
      }
      (name, fast_fields, trigram)
    }
    Some(_) => raise ConfigError::Invalid("engine: expected a string or object")
  }
}

///|
/// Parse and validate one configuration document.
pub fn parse(
  input : StringView,
  env~ : Map[String, String] = Map([]),
) -> Config raise ConfigError {
  let json = try
    @json.parse(input, max_nesting_depth=64, reject_duplicate_keys=true)
  catch {
    err => raise ConfigError::Invalid("invalid JSON: \{err}")
  } noraise {
    value => value
  }
  let object = expect_object(json, "configuration")
  check_fields(
    object,
    [
      "database", "roots", "exclude_hidden", "exclude_scope", "exclude_target", "excludes",
      "macros", "search", "engine", "fast_fields", "trigram", "one_file_system",
      "allow_nested_roots", "default_excludes", "unreadable_directories",
    ],
    "",
  )
  let database = match object.get("database") {
    Some(value) => Some(expect_path(value, "database", env))
    None => None
  }
  let roots = match object.get("roots") {
    Some(value) => parse_roots(value, env)
    None => []
  }
  let exclude_hidden = match object.get("exclude_hidden") {
    Some(value) => expect_bool(value, "exclude_hidden")
    None => false
  }
  let exclude_scope = match object.get("exclude_scope") {
    Some(value) => parse_exclude_scope(value, "exclude_scope")
    None => @index.FullPath
  }
  let exclude_target = match object.get("exclude_target") {
    Some(value) => parse_exclude_target(value, "exclude_target")
    None => @index.Both
  }
  let excludes = match object.get("excludes") {
    Some(value) => parse_excludes(value, exclude_scope, exclude_target)
    None => []
  }
  let macros = match object.get("macros") {
    Some(value) => parse_macros(value)
    None => @query.Macros::new()
  }
  let search = match object.get("search") {
    Some(value) => parse_search(value)
    None => SearchConfig::new()
  }
  let (engine, nested_fast_fields, nested_trigram) = parse_engine(
    object.get("engine"),
  )
  let fast_fields = match object.get("fast_fields") {
    Some(value) => Some(parse_fast_fields(value, "fast_fields"))
    None => nested_fast_fields
  }
  let trigram = match object.get("trigram") {
    Some(value) => Some(expect_bool(value, "trigram"))
    None => nested_trigram
  }
  let one_file_system = match object.get("one_file_system") {
    Some(value) => Some(expect_bool(value, "one_file_system"))
    None => None
  }
  let allow_nested_roots = match object.get("allow_nested_roots") {
    Some(value) => Some(expect_bool(value, "allow_nested_roots"))
    None => None
  }
  let default_excludes = match object.get("default_excludes") {
    Some(value) => Some(expect_bool(value, "default_excludes"))
    None => None
  }
  let unreadable_directories = match object.get("unreadable_directories") {
    Some(value) => parse_unreadable_policy(value, "unreadable_directories")
    None => @index.Continue
  }
  {
    database,
    roots,
    exclude_hidden,
    excludes,
    exclude_scope,
    exclude_target,
    macros,
    search,
    engine,
    fast_fields,
    trigram,
    one_file_system,
    allow_nested_roots,
    default_excludes,
    unreadable_directories,
  }
}
