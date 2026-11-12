///|
/// Parse a built-in macro or visibility query and describe the tree.
fn builtin_parsed(input : String) -> String {
  @query.parse(input).describe() catch {
    err => abort(err.message())
  }
}

///|
test "built-in category macros become type terms" {
  assert_eq(builtin_parsed("pic:"), "(type pic)")
  assert_eq(builtin_parsed("APP:"), "(type app)")
  assert_eq(builtin_parsed("archive:"), "(type archive)")
  assert_eq(builtin_parsed("audio:"), "(type audio)")
  assert_eq(builtin_parsed("video:"), "(type video)")
  assert_eq(builtin_parsed("doc:"), "(type doc)")
  assert_eq(builtin_parsed("doc: report"), "(and (type doc) (name \"report\"))")
  assert_eq(builtin_parsed("(pic: OR video:)"), "(or (type pic) (type video))")
  // A kind modifier written before the macro still applies to it.
  assert_eq(builtin_parsed("file:pic:"), "(type pic kind=file)")
}

///|
test "user macros take precedence over built-in categories" {
  let table = @query.Macros::from_array([
    @query.Macro::new(name="pic", query="ext:raw"),
  ])
  let described = @query.parse("pic:", macros=table).describe() catch {
    err => abort(err.message())
  }
  assert_eq(described, "(ext \"raw\")")
}

///|
test "visibility modifiers scope to one term or group" {
  assert_eq(builtin_parsed("hidden:"), "(visibility hidden)")
  assert_eq(builtin_parsed("hidden:report"), "(name \"report\" hidden)")
  assert_eq(builtin_parsed("hidden: report"), "(name \"report\" hidden)")
  assert_eq(builtin_parsed("nohidden:"), "(visibility visible)")
  assert_eq(builtin_parsed("visible:report"), "(name \"report\" visible)")
  assert_eq(
    builtin_parsed("hidden:(a OR b)"),
    "(or (name \"a\" hidden) (name \"b\" hidden))",
  )
  assert_eq(
    builtin_parsed("hidden:(a OR b) c"),
    "(and (or (name \"a\" hidden) (name \"b\" hidden)) (name \"c\"))",
  )
  assert_eq(builtin_parsed("hidden:doc:"), "(type doc hidden)")
}

///|
test "kind and visibility modifiers chain in either order" {
  assert_eq(builtin_parsed("file:hidden:"), "(visibility hidden kind=file)")
  assert_eq(builtin_parsed("hidden:file:"), "(kind file hidden)")
  assert_eq(builtin_parsed("hidden:nohidden:"), "(visibility visible)")
  assert_eq(builtin_parsed("nohidden:hidden:a"), "(name \"a\" hidden)")
}
