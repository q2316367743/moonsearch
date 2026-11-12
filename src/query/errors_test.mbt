///|
/// Lex an invalid query and return the error.
fn error_from_lex(input : String) -> @query.QueryError {
  try @query.lex(input) catch {
    err => err
  } noraise {
    _ => abort("expected the query to fail lexing")
  }
}

///|
/// Parse an invalid query and return the error.
fn error_from_parse(
  input : String,
  macros~ : @query.Macros = @query.Macros::new(),
) -> @query.QueryError {
  try @query.parse(input, macros~) catch {
    err => err
  } noraise {
    _ => abort("expected the query to fail parsing")
  }
}

///|
test "lex errors expose their position and message" {
  let err = error_from_lex("\"abc")
  assert_eq(err.position(), 0)
  assert_eq(err.message(), "query error at 0: unterminated quoted string")
}

///|
test "parse errors expose their position and message" {
  let err = error_from_parse("a )")
  assert_eq(err.position(), 2)
  assert_eq(err.message(), "query error at 2: unmatched ')'")
}

///|
test "bad values include the field and value text" {
  let err = error_from_parse("size:abc")
  assert_eq(err.position(), 5)
  assert_eq(
    err.message(),
    "query error at 5: size:abc: expected a size such as 1kb, >10mb, or 1kb..2mb",
  )
}

///|
test "macro errors expose their cycle and use-site positions" {
  let cycle = error_from_parse(
    "x a:",
    macros=@query.Macros::from_array([@query.Macro::new(name="a", query="a:")]),
  )
  // A cycle keeps the position where it was detected inside the macro text.
  assert_eq(cycle.position(), 0)
  assert_eq(cycle.message(), "query error at 0: macro 'a' expands to itself")

  let nested = error_from_parse(
    "x bad:",
    macros=@query.Macros::from_array([
      @query.Macro::new(name="bad", query="size:abc"),
    ]),
  )
  assert_eq(nested.position(), 2)
  assert_true(nested.message().contains("in macro 'bad'"))
  assert_true(nested.message().contains("query error at 5"))
}
