///|
/// One lexical token kind.
///
/// Words, fields, and comparison operators carry no offsets: positions live on
/// `Token` so a token kind stays comparable and cheap to describe.
pub(all) enum TokenKind {
  /// A bare, quoted, or escaped search word. Operator words such as `AND` are
  /// not words even though they look like one.
  Word(String)
  /// `name:` with a value immediately following, as in `size:>1mb`.
  Field(String)
  /// `name:` followed by whitespace or the end of the query, as in `file: x`.
  FieldEmpty(String)
  And
  Or
  Not
  Equal
  Greater
  GreaterEqual
  Smaller
  SmallerEqual
  LParen
  RParen
  Eos
}

///|
/// A token together with its start offset in UTF-16 code units.
pub struct Token {
  priv kind : TokenKind
  priv pos : Int32
}

///|
/// Package-private constructor.
fn Token::new(kind : TokenKind, pos : Int32) -> Token {
  { kind, pos, }
}

///|
/// The token kind.
pub fn Token::kind(self : Token) -> TokenKind {
  self.kind
}

///|
/// Offset of the first code unit of the token.
pub fn Token::pos(self : Token) -> Int32 {
  self.pos
}

///|
/// Whether the token can begin a primary expression.
///
/// `Not` is included because it is a prefix: `a NOT b` is an implicit AND
/// whose right operand is negated.
pub fn TokenKind::starts_primary(self : TokenKind) -> Bool {
  match self {
    Word(_) | Field(_) | FieldEmpty(_) | LParen | Not => true
    _ => false
  }
}

///|
/// Whether the token is an explicit binary operator.
pub fn TokenKind::is_binary_operator(self : TokenKind) -> Bool {
  match self {
    And | Or => true
    _ => false
  }
}

///|
/// Diagnostic text for the token, used in parser error messages.
pub fn TokenKind::describe(self : TokenKind) -> String {
  match self {
    Word(text) => "'\{text}'"
    Field(name) => "'\{name}:'"
    FieldEmpty(name) => "'\{name}:'"
    And => "AND"
    Or => "OR"
    Not => "NOT"
    Equal => "'='"
    Greater => "'>'"
    GreaterEqual => "'>='"
    Smaller => "'<'"
    SmallerEqual => "'<='"
    LParen => "'('"
    RParen => "')'"
    Eos => "end of query"
  }
}
