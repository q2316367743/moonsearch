///|
/// Parse a document that must fail and return its stable message.
fn parse_error(input : String, env~ : Map[String, String] = Map([])) -> String {
  try @config.parse(input, env~) catch {
    err => err.message()
  } noraise {
    _ => abort("expected the configuration to fail")
  }
}

///|
/// Expand a path that must succeed.
fn expanded(path : String, env : Map[String, String]) -> String {
  try @config.expand_path(path, env) catch {
    err => abort(err.message())
  } noraise {
    value => value
  }
}

///|
/// Expand a path that must fail and return its message.
fn expansion_error(path : String, env : Map[String, String]) -> String {
  try @config.expand_path(path, env) catch {
    err => err.message()
  } noraise {
    _ => abort("expected path expansion to fail")
  }
}

///|
test "configuration parses every supported section" {
  let env = Map([
    ("HOME", "/home/tester"),
    ("XDG_DATA_HOME", "/data"),
    ("XDG_CONFIG_HOME", "/config"),
  ])
  let input =
    #|{
    #|  "database": "$XDG_DATA_HOME/moonsearch/index.msdb",
    #|  "roots": [{"path": "~/Documents", "one_file_system": true}],
    #|  "exclude_hidden": true,
    #|  "exclude_scope": "basename",
    #|  "exclude_target": "folders",
    #|  "excludes": [{"pattern": "node_modules", "kind": "glob"}],
    #|  "macros": {
    #|    "book": "ext:epub;pdf",
    #|    "code": {"query": "ext:rs;mbt", "flags": {"case_sensitive": true}}
    #|  },
    #|  "search": {"sort": "size", "limit": 7, "folders_first": true, "type": "file"},
    #|  "engine": "bitmap",
    #|  "fast_fields": ["size", "depth", "childfilecount"],
    #|  "trigram": false,
    #|  "one_file_system": false,
    #|  "allow_nested_roots": true,
    #|  "default_excludes": false,
    #|  "unreadable_directories": "fatal"
    #|}
  let config = try @config.parse(input, env~) catch {
    err => abort(err.message())
  } noraise {
    value => value
  }
  assert_eq(config.database, Some("/data/moonsearch/index.msdb"))
  assert_eq(config.roots[0].path, "/home/tester/Documents")
  assert_eq(config.roots[0].one_file_system, Some(true))
  assert_true(config.exclude_hidden)
  assert_true(config.excludes[0].kind is @index.Glob)
  assert_true(config.excludes[0].scope is @index.Basename)
  assert_true(config.excludes[0].target is @index.Folders)
  assert_eq(config.search.sort, "size")
  assert_eq(config.search.limit, 7)
  assert_true(config.search.folders_first)
  assert_true(config.search.kind is @query.FilesOnly)
  assert_eq(config.engine, Some("bitmap"))
  let fast_fields = @index.RangeFieldSet::of(config.fast_fields.unwrap())
  assert_true(fast_fields.contains(@index.RangeField::Depth))
  assert_true(fast_fields.contains(@index.RangeField::ChildFileCount))
  assert_eq(config.trigram, Some(false))
  assert_eq(config.one_file_system, Some(false))
  assert_eq(config.allow_nested_roots, Some(true))
  assert_eq(config.default_excludes, Some(false))
  assert_true(config.unreadable_directories is @index.Fatal)
  let book = try @query.parse("book:", macros=config.macros) catch {
    err => abort(err.message())
  } noraise {
    query => query.describe()
  }
  assert_eq(book, "(ext \"epub\" \"pdf\")")
  let code = try @query.parse("code:", macros=config.macros) catch {
    err => abort(err.message())
  } noraise {
    query => query.describe()
  }
  assert_eq(code, "(ext \"rs\" \"mbt\" case)")
}

///|
test "engine object form supplies index settings" {
  let config = try
    @config.parse(
      "{\"engine\":{\"name\":\"bitmap\",\"trigram\":true,\"fast_fields\":[\"mtime\",\"parent\"]}}",
    )
  catch {
    err => abort(err.message())
  } noraise {
    value => value
  }
  assert_eq(config.engine, Some("bitmap"))
  assert_eq(config.trigram, Some(true))
  assert_eq(config.fast_fields.unwrap().length(), 2)
}

///|
test "top-level index settings override engine object defaults" {
  let config = try
    @config.parse(
      "{\"engine\":{\"trigram\":true,\"fast_fields\":[\"size\"]},\"trigram\":false,\"fast_fields\":[]}",
    )
  catch {
    err => abort(err.message())
  } noraise {
    value => value
  }
  assert_eq(config.trigram, Some(false))
  assert_true(config.fast_fields.unwrap().is_empty())
}

///|
test "unknown fields are rejected at every level" {
  assert_true(parse_error("{\"bogus\":1}").contains("unknown field 'bogus'"))
  assert_true(
    parse_error("{\"search\":{\"bogus\":1}}").contains(
      "unknown field 'search.bogus'",
    ),
  )
  assert_true(
    parse_error("{\"macros\":{\"x\":{\"query\":\"a\",\"bogus\":1}}}").contains(
      "unknown field 'macros.x.bogus'",
    ),
  )
  assert_true(
    parse_error("{\"roots\":[{\"path\":\"/tmp\",\"bogus\":1}]}").contains(
      "unknown field 'roots[0].bogus'",
    ),
  )
}

