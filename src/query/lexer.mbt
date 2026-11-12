///|
/// Query lexer.
///
/// The lexer turns a query string into tokens and never interprets their
/// meaning. It tracks a UTF-16 code-unit offset so error messages point at the
/// exact position the user typed.
///
/// Rules (`MIGRATION_PLAN.md` section 5.10.1):
///
/// - ASCII whitespace separates tokens; other Unicode spaces are word bytes.
/// - `=`, `:`, `<`, `<=`, `>`, `>=`, `!`, `(`, and `)` are reserved.
/// - `"..."` copies everything up to the next quote verbatim, so a regular
///   expression keeps its backslashes. Outside quotes, `\` escapes the next
///   character. There are no C-style escapes: `\n` is the letter `n`.
/// - `name:` becomes a field token. It is empty when the colon is followed by
///   whitespace or the end of the query.
/// - `AND`, `OR`, and `NOT` are operators only in uppercase and only when they
///   are whole, unquoted words. `&&` and `||` are synonyms.
priv struct Lexer {
  input : StringView
  mut pos : Int32
}

///|
/// Whether a character separates tokens.
fn is_ascii_space(char : Char) -> Bool {
  char == ' ' ||
  char == '\t' ||
  char == '\n' ||
  char == '\r' ||
  char == '\u{0B}' ||
  char == '\u{0C}'
}

///|
/// Whether a character always ends a word.
fn is_word_stop(char : Char) -> Bool {
  char == '(' ||
  char == ')' ||
  char == '=' ||
  char == '<' ||
  char == '>' ||
  char == '!'
}

///|
/// Read the character at `pos`.
///
/// A position inside a surrogate pair cannot be decoded; the replacement
/// character keeps the lexer moving instead of panicking.
fn Lexer::char_at(self : Lexer, pos : Int32) -> Char {
  match self.input.get_char(pos) {
    Some(char) => char
    None => '\u{FFFD}'
  }
}

///|
/// Number of UTF-16 code units the character at `pos` occupies.
fn Lexer::char_len_at(self : Lexer, pos : Int32) -> Int32 {
  match self.input.get_char(pos) {
    Some(char) => char.utf16_len()
    None => 1
  }
}

///|
/// Whether the character at `pos` is followed by the same character.
///
/// Only called for ASCII characters, so advancing one code unit is safe.
fn Lexer::doubled_at(self : Lexer, pos : Int32, char : Char) -> Bool {
  pos + 1 < self.input.length() && self.char_at(pos + 1) == char
}

///|
/// Skip ASCII whitespace.
fn Lexer::skip_spaces(self : Lexer) -> Unit {
  while self.pos < self.input.length() && is_ascii_space(self.char_at(self.pos)) {
    self.pos = self.pos + 1
  }
}

///|
/// Read the next token.
fn Lexer::next(self : Lexer) -> Token raise QueryError {
  self.skip_spaces()
  let start = self.pos
  if start >= self.input.length() {
    return Token::new(Eos, start)
  }
  let char = self.char_at(start)
  match char {
    '(' => {
      self.pos = start + 1
      Token::new(LParen, start)
    }
    ')' => {
      self.pos = start + 1
      Token::new(RParen, start)
    }
    '=' => {
      self.pos = start + 1
      Token::new(Equal, start)
    }
    '!' => {
      self.pos = start + 1
      Token::new(Not, start)
    }
    '<' => {
      self.pos = start + 1
      if self.pos < self.input.length() && self.char_at(self.pos) == '=' {
        self.pos = self.pos + 1
        Token::new(SmallerEqual, start)
      } else {
        Token::new(Smaller, start)
      }
    }
    '>' => {
      self.pos = start + 1
      if self.pos < self.input.length() && self.char_at(self.pos) == '=' {
        self.pos = self.pos + 1
        Token::new(GreaterEqual, start)
      } else {
        Token::new(Greater, start)
      }
    }
    '"' => self.quoted()
    '&' =>
      if self.doubled_at(start, '&') {
        self.pos = start + 2
        Token::new(And, start)
      } else {
        self.word()
      }
    '|' =>
      if self.doubled_at(start, '|') {
        self.pos = start + 2
        Token::new(Or, start)
      } else {
        self.word()
      }
    ':' => raise Lex(start, "unexpected ':'")
    _ => self.word()
  }
}

///|
/// Read a quoted word.
///
/// The opening quote is consumed, then every character is copied verbatim until
/// the closing quote. Backslashes are not escapes here: quoting exists so a
/// regular expression can keep `\.` while the query lexer ignores it. A quote
/// inside a word can be written unquoted as `\"`.
fn Lexer::quoted(self : Lexer) -> Token raise QueryError {
  let start = self.pos
  self.pos = self.pos + 1
  let chars : Array[Char] = []
  while true {
    if self.pos >= self.input.length() {
      raise Lex(start, "unterminated quoted string")
    }
    let char = self.char_at(self.pos)
    if char == '"' {
      self.pos = self.pos + 1
      break
    }
    chars.push(char)
    self.pos = self.pos + self.char_len_at(self.pos)
  }
  Token::new(Word(String::from_array(chars)), start)
}

///|
/// Read a bare or escaped word, or a field token.
///
/// The word stops at whitespace, a reserved character, or the start of `&&` or
/// `||`. A colon ends the word and turns it into a field token; a colon with no
/// word in front of it is an error, and a colon inside a word must be escaped.
fn Lexer::word(self : Lexer) -> Token raise QueryError {
  let start = self.pos
  let chars : Array[Char] = []
  let mut escaped = false
  while self.pos < self.input.length() {
    let char = self.char_at(self.pos)
    if is_ascii_space(char) {
      break
    }
    if char == ':' {
      if chars.is_empty() {
        raise Lex(self.pos, "unexpected ':'")
      }
      let name = String::from_array(chars)
      self.pos = self.pos + 1
      if self.pos >= self.input.length() ||
        is_ascii_space(self.char_at(self.pos)) {
        return Token::new(FieldEmpty(name), start)
      }
      return Token::new(Field(name), start)
    }
    if char == '"' {
      raise Lex(self.pos, "unexpected '\"' inside a word; quote the whole word")
    }
    if is_word_stop(char) {
      break
    }
    if (char == '&' || char == '|') && self.doubled_at(self.pos, char) {
      break
    }
    if char == '\\' {
      let escape_pos = self.pos
      self.pos = self.pos + 1
      if self.pos >= self.input.length() {
        raise Lex(escape_pos, "trailing '\\' at the end of the query")
      }
      chars.push(self.char_at(self.pos))
      self.pos = self.pos + self.char_len_at(self.pos)
      escaped = true
      continue
    }
    chars.push(char)
    self.pos = self.pos + self.char_len_at(self.pos)
  }
  let text = String::from_array(chars)
  if !escaped {
    if text == "AND" {
      return Token::new(And, start)
    }
    if text == "OR" {
      return Token::new(Or, start)
    }
    if text == "NOT" {
      return Token::new(Not, start)
    }
  }
  Token::new(Word(text), start)
}

///|
/// Split a query into tokens.
///
/// The returned array always ends with an `Eos` token, whose position is the
/// input length, so the parser never has to bounds-check the token list.
pub fn lex(input : StringView) -> Array[Token] raise QueryError {
  let lexer : Lexer = { input, pos: 0, }
  let tokens : Array[Token] = []
  while true {
    let token = lexer.next()
    let done = token.kind() is Eos
    tokens.push(token)
    if done {
      break
    }
  }
  tokens
}
