///|
/// Query parser.
///
/// The parser is a precedence climber over the lexer's token stream. `NOT` binds
/// tightest, then the implicit/explcit `AND`, then `OR`. It produces a `Query`
/// directly: there is no separate postfix list or intermediate tree, which is
/// one of the places this port departs from the upstream implementation.
///
/// Error recovery follows the upstream query language:
///
/// - a binary operator with no right operand is ignored (`foo AND` is `foo`);
/// - leading binary operators are ignored (`AND foo` is `foo`);
/// - an even number of `NOT` cancels out;
/// - with `compat`, an unknown field, a malformed value, or a stray `)` matches
///   nothing instead of failing.
pub fn parse(
  input : StringView,
  flags~ : Flags = Flags::new(),
  macros~ : Macros = Macros::new(),
  compat~ : Bool = false,
) -> Query raise QueryError {
  let parser = Parser::new(lex(input), macros, compat)
  parser.parse_top(flags)
}

///|
/// `OR` is the loosest operator.
const PRECEDENCE_OR : Int32 = 1

///|
/// `AND` and implicit juxtaposition bind tighter than `OR`.
const PRECEDENCE_AND : Int32 = 2

///|
/// The binary operator chosen for one iteration of the precedence climber.
priv enum BinaryOp {
  AndOp
  OrOp
}

///|
/// Flags plus the record of which of them were set explicitly.
///
/// Auto-detection of path search and case sensitivity must not override an
/// explicit `path:`, `nopath:`, `case:`, or `nocase:`. The two booleans are the
/// only state the parser needs beyond `Flags` itself.
priv struct ModifierState {
  flags : Flags
  case_explicit : Bool
  path_explicit : Bool
}

///|
fn ModifierState::new(flags : Flags) -> ModifierState {
  { flags, case_explicit: false, path_explicit: false, }
}

///|
fn ModifierState::with_case(
  self : ModifierState,
  value : Bool,
) -> ModifierState {
  {
    flags: self.flags.with_case_sensitive(value),
    case_explicit: true,
    path_explicit: self.path_explicit,
  }
}

///|
fn ModifierState::with_exact(
  self : ModifierState,
  value : Bool,
) -> ModifierState {
  {
    flags: self.flags.with_exact(value),
    case_explicit: self.case_explicit,
    path_explicit: self.path_explicit,
  }
}

///|
fn ModifierState::with_path(
  self : ModifierState,
  value : Bool,
) -> ModifierState {
  {
    flags: self.flags.with_search_path(value),
    case_explicit: self.case_explicit,
    path_explicit: true,
  }
}

///|
fn ModifierState::with_regex(
  self : ModifierState,
  value : Bool,
) -> ModifierState {
  {
    flags: self.flags.with_regex(value),
    case_explicit: self.case_explicit,
    path_explicit: self.path_explicit,
  }
}

///|
fn ModifierState::with_kind(
  self : ModifierState,
  value : KindFilter,
) -> ModifierState {
  {
    flags: self.flags.with_kind(value),
    case_explicit: self.case_explicit,
    path_explicit: self.path_explicit,
  }
}

///|
/// A value token paired with the comparison operator written in front of it.
priv struct RawValue {
  op : CmpOp?
  text : String
  pos : Int32
}

///|
/// Maximum depth of nested parenthesized groups and macro expansions.
///
/// Queries come straight from the command line, so the parser bounds recursion
/// instead of trusting the input. The limit is far above anything a person
/// writes.
const MAX_QUERY_DEPTH : Int32 = 256

///|
/// Parser state for one query string.
priv struct Parser {
  tokens : Array[Token]
  mut index : Int32
  macros : Macros
  compat : Bool
  /// Macro names currently being expanded, outermost first.
  active : Array[String]
  /// Current nesting depth of groups and macro expansions.
  mut depth : Int32
}

///|
fn Parser::new(tokens : Array[Token], macros : Macros, compat : Bool) -> Parser {
  { tokens, index: 0, macros, compat, active: [], depth: 0, }
}

///|
/// The current token, or the closing `Eos` when the stream is exhausted.
fn Parser::peek(self : Parser) -> Token {
  self.peek_at(0)
}

///|
/// The token `offset` positions ahead, saturating at `Eos`.
fn Parser::peek_at(self : Parser, offset : Int32) -> Token {
  let index = self.index + offset
  if index >= self.tokens.length() {
    self.tokens[self.tokens.length() - 1]
  } else {
    self.tokens[index]
  }
}

///|
/// Consume and return the current token. `Eos` is never consumed.
fn Parser::advance(self : Parser) -> Token {
  let token = self.peek()
  if !(token.kind() is Eos) {
    self.index = self.index + 1
  }
  token
}

