///|
/// Render a token stream as a single line for compact assertions.
fn tokens_of(input : String) -> String {
  let tokens = @query.lex(input) catch { err => abort(err.message()) }
  tokens.map(fn(token) { token.kind().describe() }).join(" ")
}

///|
/// Lex a query that must fail and return the error.
fn lex_error(input : String) -> @query.QueryError {
  try @query.lex(input) catch {
    err => err
  } noraise {
    _ => abort("expected the query to fail lexing")
  }
}

///|
test "an empty query is just end of input" {
  assert_eq(tokens_of(""), "end of query")
  assert_eq(tokens_of("   \t\n"), "end of query")
}

///|
test "words are separated by ASCII whitespace" {
  assert_eq(tokens_of("report"), "'report' end of query")
  assert_eq(tokens_of("  report   pdf \t"), "'report' 'pdf' end of query")
  assert_eq(tokens_of("one\ntwo\rthree"), "'one' 'two' 'three' end of query")
}

///|
test "uppercase operator words are operators" {
  assert_eq(
    tokens_of("a AND b && c OR d || e NOT f !g"),
    "'a' AND 'b' AND 'c' OR 'd' OR 'e' NOT 'f' NOT 'g' end of query",
  )
}

///|
test "lowercase operator words and longer words stay search terms" {
  assert_eq(
    tokens_of("and or not ANDROID ORACLE NOTHING"),
    "'and' 'or' 'not' 'ANDROID' 'ORACLE' 'NOTHING' end of query",
  )
}

///|
test "quoted and escaped words are never operators" {
  assert_eq(tokens_of("\"AND\""), "'AND' end of query")
  assert_eq(tokens_of("\\AND"), "'AND' end of query")
}

///|
test "a quoted string keeps spaces and backslashes" {
  assert_eq(tokens_of("\"my folder\""), "'my folder' end of query")
  assert_eq(tokens_of("\"a b\\c\""), "'a b\\c' end of query")
}

///|
test "backslash escapes the next character outside quotes" {
  assert_eq(tokens_of("my\\ folder"), "'my folder' end of query")
  assert_eq(tokens_of("\\(x\\)"), "'(x)' end of query")
  assert_eq(tokens_of("a\\\"b"), "'a\"b' end of query")
  assert_eq(tokens_of("\\&\\&"), "'&&' end of query")
}

///|
test "a colon turns a word into a field token" {
  assert_eq(tokens_of("file:"), "'file:' end of query")
  assert_eq(tokens_of("file:test"), "'file:' 'test' end of query")
  assert_eq(tokens_of("size:>1mb"), "'size:' '>' '1mb' end of query")
  assert_eq(tokens_of("ext:jpg;png"), "'ext:' 'jpg;png' end of query")
  assert_eq(tokens_of("file:(a)"), "'file:' '(' 'a' ')' end of query")
}

///|
test "a field ends before whitespace and keeps its text" {
  assert_eq(tokens_of("file: test"), "'file:' 'test' end of query")
  assert_eq(
    tokens_of("parent:/home/user"),
    "'parent:' '/home/user' end of query",
  )
}

///|
test "comparison operators are separate tokens" {
  assert_eq(
    tokens_of("a=b <= c >= d < e > f"),
    "'a' '=' 'b' '<=' 'c' '>=' 'd' '<' 'e' '>' 'f' end of query",
  )
}

///|
test "ampersands and pipes are words unless doubled" {
  assert_eq(tokens_of("a&&b"), "'a' AND 'b' end of query")
  assert_eq(tokens_of("a||b"), "'a' OR 'b' end of query")
  assert_eq(tokens_of("a&b"), "'a&b' end of query")
  assert_eq(tokens_of("a|b"), "'a|b' end of query")
}

///|
test "parentheses and bang are tokens anywhere" {
  assert_eq(tokens_of("(a)!"), "'(' 'a' ')' NOT end of query")
  assert_eq(tokens_of("foo!bar"), "'foo' NOT 'bar' end of query")
}

///|
test "non-ASCII words are kept intact" {
  assert_eq(tokens_of("发票"), "'发票' end of query")
  assert_eq(tokens_of("naïve"), "'naïve' end of query")
}

///|
test "token positions are UTF-16 offsets" {
  let tokens = @query.lex("  foo  bar: baz") catch {
    err => abort(err.message())
  }
  assert_eq(tokens[0].pos(), 2)
  assert_eq(tokens[1].pos(), 7)
  assert_eq(tokens[2].pos(), 12)
  assert_eq(tokens[3].pos(), 15)
  // An astral code point occupies two code units.
  let astral = @query.lex("🤣 x") catch { err => abort(err.message()) }
  assert_eq(astral[0].pos(), 0)
  assert_eq(astral[1].pos(), 3)
}

///|
test "an unterminated quote reports the opening position" {
  match lex_error("\"abc") {
    @query.Lex(pos, message) => {
      assert_eq(pos, 0)
      assert_true(message.contains("unterminated"))
    }
    err => abort("expected a lex error, got \{err.message()}")
  }
}

