///|
/// Parse a query that must succeed and describe the resulting tree.
fn parsed(input : String) -> String {
  @query.parse(input).describe() catch {
    err => abort(err.message())
  }
}

///|
/// Parse with caller flags and describe the result.
fn parsed_with(input : String, flags : @query.Flags) -> String {
  @query.parse(input, flags~).describe() catch {
    err => abort(err.message())
  }
}

///|
/// Parse in compat mode and describe the result.
fn parsed_compat(input : String) -> String {
  @query.parse(input, compat=true).describe() catch {
    err => abort(err.message())
  }
}

///|
/// Parse a query that must fail and return the error.
fn parse_error(input : String) -> @query.QueryError {
  try @query.parse(input) catch {
    err => err
  } noraise {
    _ => abort("expected the query to fail parsing")
  }
}

///|
test "an empty query matches everything" {
  assert_eq(parsed(""), "*")
  assert_eq(parsed("   "), "*")
}

///|
test "a single word is a name term" {
  assert_eq(parsed("report"), "(name \"report\")")
  assert_eq(parsed("report.pdf"), "(name \"report.pdf\")")
}

///|
test "juxtaposition and AND are the same operator" {
  assert_eq(parsed("a b"), "(and (name \"a\") (name \"b\"))")
  assert_eq(parsed("a AND b"), "(and (name \"a\") (name \"b\"))")
  assert_eq(parsed("a && b"), "(and (name \"a\") (name \"b\"))")
}

///|
test "AND binds tighter than OR" {
  assert_eq(
    parsed("a b OR c"),
    "(or (and (name \"a\") (name \"b\")) (name \"c\"))",
  )
  assert_eq(
    parsed("a OR b c"),
    "(or (name \"a\") (and (name \"b\") (name \"c\")))",
  )
  assert_eq(
    parsed("a AND b OR c"),
    "(or (and (name \"a\") (name \"b\")) (name \"c\"))",
  )
  assert_eq(
    parsed("a OR b AND c"),
    "(or (name \"a\") (and (name \"b\") (name \"c\")))",
  )
}

///|
test "parentheses group subexpressions" {
  assert_eq(
    parsed("(a OR b) c"),
    "(and (or (name \"a\") (name \"b\")) (name \"c\"))",
  )
  assert_eq(parsed("()"), "*")
  assert_eq(parsed("a AND ()"), "(name \"a\")")
}

///|
test "NOT is prefix and binds tighter than AND" {
  assert_eq(parsed("NOT a"), "(not (name \"a\"))")
  assert_eq(parsed("!a"), "(not (name \"a\"))")
  assert_eq(parsed("NOT a b"), "(and (not (name \"a\")) (name \"b\"))")
  assert_eq(parsed("a NOT b"), "(and (name \"a\") (not (name \"b\")))")
  assert_eq(parsed("NOT (a OR b)"), "(not (or (name \"a\") (name \"b\")))")
}

///|
test "consecutive NOTs cancel in pairs" {
  assert_eq(parsed("NOT NOT a"), "(name \"a\")")
  assert_eq(parsed("!!!a"), "(not (name \"a\"))")
  assert_eq(parsed("a AND NOT NOT b"), "(and (name \"a\") (name \"b\"))")
}

///|
test "operators with no operand are ignored" {
  assert_eq(parsed("a AND"), "(name \"a\")")
  assert_eq(parsed("AND a"), "(name \"a\")")
  assert_eq(parsed("a OR"), "(name \"a\")")
  assert_eq(parsed("OR a"), "(name \"a\")")
  assert_eq(parsed("a OR OR b"), "(or (name \"a\") (name \"b\"))")
  assert_eq(parsed("a AND AND b"), "(and (name \"a\") (name \"b\"))")
  assert_eq(parsed("NOT"), "*")
  assert_eq(parsed("AND"), "*")
  assert_eq(parsed("(AND a)"), "(name \"a\")")
}

///|
test "a dangling operator before another operator is dropped" {
  // `OR` has no right operand, so it is ignored and the remaining
  // `AND b` forms an intersection with `a`.
  assert_eq(parsed("a OR AND b"), "(and (name \"a\") (name \"b\"))")
  assert_eq(parsed("a AND OR b"), "(or (name \"a\") (name \"b\"))")
}