///|
/// Parse a whole query and require the token stream to be exhausted.
///
/// Initial flags reach every parsed term. When the query is empty there is no
/// term carrying a `kind` flag, so a `--type`-style kind filter becomes a
/// standalone kind term instead of being lost.
fn Parser::parse_top(self : Parser, flags : Flags) -> Query raise QueryError {
  let query = self.parse_binary(ModifierState::new(flags), PRECEDENCE_OR)
  match self.peek().kind() {
    Eos =>
      if query is MatchAll && !(flags.kind is AnyKind) {
        Query::Term(Term::new(TermBody::Kind(flags.kind)))
      } else {
        query
      }
    RParen =>
      if self.compat {
        Query::MatchNone
      } else {
        raise Parse(self.peek().pos(), "unmatched ')'")
      }
    kind => raise Parse(self.peek().pos(), "unexpected \{kind.describe()}")
  }
}

///|
/// Parse a binary expression whose operators bind at least `min_precedence`.
///
/// Implicit `AND` is recognized when the next token can start a primary; it has
/// the same precedence as an explicit `AND`. A binary operator with no operand
/// after it is dropped so that `foo AND` still means `foo`.
fn Parser::parse_binary(
  self : Parser,
  state : ModifierState,
  min_precedence : Int32,
) -> Query raise QueryError {
  let mut left = self.parse_not(state)
  while true {
    let kind = self.peek().kind()
    let explicit = match kind {
      And => Some(AndOp)
      Or => Some(OrOp)
      _ => None
    }
    let operator = match explicit {
      Some(operator) => operator
      None => if kind.starts_primary() { AndOp } else { break }
    }
    if explicit is Some(_) && !self.peek_at(1).kind().starts_primary() {
      ignore(self.advance())
      continue
    }
    let precedence = if operator is OrOp {
      PRECEDENCE_OR
    } else {
      PRECEDENCE_AND
    }
    if precedence < min_precedence {
      break
    }
    if explicit is Some(_) {
      ignore(self.advance())
    }
    let right = self.parse_binary(state, precedence + 1)
    left = match operator {
      AndOp => make_and(left, right)
      OrOp => make_or(left, right)
    }
  }
  left
}

///|
/// Build an AND, folding the neutral element and absorbing the empty set.
///
/// The empty query (`MatchAll`) is what an empty macro expands to, and
/// `MatchNone` is what compat error recovery produces; folding them here keeps
/// both from cluttering the tree without changing meaning.
fn make_and(left : Query, right : Query) -> Query {
  if left is MatchAll {
    right
  } else if right is MatchAll {
    left
  } else if left is MatchNone || right is MatchNone {
    MatchNone
  } else {
    And(left, right)
  }
}

///|
/// Build an OR, folding the empty set and the empty query.
fn make_or(left : Query, right : Query) -> Query {
  if left is MatchNone {
    right
  } else if right is MatchNone {
    left
  } else if left is MatchAll || right is MatchAll {
    MatchAll
  } else {
    Or(left, right)
  }
}

///|
/// Build a negation, folding the two constants.
fn make_not(query : Query) -> Query {
  if query is MatchAll {
    MatchNone
  } else if query is MatchNone {
    MatchAll
  } else {
    Not(query)
  }
}

///|
/// Parse an optionally negated primary.
///
/// Consecutive `NOT` tokens cancel in pairs. A `NOT` with nothing to negate, or
/// a binary operator with no left operand, is ignored.
fn Parser::parse_not(
  self : Parser,
  state : ModifierState,
) -> Query raise QueryError {
  let mut negations = 0
  while true {
    match self.peek().kind() {
      Not => {
        negations = negations + 1
        ignore(self.advance())
      }
      And | Or =>
        // An operator in operand position has no left side. Drop it and keep
        // looking for something a primary can start with.
        ignore(self.advance())
      _ => break
    }
  }
  if !self.peek().kind().starts_primary() {
    return Query::MatchAll
  }
  let query = self.parse_primary(state)
  if negations % 2 == 1 {
    make_not(query)
  } else {
    query
  }
}

