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
) -> Bytes {
  let hits = paths.map(fn(path) { entry_at_path(store, path) })
  @exec.format_hits(store, hits, options).bytes
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
    b"/root/docs/report.pdf\n/root/docs",
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
    b"report.pdf\ndocs",
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
    b"/root/docs/report.pdf\x00/root/docs\x00",
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
    b"{\"path\":\"/root/docs/report.pdf\",\"name\":\"report.pdf\",\"size\":1000,\"mtime\":600,\"ext\":\"pdf\",\"type\":\"doc\",\"kind\":\"file\"}",
  )
  assert_eq(
    formatted(
      store,
      ["/root/docs"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    b"{\"path\":\"/root/docs\",\"name\":\"docs\",\"size\":1500,\"mtime\":300,\"ext\":\"\",\"type\":\"folder\",\"kind\":\"folder\"}",
  )
  assert_eq(
    formatted(store, ["/root/zzz"], @exec.FormatOptions::new(format=@exec.Json)),
    b"{\"path\":\"/root/zzz\",\"name\":\"zzz\",\"size\":300,\"mtime\":1000,\"ext\":\"\",\"type\":\"other\",\"kind\":\"file\"}",
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
    b"/root/docs/report.pdf|report.pdf|/root/docs|1000|600|pdf|doc|file",
  )
  assert_eq(
    formatted(store, ["/root/docs"], options),
    b"/root/docs|docs|/root|1500|300||folder|folder",
  )
  assert_eq(
    formatted(store, ["/root/zzz"], options),
    b"/root/zzz|zzz|/root|300|1000||other|file",
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
    b"report.pdf\tpdf\n",
  )
  let nul = template_of("a\\0b")
  assert_eq(
    formatted(
      store,
      ["/root/zzz"],
      @exec.FormatOptions::new(format=@exec.Template(nul)),
    ),
    b"a\x00b",
  )
  let literal_backslash = template_of("a\\qb\\\\c")
  assert_eq(
    formatted(
      store,
      ["/root/zzz"],
      @exec.FormatOptions::new(format=@exec.Template(literal_backslash)),
    ),
    b"a\\qb\\c",
  )
}

///|
test "relative paths strip the base and one separator" {
  let store = order_store() catch { err => abort(err.message()) }
  let options = @exec.FormatOptions::new(relative_to=Some(b"/root"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf", "/root/docs", "/root"], options),
    b"docs/report.pdf\ndocs\n.",
  )
  let slash = @exec.FormatOptions::new(relative_to=Some(b"/"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf", "/root"], slash),
    b"root/docs/report.pdf\nroot",
  )
  let trailing = @exec.FormatOptions::new(relative_to=Some(b"/root/"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], trailing),
    b"docs/report.pdf",
  )
  let outside = @exec.FormatOptions::new(relative_to=Some(b"/elsewhere"))
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], outside),
    b"/root/docs/report.pdf",
  )
  let json = @exec.FormatOptions::new(
    format=@exec.Json,
    relative_to=Some(b"/root"),
  )
  assert_eq(
    formatted(store, ["/root/docs/report.pdf"], json),
    b"{\"path\":\"docs/report.pdf\",\"name\":\"report.pdf\",\"size\":1000,\"mtime\":600,\"ext\":\"pdf\",\"type\":\"doc\",\"kind\":\"file\"}",
  )
}