///|
test "modifiers apply to the next term only" {
  assert_eq(parsed("case:README"), "(name \"README\" case)")
  assert_eq(parsed("nocase:README"), "(name \"README\")")
  assert_eq(parsed("exact:Makefile"), "(name \"Makefile\" exact)")
  assert_eq(parsed("path:home"), "(name \"home\" path)")
  assert_eq(
    parsed("regex:^IMG_[0-9]+\\.jpg$"),
    "(name \"^IMG_[0-9]+.jpg$\" regex)",
  )
}

///|
test "modifiers do not leak out of a group" {
  assert_eq(parsed("file:a OR b"), "(or (name \"a\" kind=file) (name \"b\"))")
  assert_eq(
    parsed("file:(a OR b)"),
    "(or (name \"a\" kind=file) (name \"b\" kind=file))",
  )
  assert_eq(parsed("(file:a) OR b"), "(or (name \"a\" kind=file) (name \"b\"))")
  assert_eq(parsed("case:a nocase:b"), "(and (name \"a\" case) (name \"b\"))")
}

///|
test "kind modifiers cover both aliases and chain with other modifiers" {
  assert_eq(parsed("file:test"), "(name \"test\" kind=file)")
  assert_eq(parsed("files:test"), "(name \"test\" kind=file)")
  assert_eq(parsed("folder:test"), "(name \"test\" kind=folder)")
  assert_eq(parsed("folders:test"), "(name \"test\" kind=folder)")
  assert_eq(parsed("file:case:x"), "(name \"x\" case kind=file)")
}

///|
test "a kind modifier with no target becomes a standalone filter" {
  assert_eq(parsed("file:"), "(kind file)")
  assert_eq(parsed("file:   "), "(kind file)")
  assert_eq(parsed("folder:"), "(kind folder)")
  assert_eq(parsed("a AND file:"), "(and (name \"a\") (kind file))")
}

///|
test "other modifiers with no target are ignored" {
  assert_eq(parsed("case:"), "*")
  assert_eq(parsed("exact:"), "*")
  assert_eq(parsed("path:"), "*")
}

///|
test "caller flags seed the parser" {
  let flags = @query.Flags::new(case_sensitive=true, search_path=true)
  assert_eq(parsed_with("report", flags), "(name \"report\" case path)")
  assert_eq(parsed_with("nocase:report", flags), "(name \"report\" path)")
  assert_eq(parsed_with("nopath:report", flags), "(name \"report\" case)")
  assert_eq(
    parsed_with("case:report", @query.Flags::new()),
    "(name \"report\" case)",
  )
  assert_eq(
    parsed_with("report", @query.Flags::new(kind=@query.FilesOnly)),
    "(name \"report\" kind=file)",
  )
  assert_eq(
    parsed_with("", @query.Flags::new(kind=@query.FilesOnly)),
    "(kind file)",
  )
  assert_eq(
    parsed_with("folder:", @query.Flags::new(kind=@query.FilesOnly)),
    "(kind folder)",
  )
}

///|
test "a needle with a slash searches the path" {
  assert_eq(parsed("/home/user"), "(name \"/home/user\" path)")
  assert_eq(parsed("nopath:/home/user"), "(name \"/home/user\")")
  assert_eq(parsed("path:home"), "(name \"home\" path)")
}

///|
test "a non-ASCII uppercase letter forces case sensitivity" {
  assert_eq(parsed("Äpfel"), "(name \"Äpfel\" case)")
  assert_eq(parsed("nocase:Äpfel"), "(name \"Äpfel\")")
  assert_eq(parsed("café"), "(name \"café\")")
  assert_eq(
    parsed("café au lait"),
    "(and (and (name \"café\") (name \"au\")) (name \"lait\"))",
  )
}

///|
test "extension lists split on semicolons" {
  assert_eq(parsed("ext:jpg;png"), "(ext \"jpg\" \"png\")")
  assert_eq(parsed("ext:JPG;PNG"), "(ext \"jpg\" \"png\")")
  assert_eq(parsed("ext:jpg;"), "(ext \"jpg\" \"\")")
  assert_eq(parsed("ext:"), "(ext \"\")")
  assert_eq(parsed("ext: jpg"), "(ext \"jpg\")")
  assert_eq(parsed("ext:\"jpg; png\""), "(ext \"jpg\" \"png\")")
}

///|
test "file and extension terms intersect" {
  assert_eq(parsed("file: ext:pdf"), "(ext \"pdf\" kind=file)")
  assert_eq(
    parsed("file: ext:pdf size:>1mb"),
    "(and (ext \"pdf\" kind=file) (size > 1000000))",
  )
}

