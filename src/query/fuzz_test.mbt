///|
/// Advance the deterministic generator used by the robustness tests.
fn fuzz_seed(seed : Int64) -> Int64 {
  (seed * 1103515245L + 12345L) % 2147483648L
}

///|
/// Byte and syntax fragments that exercise every lexer path: operators,
/// reserved characters, quotes, escapes, astral characters, and field syntax.
fn fuzz_alphabet() -> Array[String] {
  [
    "a", "b", "0", "1", " ", "\t", ":", "(", ")", "!", "&", "|", "<", ">", "=", "\"",
    "\\", "-", ".", "/", "é", "🤣", "AND", "OR", "NOT", "size:", "ext:",
  ]
}

///|
/// Build one deterministic input string.
fn fuzz_input(seed : Int64, alphabet : Array[String]) -> String {
  let mut state = seed
  state = fuzz_seed(state)
  let length = (state % 14L).to_int()
  let out = StringBuilder()
  for _ in 0..<length {
    state = fuzz_seed(state)
    out.write_string(alphabet[(state % alphabet.length().to_int64()).to_int()])
  }
  out.to_string()
}

///|
test "lexer invariants hold on generated inputs" {
  let alphabet = fuzz_alphabet()
  let mut seed = 17L
  for _ in 0..<2000 {
    seed = fuzz_seed(seed)
    let input = fuzz_input(seed, alphabet)
    let result : Result[Array[@query.Token], @query.QueryError] = Ok(
      @query.lex(input),
    ) catch {
      err => Err(err)
    }
    match result {
      Ok(tokens) => {
        // A successful lex always ends with Eos, positions stay in bounds,
        // and they never move backwards.
        assert_true(tokens.length() > 0)
        assert_true(tokens[tokens.length() - 1].kind() is Eos)
        let mut previous = 0
        for token in tokens {
          assert_true(token.pos() >= previous)
          assert_true(token.pos() <= input.length())
          previous = token.pos()
        }
        assert_eq(tokens[tokens.length() - 1].pos(), input.length())
      }
      Err(err) => {
        assert_true(err.position() >= 0)
        assert_true(err.position() <= input.length())
      }
    }
  }
}

///|
test "parser never panics on generated inputs" {
  let alphabet = fuzz_alphabet()
  let mut seed = 99L
  for _ in 0..<2000 {
    seed = fuzz_seed(seed)
    let input = fuzz_input(seed, alphabet)
    let normal : Result[@query.Query, @query.QueryError] = Ok(
      @query.parse(input),
    ) catch {
      err => Err(err)
    }
    match normal {
      Ok(query) => assert_true(query.describe().length() > 0)
      Err(err) => {
        assert_true(err.position() >= 0)
        assert_true(err.position() <= input.length())
        assert_true(err.message().length() > 0)
      }
    }
    let compat : Result[@query.Query, @query.QueryError] = Ok(
      @query.parse(input, compat=true),
    ) catch {
      err => Err(err)
    }
    match compat {
      Ok(query) => assert_true(query.describe().length() > 0)
      Err(err) => {
        assert_true(err.position() >= 0)
        assert_true(err.position() <= input.length())
      }
    }
  }
}