///|
test "json escapes quotes, backslashes, and control characters" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/root", false, 0L)
  ignore(builder.add_file(root, b"a\"b\\c", 1L, 0L))
  ignore(builder.add_file(root, b"tab\x01name", 2L, 0L))
  let store = builder.finish(built_at=0L)
  assert_eq(
    formatted(
      store,
      ["/root/a\"b\\c"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    b"{\"path\":\"/root/a\\\"b\\\\c\",\"name\":\"a\\\"b\\\\c\",\"size\":1,\"mtime\":0,\"ext\":\"\",\"type\":\"other\",\"kind\":\"file\"}",
  )
  assert_eq(
    formatted(
      store,
      ["/root/tab\u{1}name"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    b"{\"path\":\"/root/tab\\u0001name\",\"name\":\"tab\\u0001name\",\"size\":2,\"mtime\":0,\"ext\":\"\",\"type\":\"other\",\"kind\":\"file\"}",
  )
}

///|
test "json keeps non-BMP characters intact" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/root", false, 0L)
  ignore(builder.add_file(root, b"x🤣.txt", 1L, 0L))
  let store = builder.finish(built_at=0L)
  assert_eq(
    formatted(
      store,
      ["/root/x🤣.txt"],
      @exec.FormatOptions::new(format=@exec.Json),
    ),
    b"{\"path\":\"/root/x🤣.txt\",\"name\":\"x🤣.txt\",\"size\":1,\"mtime\":0,\"ext\":\"txt\",\"type\":\"doc\",\"kind\":\"file\"}",
  )
}

///|
test "ext and type fold case and folders stay extensionless" {
  let store = order_store() catch { err => abort(err.message()) }
  let template = template_of("{ext}|{type}")
  let options = @exec.FormatOptions::new(format=@exec.Template(template))
  assert_eq(formatted(store, ["/root/media/photo.JPG"], options), b"jpg|pic")
  assert_eq(formatted(store, ["/root/docs"], options), b"|folder")
  assert_eq(formatted(store, ["/root/zzz"], options), b"|other")
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
test "raw formats preserve distinct invalid UTF-8 names and NUL records" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/raw", false, 0L)
  ignore(builder.add_file(root, b"bad-\xff", 1L, 0L))
  ignore(builder.add_file(root, b"bad-\xfe", 2L, 0L))
  let store = builder.finish(built_at=0L)
  let hits = [
    @core.EntryRef::new(@core.File, 0),
    @core.EntryRef::new(@core.File, 1),
  ]
  assert_eq(
    @exec.format_hits(store, hits, @exec.FormatOptions::new()).bytes,
    b"/raw/bad-\xfe\n/raw/bad-\xff",
  )
  assert_eq(
    @exec.format_hits(store, hits, @exec.FormatOptions::new(format=@exec.Names)).bytes,
    b"bad-\xfe\nbad-\xff",
  )
  let template = template_of("{path}|{name}")
  assert_eq(
    @exec.format_hits(
      store,
      hits,
      @exec.FormatOptions::new(format=@exec.Template(template)),
    ).bytes,
    b"/raw/bad-\xfe|bad-\xfe\n/raw/bad-\xff|bad-\xff",
  )
  let nul = @exec.format_hits(
    store,
    hits,
    @exec.FormatOptions::new(null_terminated=true),
  )
  assert_eq(nul.bytes, b"/raw/bad-\xfe\x00/raw/bad-\xff\x00")
  assert_eq(nul.stdout_bytes(), nul.bytes)
  assert_eq(
    @exec.format_hits(
      store,
      hits,
      @exec.FormatOptions::new(relative_to=Some(b"/raw")),
    ).stdout_bytes(),
    b"bad-\xfe\nbad-\xff\n",
  )
}

///|
test "JSON replaces invalid UTF-8 and reports one warning per record" {
  let builder = @index.Builder::new()
  let root = builder.add_root(b"/raw", false, 0L)
  ignore(builder.add_file(root, b"bad-\xff", 1L, 0L))
  ignore(builder.add_file(root, b"bad-\xfe", 2L, 0L))
  let store = builder.finish(built_at=0L)
  let hits = [
    @core.EntryRef::new(@core.File, 0),
    @core.EntryRef::new(@core.File, 1),
  ]
  let rendered = @exec.format_hits(
    store,
    hits,
    @exec.FormatOptions::new(format=@exec.Json),
  )
  assert_eq(rendered.invalid_utf8_records, 2)
  assert_eq(
    rendered.warning(),
    Some("warning: replaced invalid UTF-8 in 2 JSON record(s) with U+FFFD"),
  )
  let text = @utf8.decode(rendered.stdout_bytes()) catch {
    _ => abort("JSON output must be valid UTF-8")
  }
  assert_true(text.contains("bad-\u{FFFD}"))
  assert_false(text.contains("bad-\u{FFFD}\u{FFFD}"))
}

///|
test "formatting an empty match set is empty" {
  let store = order_store() catch { err => abort(err.message()) }
  let empty : Array[@core.EntryRef] = []
  assert_eq(
    @exec.format_hits(store, empty, @exec.FormatOptions::new()).bytes,
    b"",
  )
  assert_eq(
    @exec.format_hits(
      store,
      empty,
      @exec.FormatOptions::new(null_terminated=true),
    ).bytes,
    b"",
  )
}