///|
/// Parse one primary expression.
///
/// Modifiers are prefix operators: they update the flag state and recurse into
/// the primary they apply to. A parenthesized group inherits the state by value,
/// so modifiers inside the group cannot leak out.
fn Parser::parse_primary(
  self : Parser,
  state : ModifierState,
) -> Query raise QueryError {
  let token = self.peek()
  match token.kind() {
    LParen => {
      ignore(self.advance())
      self.depth = self.depth + 1
      if self.depth > MAX_QUERY_DEPTH {
        raise Parse(token.pos(), "the query nests too deeply")
      }
      let inner = self.parse_binary(state, PRECEDENCE_OR)
      self.depth = self.depth - 1
      match self.peek().kind() {
        RParen => {
          ignore(self.advance())
          inner
        }
        Eos => raise Parse(token.pos(), "unclosed '('")
        kind =>
          raise Parse(
            self.peek().pos(),
            "expected ')', found \{kind.describe()}",
          )
      }
    }
    Word(text) => {
      ignore(self.advance())
      Query::Term(
        Term::new(TermBody::Name(text), flags=name_flags(text, state)),
      )
    }
    Field(name) | FieldEmpty(name) => {
      ignore(self.advance())
      self.parse_field_or_modifier(name, token.pos(), state)
    }
    Not => {
      // Only reachable after a modifier: the ordinary path consumes NOT in
      // `parse_not`. Apply the flags to the negated primary so `file:!x`
      // remains a name search restricted to files.
      let mut negations = 0
      while self.peek().kind() is Not {
        negations = negations + 1
        ignore(self.advance())
      }
      if !self.peek().kind().starts_primary() {
        return Query::MatchAll
      }
      let inner = self.parse_primary(state)
      if negations % 2 == 1 {
        make_not(inner)
      } else {
        inner
      }
    }
    And | Or => {
      // Stray operators with no left operand; skip the whole run.
      while self.peek().kind().is_binary_operator() {
        ignore(self.advance())
      }
      self.parse_primary(state)
    }
    Eos | RParen => Query::MatchAll
    kind => raise Parse(token.pos(), "unexpected \{kind.describe()}")
  }
}

///|
/// Resolve the flags of a name term.
///
/// `MIGRATION_PLAN.md` section 5.10.6 makes two behaviors term-local: a needle
/// containing `/` searches the full path, and a needle containing a non-ASCII
/// uppercase letter becomes case-sensitive. An explicit `path:`/`nopath:` or
/// `case:`/`nocase:` always wins.
fn name_flags(text : String, state : ModifierState) -> Flags {
  let mut flags = state.flags
  if !state.path_explicit && text.contains_char('/') {
    flags = flags.with_search_path(true)
  }
  if !state.case_explicit && contains_non_ascii_upper(text) {
    flags = flags.with_case_sensitive(true)
  }
  flags
}

///|
/// Dispatch a `name:` token to a macro, a modifier, or a field function, in
/// that order.
fn Parser::parse_field_or_modifier(
  self : Parser,
  name : String,
  name_pos : Int32,
  state : ModifierState,
) -> Query raise QueryError {
  let lower = ascii_lower_string(name)
  match self.macros.get(lower) {
    Some(entry) => return self.expand_macro(lower, entry, name_pos)
    None => ()
  }
  match lower {
    "case" => self.parse_primary(state.with_case(true))
    "nocase" => self.parse_primary(state.with_case(false))
    "exact" => self.parse_primary(state.with_exact(true))
    "file" | "files" => self.kind_modifier(FilesOnly, state)
    "folder" | "folders" => self.kind_modifier(FoldersOnly, state)
    "path" => self.parse_primary(state.with_path(true))
    "nopath" => self.parse_primary(state.with_path(false))
    "regex" => self.parse_primary(state.with_regex(true))
    "noregex" => self.parse_primary(state.with_regex(false))
    _ => self.parse_function(lower, name, name_pos, state)
  }
}

///|
/// Apply `file:` or `folder:`.
///
/// With a following term or group the kind becomes a term flag. With nothing to
/// apply to, as in a bare `file:`, it becomes a standalone kind term so the
/// filter still means something.
fn Parser::kind_modifier(
  self : Parser,
  kind : KindFilter,
  state : ModifierState,
) -> Query raise QueryError {
  if self.peek().kind().starts_primary() {
    self.parse_primary(state.with_kind(kind))
  } else {
    Query::Term(Term::new(TermBody::Kind(kind)))
  }
}

///|
/// Report a bad field value, or match nothing in compat mode.
fn Parser::bad_value(
  self : Parser,
  pos : Int32,
  field : String,
  value : String,
  message : String,
) -> Query raise QueryError {
  if self.compat {
    Query::MatchNone
  } else {
    raise BadValue(pos, field, value, message)
  }
}

///|
/// Report a missing field value, or match nothing in compat mode.
fn Parser::missing_value(
  self : Parser,
  pos : Int32,
  field : String,
) -> Query raise QueryError {
  if self.compat {
    Query::MatchNone
  } else {
    raise BadValue(pos, field, "", "expected a value")
  }
}

///|
/// Report an unknown field, or match nothing in compat mode.
fn Parser::unknown_field(
  self : Parser,
  pos : Int32,
  name : String,
) -> Query raise QueryError {
  if self.compat {
    Query::MatchNone
  } else {
    raise Parse(pos, "unknown field '\{name}:'")
  }
}
