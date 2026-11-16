///|
/// Parse a template or abort the test.
fn template_of(text : String) -> @exec.FormatTemplate {
  match @exec.FormatTemplate::parse(text) {
    Ok(template) => template
    Err(message) => abort(message)
  }
}

///|
/// Resolve one fixture entry by its full path.
fn entry_at_path(store : @core.Store, path : String) -> @core.EntryRef {
  for entry in store.entries_in_order() {
    if @utf8.decode_lossy(store.entry_path(entry)) == path {
      return entry
    }
  }
  abort("missing fixture path: \{path}")
}

///|
/// Format one or more entries with the given options.
fn formatted(
  store : @core.Store,
  paths : Array[String],
  options : @exec.FormatOptions,
) -> String {
  let hits = paths.map(fn(path) { entry_at_path(store, path) })
  @exec.format_hits(store, hits, options)
}

///|
test "default format prints full paths separated by newlines" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(
    formatted(
      store,
      ["/root/docs/report.pdf", "/root/docs"],
      @exec.FormatOptions::new(),
    ),
    "/root/docs/report.pdf\n/root/docs",
  )
}

///|
test "basename format prints only names" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(
    formatted(
      store,
      ["/root/docs/report.pdf", "/root/docs"],
      @exec.FormatOptions::new(format=@exec.Names),
    ),
    "report.pdf\ndocs",
  )
}

///|
test "null terminates every record including the last" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(
    formatted(
      store,
      ["/root/docs/report.pdf", "/root/docs"],
      @exec.FormatOptions::new(null_terminated=true),
    ),
    "/root/docs/report.pdf\u{0}/root/docs\u{0}",
  )
}

///|
test "json lines carry the stable field order" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(
    formatted(
      store,
      ["/root/docs/report.pdf"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    "{\"path\":\"/root/docs/report.pdf\",\"name\":\"report.pdf\",\"size\":1000,\"mtime\":600,\"ext\":\"pdf\",\"type\":\"doc\",\"kind\":\"file\"}",
  )
  assert_eq(
    formatted(
      store,
      ["/root/docs"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    "{\"path\":\"/root/docs\",\"name\":\"docs\",\"size\":1500,\"mtime\":300,\"ext\":\"\",\"type\":\"folder\",\"kind\":\"folder\"}",
  )
  assert_eq(
    formatted(store, ["/root/zzz"], @exec.FormatOptions::new(format=@exec.Json)),
    "{\"path\":\"/root/zzz\",\"name\":\"zzz\",\"size\":300,\"mtime\":1000,\"ext\":\"\",\"type\":\"other\",\"kind\":\"file\"}",
  )
}

///|
test "format templates render every placeholder" {
  let store = order_store() catch { err => abort(err.message()) }
  let template = template_of(
    "{path}|{name}|{dir}|{size}|{mtime}|{ext}|{type}|{kind}",
  )
  let options = @exec.FormatOptions::new(format=@exec.Template(template))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], options),
    "/root/docs/report.pdf|report.pdf|/root/docs|1000|600|pdf|doc|file",
  )
  assert_eq(
    formatted(store, ["/root/docs"], options),
    "/root/docs|docs|/root|1500|300||folder|folder",
  )
  assert_eq(
    formatted(store, ["/root/zzz"], options),
    "/root/zzz|zzz|/root|300|1000||other|file",
  )
}

///|
test "format templates translate escapes" {
  let store = order_store() catch { err => abort(err.message()) }
  let template = template_of("{name}\\t{ext}\\n")
  assert_eq(
    formatted(
      store,
      ["/root/docs/report.pdf"],
      @exec.FormatOptions::new(format=@exec.Template(template)),
    ),
    "report.pdf\tpdf\n",
  )
  let nul = template_of("a\\0b")
  assert_eq(
    formatted(
      store,
      ["/root/zzz"],
      @exec.FormatOptions::new(format=@exec.Template(nul)),
    ),
    "a\u{0}b",
  )
  let literal_backslash = template_of("a\\qb\\\\c")
  assert_eq(
    formatted(
      store,
      ["/root/zzz"],
      @exec.FormatOptions::new(format=@exec.Template(literal_backslash)),
    ),
    "a\\qb\\c",
  )
}