///|
test "wrong JSON types and invalid enum values have stable errors" {
  assert_true(
    parse_error("{\"roots\":\"/tmp\"}").contains("roots: expected an array"),
  )
  assert_true(
    parse_error("{\"exclude_hidden\":\"yes\"}").contains(
      "exclude_hidden: expected a boolean",
    ),
  )
  assert_true(
    parse_error("{\"search\":{\"limit\":-1}}").contains(
      "search.limit: expected a non-negative 32-bit integer",
    ),
  )
  assert_true(
    parse_error("{\"engine\":\"other\"}").contains(
      "engine: expected scan or bitmap",
    ),
  )
  assert_true(
    parse_error("{\"unreadable_directories\":\"skip\"}").contains(
      "unreadable_directories: expected continue or fatal",
    ),
  )
  assert_true(
    parse_error("{\"fast_fields\":[\"size\",\"bogus\"]}").contains(
      "fast_fields[1]: unknown range field 'bogus'",
    ),
  )
}

///|
test "invalid regex excludes fail configuration parsing" {
  let message = parse_error(
    "{\"excludes\":[{\"pattern\":\"[\",\"kind\":\"regex\"}]}",
  )
  assert_true(message.contains("excludes[0]"))
  assert_true(message.contains("invalid regular expression"))
}

///|
test "duplicate JSON keys and case-insensitive macro names are rejected" {
  assert_true(
    parse_error("{\"engine\":\"scan\",\"engine\":\"bitmap\"}").contains(
      "Duplicate key",
    ),
  )
  assert_true(
    parse_error("{\"macros\":{\"Book\":\"ext:pdf\",\"book\":\"ext:epub\"}}").contains(
      "duplicate macro name",
    ),
  )
  assert_true(
    parse_error("{\"macros\":{\"bad:name\":\"ext:pdf\"}}").contains(
      "invalid macro name",
    ),
  )
}

///|
test "path expansion accepts only the documented forms" {
  let env = Map([
    ("HOME", "/home/u"),
    ("XDG_DATA_HOME", "/data"),
    ("XDG_CACHE_HOME", "/cache"),
    ("PATH", "/bin"),
  ])
  assert_eq(expanded("~", env), "/home/u")
  assert_eq(expanded("~/x", env), "/home/u/x")
  assert_eq(expanded("$HOME/x", env), "/home/u/x")
  assert_eq(expanded("${XDG_CACHE_HOME}/x", env), "/cache/x")
  assert_true(
    expansion_error("$PATH", env).contains("unsupported environment variable"),
  )
  assert_true(
    expansion_error("~other", env).contains("unsupported home expansion"),
  )
  assert_true(expansion_error("$XDG_MISSING/x", env).contains("not set"))
}

///|
test "default config path follows XDG and HOME" {
  assert_eq(
    @config.default_config_path(
      Map([("XDG_CONFIG_HOME", "/cfg"), ("HOME", "/home/u")]),
    ),
    Some("/cfg/moonsearch/config.json"),
  )
  assert_eq(
    @config.default_config_path(Map([("HOME", "/home/u")])),
    Some("/home/u/.config/moonsearch/config.json"),
  )
  assert_eq(
    @config.default_config_path(Map([("HOME", "/home/u/")])),
    Some("/home/u/.config/moonsearch/config.json"),
  )
  assert_eq(
    @config.default_config_path(
      Map([("HOME", ""), ("USERPROFILE", "C:/Users/u")]),
    ),
    Some("C:/Users/u/.config/moonsearch/config.json"),
  )
  assert_eq(@config.default_config_path(Map([])), None)
}

///|
async test "explicit config load rejects a missing file" {
  let dir = @fs.tmpdir(prefix="moonsearch-config-missing")
  let path = "\{dir}/missing.json"
  let message = try @config.load_explicit(path) catch {
    err => err.message()
  } noraise {
    _ => abort("expected a missing configuration error")
  }
  @fs.remove(dir, recursive=true)
  assert_true(message.contains("cannot read configuration"))
  assert_true(message.contains(path))
}

///|
async test "default config load is optional but validates an existing file" {
  let home = @fs.tmpdir(prefix="moonsearch-config-default")
  let env = Map([("XDG_CONFIG_HOME", "\{home}/cfg"), ("HOME", home)])
  let missing = try @config.load_default(env~) catch {
    err => abort(err.message())
  } noraise {
    value => value
  }
  assert_true(missing.roots.is_empty())
  let path = "\{home}/cfg/moonsearch/config.json"
  @fs.mkdir("\{home}/cfg/moonsearch", recursive=true)
  @fs.write_text(path, "{\"bogus\":true}")
  let message = try @config.load_default(env~) catch {
    err => err.message()
  } noraise {
    _ => abort("expected an invalid default configuration error")
  }
  @fs.remove(home, recursive=true)
  assert_true(message.contains("configuration"))
  assert_true(message.contains("unknown field 'bogus'"))
}

///|
#cfg(not(platform="windows"))
async test "default config access errors are not treated as missing files" {
  let home = @fs.tmpdir(prefix="moonsearch-config-access")
  let env = Map([("XDG_CONFIG_HOME", "\{home}/cfg"), ("HOME", home)])
  let path = "\{home}/cfg/moonsearch/config.json"
  @fs.mkdir("\{home}/cfg/moonsearch", recursive=true)
  @fs.symlink(target=path, path)
  let message = try @config.load_default(env~) catch {
    err => err.message()
  } noraise {
    _ => abort("expected a default configuration access error")
  }
  @fs.remove(home, recursive=true)
  assert_true(message.contains("cannot access configuration"))
  assert_true(message.contains(path))
}
