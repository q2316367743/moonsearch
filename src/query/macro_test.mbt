///|
/// Parse a query against a macro table and describe the result.
fn macro_parsed(input : String, macros : Array[@query.Macro]) -> String {
  let table = @query.Macros::from_array(macros)
  @query.parse(input, macros=table).describe() catch {
    err => abort(err.message())
  }
}

///|
/// Parse a query against a macro table and return the expected error.
fn macro_error(
  input : String,
  macros : Array[@query.Macro],
) -> @query.QueryError {
  let table = @query.Macros::from_array(macros)
  try @query.parse(input, macros=table) catch {
    err => err
  } noraise {
    _ => abort("expected the query to fail parsing")
  }
}

///|
test "a macro expands into its query" {
  let macros = [@query.Macro::new(name="book", query="ext:epub;pdf")]
  assert_eq(macro_parsed("book:", macros), "(ext \"epub\" \"pdf\")")
  assert_eq(
    macro_parsed("book: report", macros),
    "(and (ext \"epub\" \"pdf\") (name \"report\"))",
  )
  assert_eq(
    macro_parsed("book:report", macros),
    "(and (ext \"epub\" \"pdf\") (name \"report\"))",
  )
}

///|
test "macro names are ASCII case-insensitive" {
  let macros = [@query.Macro::new(name="Book", query="ext:epub")]
  assert_eq(macro_parsed("BOOK:", macros), "(ext \"epub\")")
  assert_eq(macro_parsed("book:", macros), "(ext \"epub\")")
}

///|
test "macros can reference other macros" {
  let macros = [
    @query.Macro::new(name="archive", query="ext:zip;tar"),
    @query.Macro::new(name="compressed", query="archive:"),
  ]
  assert_eq(macro_parsed("compressed:", macros), "(ext \"zip\" \"tar\")")
}

///|
test "a macro can expand to a boolean expression" {
  let macros = [@query.Macro::new(name="media", query="(ext:mp3 OR ext:mp4)")]
  assert_eq(macro_parsed("media:", macros), "(or (ext \"mp3\") (ext \"mp4\"))")
}

///|
test "an empty macro produces no term" {
  let macros = [@query.Macro::new(name="none", query="")]
  assert_eq(macro_parsed("none:", macros), "*")
  assert_eq(macro_parsed("none: foo", macros), "(name \"foo\")")
}

///|
test "macro flags apply to the macro's terms" {
  let macros = [
    @query.Macro::new(
      name="img",
      query="ext:png",
      flags=@query.Flags::new(case_sensitive=true),
    ),
  ]
  assert_eq(macro_parsed("img:", macros), "(ext \"png\" case)")
}

///|
test "macros take precedence over field functions" {
  let macros = [@query.Macro::new(name="size", query="ext:big")]
  assert_eq(macro_parsed("size:", macros), "(ext \"big\")")
}

///|
test "a later macro replaces an earlier one with the same name" {
  let macros = [
    @query.Macro::new(name="x", query="ext:old"),
    @query.Macro::new(name="x", query="ext:new"),
  ]
  assert_eq(macro_parsed("x:", macros), "(ext \"new\")")
}

///|
test "an empty macro table reports empty" {
  assert_true(@query.Macros::new().is_empty())
  let table = @query.Macros::from_array([
    @query.Macro::new(name="x", query="ext:a"),
  ])
  assert_false(table.is_empty())
}

///|
test "a direct macro cycle is reported" {
  let macros = [@query.Macro::new(name="a", query="a:")]
  match macro_error("a:", macros) {
    @query.MacroCycle(_, name) => assert_eq(name, "a")
    err => abort("expected a macro cycle, got \{err.message()}")
  }
}

///|
test "an indirect macro cycle is reported" {
  let macros = [
    @query.Macro::new(name="a", query="b:"),
    @query.Macro::new(name="b", query="a:"),
  ]
  match macro_error("a:", macros) {
    @query.MacroCycle(_, name) => assert_eq(name, "a")
    err => abort("expected a macro cycle, got \{err.message()}")
  }
}

///|
test "an error inside a macro is reported at the use site" {
  let macros = [@query.Macro::new(name="bad", query="size:abc")]
  match macro_error("bad:", macros) {
    @query.MacroError(pos, name, message) => {
      assert_eq(pos, 0)
      assert_eq(name, "bad")
      assert_true(message.contains("query error at 5"))
    }
    err => abort("expected a macro error, got \{err.message()}")
  }
}

///|
test "a macro that fails to lex is reported at the use site" {
  let macros = [@query.Macro::new(name="bad", query="\"unterminated")]
  match macro_error("x bad:", macros) {
    @query.MacroError(pos, name, message) => {
      assert_eq(pos, 2)
      assert_eq(name, "bad")
      assert_true(message.contains("unterminated"))
    }
    err => abort("expected a macro error, got \{err.message()}")
  }
}