///|
test "relative paths strip the base and one separator" {
  let store = order_store() catch { err => abort(err.message()) }
  let options = @exec.FormatOptions::new(relative_to=Some("/root"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf", "/root/docs", "/root"], options),
    "docs/report.pdf\ndocs\n.",
  )
  let slash = @exec.FormatOptions::new(relative_to=Some("/"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf", "/root"], slash),
    "root/docs/report.pdf\nroot",
  )
  let trailing = @exec.FormatOptions::new(relative_to=Some("/root/"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], trailing),
    "docs/report.pdf",
  )
  let outside = @exec.FormatOptions::new(relative_to=Some("/elsewhere"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], outside),
    "/root/docs/report.pdf",
  )
  let json = @exec.FormatOptions::new(
    format=@exec.Json,
    relative_to=Some("/root"),
  )
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], json),
    "{\"path\":\"docs/report.pdf\",\"name\":\"report.pdf\",\"size\":1000,\"mtime\":600,\"ext\":\"pdf\",\"type\":\"doc\",\"kind\":\"file\"}",
  )
}

///|
test "json escapes quotes, backslashes, and control characters" {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 0L)
  ignore(builder.add_file(root, "a\"b\\c", 1L, 0L))
  ignore(builder.add_file(root, "tab\u{1}name", 2L, 0L))
  let store = builder.finish(built_at=0L)
  assert_eq(
    formatted(
      store,
      ["/root/a\"b\\c"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    "{\"path\":\"/root/a\\\"b\\\\c\",\"name\":\"a\\\"b\\\\c\",\"size\":1,\"mtime\":0,\"ext\":\"\",\"type\":\"other\",\"kind\":\"file\"}",
  )
  assert_eq(
    formatted(
      store,
      ["/root/tab\u{1}name"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    "{\"path\":\"/root/tab\\u0001name\",\"name\":\"tab\\u0001name\",\"size\":2,\"mtime\":0,\"ext\":\"\",\"type\":\"other\",\"kind\":\"file\"}",
  )
}

///|
test "json keeps non-BMP characters intact" {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 0L)
  ignore(builder.add_file(root, "x🤣.txt", 1L, 0L))
  let store = builder.finish(built_at=0L)
  assert_eq(
    formatted(
      store,
      ["/root/x🤣.txt"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    "{\"path\":\"/root/x🤣.txt\",\"name\":\"x🤣.txt\",\"size\":1,\"mtime\":0,\"ext\":\"txt\",\"type\":\"doc\",\"kind\":\"file\"}",
  )
}

///|
test "ext and type fold case and folders stay extensionless" {
  let store = order_store() catch { err => abort(err.message()) }
  let template = template_of("{ext}|{type}")
  let options = @exec.FormatOptions::new(format=@exec.Template(template))
  assert_eq(formatted(store, ["/root/media/photo.JPG"], options), "jpg|pic")
  assert_eq(formatted(store, ["/root/docs"], options), "|folder")
  assert_eq(formatted(store, ["/root/zzz"], options), "|other")
}

///|
test "format template errors are reported before rendering" {
  match @exec.FormatTemplate::parse("{bogus}") {
    Err(message) => assert_true(message.contains("unknown format placeholder"))
    Ok(_) => abort("expected an unknown placeholder error")
  }
  match @exec.FormatTemplate::parse("{path") {
    Err(message) => assert_true(message.contains("unterminated"))
    Ok(_) => abort("expected an unterminated placeholder error")
  }
  match @exec.FormatTemplate::parse("{path}") {
    Ok(_) => ()
    Err(message) => abort("expected a valid template, got: \{message}")
  }
}

///|
test "formatting an empty match set is empty" {
  let store = order_store() catch { err => abort(err.message()) }
  let empty : Array[@core.EntryRef] = []
  assert_eq(@exec.format_hits(store, empty, @exec.FormatOptions::new()), "")
  assert_eq(
    @exec.format_hits(
      store,
      empty,
      @exec.FormatOptions::new(null_terminated=true),
    ),
    "",
  )
}