///|
test "size values support every comparison form" {
  assert_eq(parsed("size:5"), "(size = 5)")
  assert_eq(parsed("size:=5"), "(size = 5)")
  assert_eq(parsed("size:>1mb"), "(size > 1000000)")
  assert_eq(parsed("size:>=1mb"), "(size >= 1000000)")
  assert_eq(parsed("size:<2kb"), "(size < 2000)")
  assert_eq(parsed("size:<=2kb"), "(size <= 2000)")
  assert_eq(parsed("size:1kb..2mb"), "(size .. 1000 2000000)")
  assert_eq(parsed("size:..1mb"), "(size .. 0 1000000)")
  assert_eq(parsed("size:1mb.."), "(size .. 1000000 9223372036854775807)")
  assert_eq(parsed("size: 1mb"), "(size = 1000000)")
  assert_eq(parsed("size: >1mb"), "(size > 1000000)")
}

///|
test "date values keep their text" {
  assert_eq(parsed("dm:2024-01"), "(dm = \"2024-01\")")
  assert_eq(parsed("dm:>2024"), "(dm > \"2024\")")
  assert_eq(parsed("datemodified:today"), "(dm = \"today\")")
  assert_eq(
    parsed("dm:lastweek..yesterday"),
    "(dm \"lastweek\" .. \"yesterday\")",
  )
  assert_eq(parsed("dm:..yesterday"), "(dm .. \"yesterday\")")
  assert_eq(parsed("dm:\"2024-01-31 12:00\""), "(dm = \"2024-01-31 12:00\")")
}

///|
test "counting fields parse comparisons and ranges" {
  assert_eq(parsed("depth:2"), "(depth = 2)")
  assert_eq(parsed("depth:<=3"), "(depth <= 3)")
  assert_eq(parsed("parents:3"), "(depth = 3)")
  assert_eq(parsed("childcount:1..5"), "(childcount .. 1 5)")
  assert_eq(parsed("childfilecount:0"), "(childfilecount = 0)")
  assert_eq(parsed("childfoldercount:10..20"), "(childfoldercount .. 10 20)")
}

///|
test "parent, empty, and contenttype are distinct terms" {
  assert_eq(parsed("parent:/home/user"), "(parent \"/home/user\")")
  assert_eq(parsed("parent:\"/home/my dir\""), "(parent \"/home/my dir\")")
  assert_eq(parsed("empty:"), "(empty)")
  assert_eq(parsed("empty: foo"), "(and (empty) (name \"foo\"))")
  assert_eq(parsed("contenttype:TEXT/PLAIN"), "(contenttype \"text/plain\")")
}

///|
test "field names are ASCII case-insensitive" {
  assert_eq(parsed("SIZE:>1MB"), "(size > 1000000)")
  assert_eq(parsed("Ext:JPG"), "(ext \"jpg\")")
  assert_eq(parsed("FILE:x"), "(name \"x\" kind=file)")
}

