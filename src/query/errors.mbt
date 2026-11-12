///|
/// Errors raised while lexing, parsing, or expanding a query.
///
/// Every variant carries the UTF-16 offset of the token that caused the
/// failure, so the CLI can point at the offending position and tests can assert
/// both the position and the message. Query errors map to exit code 2.
pub suberror QueryError {
  /// The input could not be split into tokens: an unterminated quote, a
  /// trailing backslash, or a stray `:`.
  Lex(Int32, String)
  /// The token stream does not form a valid query: an unknown field, an
  /// unmatched parenthesis, or an operator in a position that cannot take one.
  Parse(Int32, String)
  /// A field value could not be interpreted: a size without digits, an
  /// overflowing count, or an empty date.
  BadValue(Int32, String, String, String)
  /// A macro expands to itself, directly or through other macros.
  MacroCycle(Int32, String)
  /// A macro failed to parse. The inner message keeps its own offset inside
  /// the macro text; the first offset is where the macro was used in the outer
  /// query.
  MacroError(Int32, String, String)
}

///|
/// Offset of the token that caused the error.
pub fn QueryError::position(self : QueryError) -> Int32 {
  match self {
    Lex(pos, _) => pos
    Parse(pos, _) => pos
    BadValue(pos, _, _, _) => pos
    MacroCycle(pos, _) => pos
    MacroError(pos, _, _) => pos
  }
}

///|
/// Human-readable text for the CLI.
///
/// Offsets are UTF-16 code units, the same unit the lexer advances by.
pub fn QueryError::message(self : QueryError) -> String {
  match self {
    Lex(pos, message) => "query error at \{pos}: \{message}"
    Parse(pos, message) => "query error at \{pos}: \{message}"
    BadValue(pos, field, value, message) =>
      "query error at \{pos}: \{field}:\{value}: \{message}"
    MacroCycle(pos, name) =>
      "query error at \{pos}: macro '\{name}' expands to itself"
    MacroError(pos, name, message) =>
      "query error at \{pos}: in macro '\{name}': \{message}"
  }
}