///|
test "a trailing backslash is an error" {
  match lex_error("abc\\") {
    @query.Lex(pos, message) => {
      assert_eq(pos, 3)
      assert_true(message.contains("trailing"))
    }
    err => abort("expected a lex error, got \{err.message()}")
  }
}

///|
test "a colon with no field name is an error" {
  match lex_error(":foo") {
    @query.Lex(pos, _) => assert_eq(pos, 0)
    err => abort("expected a lex error, got \{err.message()}")
  }
}

///|
test "a quote in the middle of a word is an error" {
  match lex_error("foo\"bar") {
    @query.Lex(pos, message) => {
      assert_eq(pos, 3)
      assert_true(message.contains("inside a word"))
    }
    err => abort("expected a lex error, got \{err.message()}")
  }
}

///|
test "error positions count UTF-16 code units" {
  match lex_error("🤣 \"abc") {
    @query.Lex(pos, _) => assert_eq(pos, 3)
    err => abort("expected a lex error, got \{err.message()}")
  }
}

///|
test "a lone ampersand or pipe is part of a word" {
  assert_eq(tokens_of("&x"), "'&x' end of query")
  assert_eq(tokens_of("|x"), "'|x' end of query")
  assert_eq(tokens_of("&"), "'&' end of query")
  assert_eq(tokens_of("|"), "'|' end of query")
  assert_eq(tokens_of("a&&&b"), "'a' AND '&b' end of query")
  assert_eq(tokens_of("a|||b"), "'a' OR '|b' end of query")
  assert_eq(tokens_of("&&&"), "AND '&' end of query")
  assert_eq(tokens_of("|||"), "OR '|' end of query")
}

///|
test "escapes also work on reserved characters" {
  assert_eq(tokens_of("\\:x"), "':x' end of query")
  assert_eq(tokens_of("a\\:b"), "'a:b' end of query")
  // Only the escaped colon is literal; the second one starts a field.
  assert_eq(tokens_of("a\\:b:c"), "'a:b:' 'c' end of query")
  assert_eq(tokens_of("\\!x"), "'!x' end of query")
  assert_eq(tokens_of("\\&&"), "'&&' end of query")
  assert_eq(tokens_of("\\(x\\)"), "'(x)' end of query")
  assert_eq(tokens_of("\\A\\N\\D"), "'AND' end of query")
  // A single escaped letter disables operator recognition for the word.
  assert_eq(tokens_of("A\\ND"), "'AND' end of query")
}

///|
test "quotes can start a word but not appear inside one" {
  assert_eq(tokens_of("\"\""), "'' end of query")
  assert_eq(tokens_of("\"a\"b"), "'a' 'b' end of query")
  match lex_error("\"a\"b\"") {
    @query.Lex(pos, message) => {
      assert_eq(pos, 4)
      assert_true(message.contains("inside a word"))
    }
    err => abort("expected a lex error, got \{err.message()}")
  }
  // A colon directly after a quoted word is not a field separator.
  match lex_error("\"file\":x") {
    @query.Lex(pos, _) => assert_eq(pos, 6)
    err => abort("expected a lex error, got \{err.message()}")
  }
}

///|
test "reserved characters terminate a word without needing spaces" {
  assert_eq(tokens_of("a(b)"), "'a' '(' 'b' ')' end of query")
  assert_eq(tokens_of("a=b"), "'a' '=' 'b' end of query")
  assert_eq(tokens_of("< ="), "'<' '=' end of query")
  assert_eq(tokens_of("a<b>c"), "'a' '<' 'b' '>' 'c' end of query")
}

///|
test "only ASCII whitespace separates tokens" {
  assert_eq(tokens_of("a\u{0B}b\u{0C}c"), "'a' 'b' 'c' end of query")
  // U+00A0 and U+2003 are ordinary word bytes.
  assert_eq(tokens_of("a\u{00A0}b"), "'a\u{00A0}b' end of query")
  assert_eq(tokens_of("a\u{2003}b"), "'a\u{2003}b' end of query")
}

///|
test "a field token can end at a tab or a newline" {
  assert_eq(tokens_of("file:\t"), "'file:' end of query")
  assert_eq(tokens_of("file:\n"), "'file:' end of query")
  assert_eq(tokens_of("file:\r\nx"), "'file:' 'x' end of query")
}

///|
test "positions count escaped astral characters correctly" {
  let tokens = @query.lex("\\🤣 x") catch { err => abort(err.message()) }
  assert_eq(tokens[0].pos(), 0)
  assert_eq(tokens[1].pos(), 4)
  let field = @query.lex("size:>abc") catch { err => abort(err.message()) }
  assert_eq(field[0].pos(), 0)
  assert_eq(field[1].pos(), 5)
  assert_eq(field[2].pos(), 6)
  match lex_error("🤣\\") {
    @query.Lex(pos, _) => assert_eq(pos, 2)
    err => abort("expected a lex error, got \{err.message()}")
  }
}