///|
test "an unknown field is an error" {
  match parse_error("unknown:x") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 0)
      assert_true(message.contains("unknown field"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "compat turns an unknown field into the empty set" {
  assert_eq(parsed_compat("unknown:x"), "none")
  assert_eq(parsed_compat("unknown:x ext:jpg"), "none")
}

///|
test "a malformed size is an error at the value" {
  match parse_error("size:abc") {
    @query.BadValue(pos, field, value, message) => {
      assert_eq(pos, 5)
      assert_eq(field, "size")
      assert_eq(value, "abc")
      assert_true(message.contains("size"))
    }
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("size:>1..2") {
    @query.BadValue(_, field, _, _) => assert_eq(field, "size")
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("size:") {
    @query.BadValue(pos, _, value, _) => {
      assert_eq(pos, 0)
      assert_eq(value, "")
    }
    err => abort("expected a bad value, got \{err.message()}")
  }
}

///|
test "compat turns malformed values into the empty set" {
  assert_eq(parsed_compat("size:abc"), "none")
  assert_eq(parsed_compat("size:"), "none")
  assert_eq(parsed_compat("depth:1..2..3"), "none")
}

///|
test "an operator with no value is a syntax error" {
  match parse_error("size:>") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 5)
      assert_true(message.contains("expected a value"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "unmatched parentheses are reported" {
  match parse_error("a )") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 2)
      assert_true(message.contains("unmatched"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
  match parse_error("(a") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 0)
      assert_true(message.contains("unclosed"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
  assert_eq(parsed_compat("a )"), "none")
}

///|
test "an operator in primary position is reported" {
  match parse_error("a = b") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 2)
      assert_true(message.contains("unexpected"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "a date comparison rejects a range after an operator" {
  match parse_error("dm:>a..b") {
    @query.BadValue(_, field, _, _) => assert_eq(field, "dm")
    err => abort("expected a bad value, got \{err.message()}")
  }
}

///|
test "excessively deep nesting is rejected" {
  let mut input = ""
  for _ in 0..<300 {
    input = input + "("
  }
  input = input + "x"
  for _ in 0..<300 {
    input = input + ")"
  }
  match parse_error(input) {
    @query.Parse(_, message) => assert_true(message.contains("deeply"))
    err => abort("expected a nesting error, got \{err.message()}")
  }
}

///|
test "quoted text keeps its backslashes for regular expressions" {
  assert_eq(
    parsed("regex:\"^IMG_[0-9]{4}\\.jpg$\""),
    "(name \"^IMG_[0-9]{4}\\\\.jpg$\" regex)",
  )
}

///|
test "the MVP query examples parse end to end" {
  assert_eq(
    parsed("ext:jpg;png size:>1mb"),
    "(and (ext \"jpg\" \"png\") (size > 1000000))",
  )
  assert_eq(
    parsed("file: ext:pdf;epub size:>1mb"),
    "(and (ext \"pdf\" \"epub\" kind=file) (size > 1000000))",
  )
  assert_eq(parsed("report pdf"), "(and (name \"report\") (name \"pdf\"))")
  assert_eq(parsed("*.pdf"), "(name \"*.pdf\")")
  assert_eq(
    parsed("parent:/home/user ext:mp4"),
    "(and (parent \"/home/user\") (ext \"mp4\"))",
  )
  assert_eq(
    parsed("(pdf || epub) !draft"),
    "(and (or (name \"pdf\") (name \"epub\")) (not (name \"draft\")))",
  )
  assert_eq(
    parsed("dm:lastweek ext:mp4"),
    "(and (dm = \"lastweek\") (ext \"mp4\"))",
  )
}

///|
test "negation after a modifier keeps the modifier flags" {
  assert_eq(parsed("file:!x"), "(not (name \"x\" kind=file))")
  assert_eq(parsed("file:!!x"), "(name \"x\" kind=file)")
  assert_eq(parsed("case:NOT x"), "(not (name \"x\" case))")
  assert_eq(parsed("case:!!!x"), "(not (name \"x\" case))")
}

///|
test "stray operators after a modifier are skipped" {
  assert_eq(parsed("case:OR x"), "(name \"x\" case)")
  assert_eq(parsed("case:AND x"), "(name \"x\" case)")
  assert_eq(parsed("case:AND"), "*")
  assert_eq(parsed("case:OR"), "*")
}

///|
test "boolean constants fold during construction" {
  assert_eq(parsed("NOT ()"), "none")
  assert_eq(parsed("NOT NOT ()"), "*")
  assert_eq(parsed("() OR a"), "*")
  assert_eq(parsed("a OR ()"), "*")
  assert_eq(parsed("() AND a"), "(name \"a\")")
  assert_eq(parsed("a AND ()"), "(name \"a\")")
}

///|
test "compat mode folds malformed fields into the empty set" {
  assert_eq(parsed_compat("unknown:x OR a"), "(name \"a\")")
  assert_eq(parsed_compat("unknown:x AND a"), "none")
  assert_eq(parsed_compat("unknown:x size:>1"), "none")
  assert_eq(parsed_compat("unknown:>x"), "none")
  assert_eq(parsed_compat("unknown:=x"), "none")
  assert_eq(parsed_compat("unknown:"), "none")
  // Consecutive comparison operators must still be consumed without leaving a
  // stray token behind.
  assert_eq(parsed_compat("unknown:==x"), "none")
}

///|
test "every modifier without a target is ignored except kind filters" {
  assert_eq(parsed("regex:"), "*")
  assert_eq(parsed("noregex:"), "*")
  assert_eq(parsed("case:"), "*")
  assert_eq(parsed("nocase:"), "*")
  assert_eq(parsed("exact:"), "*")
  assert_eq(parsed("path:"), "*")
  assert_eq(parsed("nopath:"), "*")
  assert_eq(parsed("files:"), "(kind file)")
  assert_eq(parsed("folders:"), "(kind folder)")
}

///|
test "modifiers chain and explicit negatives override caller flags" {
  assert_eq(parsed("regex:^a"), "(name \"^a\" regex)")
  assert_eq(
    parsed("case:exact:path:regex:file:x"),
    "(name \"x\" case exact path regex kind=file)",
  )
  assert_eq(
    parsed_with("noregex:a", @query.Flags::new(regex=true)),
    "(name \"a\")",
  )
  assert_eq(parsed_with("case:a", @query.Flags::new()), "(name \"a\" case)")
  assert_eq(
    parsed_with("nocase:a", @query.Flags::new(case_sensitive=true)),
    "(name \"a\")",
  )
}

///|
test "modifiers on a group stay inside the group" {
  assert_eq(
    parsed("case:(a OR b) c"),
    "(and (or (name \"a\" case) (name \"b\" case)) (name \"c\"))",
  )
  assert_eq(
    parsed("!case:(A || B) c"),
    "(and (not (or (name \"A\" case) (name \"B\" case))) (name \"c\"))",
  )
  assert_eq(parsed("case:(a) nocase:b"), "(and (name \"a\" case) (name \"b\"))")
}

///|
test "fields reject values they cannot interpret" {
  match parse_error("parent:") {
    @query.BadValue(_, field, value, _) => {
      assert_eq(field, "parent")
      assert_eq(value, "")
    }
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("parent:>x") {
    @query.BadValue(pos, field, value, message) => {
      assert_eq(pos, 8)
      assert_eq(field, "parent")
      assert_eq(value, "x")
      assert_true(message.contains("operator"))
    }
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("contenttype:>x") {
    @query.BadValue(_, field, _, _) => assert_eq(field, "contenttype")
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("ext:>jpg") {
    @query.BadValue(_, field, value, message) => {
      assert_eq(field, "ext")
      assert_eq(value, "jpg")
      assert_true(message.contains("operator"))
    }
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("empty:>x") {
    @query.Parse(_, message) => assert_true(message.contains("unexpected"))
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "counting and size values cover their numeric edges" {
  assert_eq(parsed("depth:+3"), "(depth = 3)")
  assert_eq(parsed("depth:0003"), "(depth = 3)")
  assert_eq(parsed("depth:>=3"), "(depth >= 3)")
  assert_eq(parsed("depth:.."), "(depth .. 0 9223372036854775807)")
  assert_eq(parsed("childcount:3..3"), "(childcount = 3)")
  assert_eq(parsed("size:.."), "(size .. 0 9223372036854775807)")
  assert_eq(parsed("size:0005"), "(size = 5)")
  match parse_error("size:+3") {
    @query.BadValue(_, field, _, _) => assert_eq(field, "size")
    err => abort("expected a bad value, got \{err.message()}")
  }
  match parse_error("size:9223372036854776kb") {
    @query.BadValue(_, field, _, _) => assert_eq(field, "size")
    err => abort("expected a bad value, got \{err.message()}")
  }
}

///|
test "date values cover open, closed, and invalid ranges" {
  assert_eq(parsed("dm:.."), "(dm ..)")
  assert_eq(parsed("dm:>=today"), "(dm >= \"today\")")
  assert_eq(parsed("dm:today..today"), "(dm = \"today\")")
  match parse_error("dm:..x..y") {
    @query.BadValue(_, field, _, _) => assert_eq(field, "dm")
    err => abort("expected a bad value, got \{err.message()}")
  }
}

///|
test "extension lists preserve empty entries" {
  assert_eq(parsed("ext:jpg;;png"), "(ext \"jpg\" \"\" \"png\")")
  assert_eq(parsed("ext:;"), "(ext \"\" \"\")")
  assert_eq(parsed("ext:\"\""), "(ext \"\")")
  assert_eq(parsed("ext:PDF;TXT"), "(ext \"pdf\" \"txt\")")
}

///|
test "field names are ASCII case-insensitive in every spelling" {
  assert_eq(parsed("SiZe:>1Kb"), "(size > 1000)")
  assert_eq(parsed("DaTeMoDiFiEd:today"), "(dm = \"today\")")
  assert_eq(parsed("PARENT:/x"), "(parent \"/x\")")
  assert_eq(parsed("PARENTS:2"), "(depth = 2)")
  assert_eq(parsed("ChildFileCount:0"), "(childfilecount = 0)")
}

///|
test "describe escapes quotes and backslashes in names" {
  assert_eq(parsed("a\\\"b"), "(name \"a\\\"b\")")
  assert_eq(parsed("a\\\\b"), "(name \"a\\\\b\")")
}

///|
test "the group depth limit is exactly 256" {
  let allowed = StringBuilder()
  for _ in 0..<256 {
    allowed.write_string("(")
  }
  allowed.write_string("x")
  for _ in 0..<256 {
    allowed.write_string(")")
  }
  assert_eq(parsed(allowed.to_string()), "(name \"x\")")

  let rejected = StringBuilder()
  for _ in 0..<257 {
    rejected.write_string("(")
  }
  rejected.write_string("x")
  for _ in 0..<257 {
    rejected.write_string(")")
  }
  match parse_error(rejected.to_string()) {
    @query.Parse(_, message) => assert_true(message.contains("deeply"))
    err => abort("expected a nesting error, got \{err.message()}")
  }
}

///|
test "error offsets survive an astral character before the field" {
  match parse_error("🤣 size:>") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 8)
      assert_true(message.contains("expected a value"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "a term exposes its flags and body" {
  let flags = @query.Flags::new(case_sensitive=true, kind=@query.FilesOnly)
  let query = @query.parse("ext:pdf", flags~) catch {
    err => abort(err.message())
  }
  match query {
    @query.Term(term) => {
      assert_eq(term.flags().describe(), "case kind=file")
      match term.body() {
        @query.Extensions(list) => assert_eq(list.length(), 1)
        _ => abort("expected an extension term")
      }
    }
    _ => abort("expected a single term")
  }
}

///|
test "every value-taking field rejects a missing value" {
  for
    input in [
      "dm:", "contenttype:", "depth:", "childcount:", "childfilecount:", "childfoldercount:",
    ] {
    match parse_error(input) {
      @query.BadValue(_, field, value, _) => {
        assert_eq(value, "")
        assert_false(field.is_empty())
      }
      err => abort("expected a bad value for \{input}, got \{err.message()}")
    }
  }
  assert_eq(parsed_compat("dm:"), "none")
  assert_eq(parsed_compat("depth:"), "none")
}

///|
test "a group reports the token it found instead of a closing parenthesis" {
  match parse_error("(a = b)") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 3)
      assert_true(message.contains("expected ')'"))
      assert_true(message.contains("'='"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "unexpected tokens after a modifier are reported at their position" {
  match parse_error("case:=x") {
    @query.Parse(pos, message) => {
      assert_eq(pos, 5)
      assert_true(message.contains("unexpected '='"))
    }
    err => abort("expected a parse error, got \{err.message()}")
  }
}

///|
test "a negated modifier with no target is ignored" {
  assert_eq(parsed("file:!"), "*")
  assert_eq(parsed("file:!!"), "*")
  assert_eq(parsed("case:!"), "*")
}

///|
test "compat constants fold from either side of a binary operator" {
  assert_eq(parsed_compat("a OR unknown:x"), "(name \"a\")")
  assert_eq(parsed_compat("a AND unknown:x"), "none")
  assert_eq(parsed_compat("NOT unknown:x"), "*")
}

///|
test "binary operators are left-associative" {
  assert_eq(
    parsed("a OR b OR c"),
    "(or (or (name \"a\") (name \"b\")) (name \"c\"))",
  )
  assert_eq(
    parsed("a b c"),
    "(and (and (name \"a\") (name \"b\")) (name \"c\"))",
  )
  assert_eq(
    parsed("a AND b AND c"),
    "(and (and (name \"a\") (name \"b\")) (name \"c\"))",
  )
}

///|
test "NOT binds tighter than both binary operators" {
  assert_eq(parsed("NOT a AND b"), "(and (not (name \"a\")) (name \"b\"))")
  assert_eq(parsed("NOT a OR b"), "(or (not (name \"a\")) (name \"b\"))")
  assert_eq(
    parsed("NOT (a OR b) AND c"),
    "(and (not (or (name \"a\") (name \"b\"))) (name \"c\"))",
  )
}

///|
test "a modifier inside an OR branch affects only its next primary" {
  assert_eq(
    parsed("a OR case:b c"),
    "(or (name \"a\") (and (name \"b\" case) (name \"c\")))",
  )
  assert_eq(
    parsed("a case:b OR c"),
    "(or (and (name \"a\") (name \"b\" case)) (name \"c\"))",
  )
}
