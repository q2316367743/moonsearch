///|
/// Parse a field that takes a value.
fn Parser::parse_function(
  self : Parser,
  field : String,
  name : String,
  name_pos : Int32,
  state : ModifierState,
) -> Query raise QueryError {
  match field {
    "ext" =>
      match self.next_value() {
        None =>
          // An empty extension list selects files without an extension.
          Query::Term(Term::new(TermBody::Extensions([""]), flags=state.flags))
        Some(raw) =>
          match raw.op {
            Some(op) =>
              self.bad_value(
                raw.pos,
                name,
                raw.text,
                "an extension list does not take the operator '\{op.symbol()}'",
              )
            None =>
              Query::Term(
                Term::new(
                  TermBody::Extensions(split_extensions(raw.text)),
                  flags=state.flags,
                ),
              )
          }
      }
    "size" =>
      match self.next_value() {
        None => self.missing_value(name_pos, name)
        Some(raw) => {
          let comparison = numeric_comparison(
            raw, parse_size, parse_size_comparison,
          )
          match comparison {
            Some(comparison) =>
              Query::Term(
                Term::new(TermBody::Size(comparison), flags=state.flags),
              )
            None =>
              self.bad_value(
                raw.pos,
                name,
                raw.text,
                "expected a size such as 1kb, >10mb, or 1kb..2mb",
              )
          }
        }
      }
    "dm" | "datemodified" =>
      match self.next_value() {
        None => self.missing_value(name_pos, name)
        Some(raw) => {
          let comparison = match raw.op {
            Some(op) =>
              if raw.text.is_empty() || has_range_separator(raw.text) {
                None
              } else {
                Some(DateComparison::new(op, lo=raw.text))
              }
            None => parse_date_comparison(raw.text)
          }
          match comparison {
            Some(comparison) =>
              Query::Term(
                Term::new(TermBody::Modified(comparison), flags=state.flags),
              )
            None =>
              self.bad_value(
                raw.pos,
                name,
                raw.text,
                "expected a date such as today, 2024-01, or lastweek..yesterday",
              )
          }
        }
      }
    "depth" | "parents" =>
      self.count_term(name, name_pos, state, fn(comparison) {
        TermBody::Depth(comparison)
      })
    "childcount" =>
      self.count_term(name, name_pos, state, fn(comparison) {
        TermBody::ChildCount(comparison)
      })
    "childfilecount" =>
      self.count_term(name, name_pos, state, fn(comparison) {
        TermBody::ChildFileCount(comparison)
      })
    "childfoldercount" =>
      self.count_term(name, name_pos, state, fn(comparison) {
        TermBody::ChildFolderCount(comparison)
      })
    "parent" =>
      match self.next_value() {
        None => self.missing_value(name_pos, name)
        Some(raw) =>
          match raw.op {
            Some(op) =>
              self.bad_value(
                raw.pos,
                name,
                raw.text,
                "parent: does not take the operator '\{op.symbol()}'",
              )
            None =>
              Query::Term(
                Term::new(TermBody::Parent(raw.text), flags=state.flags),
              )
          }
      }
    "contenttype" =>
      match self.next_value() {
        None => self.missing_value(name_pos, name)
        Some(raw) =>
          match raw.op {
            Some(op) =>
              self.bad_value(
                raw.pos,
                name,
                raw.text,
                "contenttype: does not take the operator '\{op.symbol()}'",
              )
            None =>
              Query::Term(
                Term::new(
                  TermBody::ContentType(ascii_lower_string(raw.text)),
                  flags=state.flags,
                ),
              )
          }
      }
    "empty" =>
      // `empty:` takes no value; a word written after it is a separate term.
      Query::Term(Term::new(TermBody::Empty, flags=state.flags))
    _ => {
      // Consume the would-be value so compat mode does not turn it into a
      // stray name term.
      self.skip_field_value()
      self.unknown_field(name_pos, name)
    }
  }
}

///|
/// Parse a numeric field such as `depth:` or `childcount:`.
fn Parser::count_term(
  self : Parser,
  name : String,
  name_pos : Int32,
  state : ModifierState,
  make : (Comparison) -> TermBody,
) -> Query raise QueryError {
  match self.next_value() {
    None => self.missing_value(name_pos, name)
    Some(raw) => {
      let comparison = numeric_comparison(
        raw, parse_count, parse_count_comparison,
      )
      match comparison {
        Some(comparison) =>
          Query::Term(Term::new(make(comparison), flags=state.flags))
        None =>
          self.bad_value(
            raw.pos,
            name,
            raw.text,
            "expected a whole number, a comparison, or a range",
          )
      }
    }
  }
}

///|
/// Read the value tokens of a field.
///
/// Returns `None` when no value follows. An explicit operator without an
/// operand is a syntax error. The caller decides whether a missing value is
/// meaningful (`ext:`) or an error.
fn Parser::next_value(self : Parser) -> RawValue? raise QueryError {
  let kind = self.peek().kind()
  let explicit_op = match kind {
    Equal => Some(CmpOp::Equal)
    Greater => Some(CmpOp::Greater)
    GreaterEqual => Some(CmpOp::GreaterEqual)
    Smaller => Some(CmpOp::Smaller)
    SmallerEqual => Some(CmpOp::SmallerEqual)
    _ => None
  }
  match explicit_op {
    Some(op) => {
      let operator_pos = self.peek().pos()
      ignore(self.advance())
      match self.peek().kind() {
        Word(text) => {
          let value_pos = self.peek().pos()
          ignore(self.advance())
          Some({ op: Some(op), text, pos: value_pos, })
        }
        found =>
          raise Parse(
            operator_pos,
            "expected a value after '\{op.symbol()}', found \{found.describe()}",
          )
      }
    }
    None =>
      match kind {
        Word(text) => {
          let value_pos = self.peek().pos()
          ignore(self.advance())
          Some({ op: None, text, pos: value_pos, })
        }
        _ => None
      }
  }
}

///|
/// Consume an optional comparison operator and value without interpreting it.
///
/// Unknown fields still own the value written after their colon; consuming it
/// keeps compat mode from turning that value into a stray name term. A run of
/// comparison operators is consumed as well, so malformed input such as
/// `unknown:==x` still degrades to the empty set instead of failing.
fn Parser::skip_field_value(self : Parser) -> Unit {
  while true {
    match self.peek().kind() {
      Equal | Greater | GreaterEqual | Smaller | SmallerEqual =>
        ignore(self.advance())
      _ => break
    }
  }
  match self.peek().kind() {
    Word(_) => ignore(self.advance())
    _ => ()
  }
}

///|
/// Build a comparison from a raw value and a scalar parser.
fn numeric_comparison(
  raw : RawValue,
  scalar : (StringView) -> Int64?,
  implicit : (StringView) -> Comparison?,
) -> Comparison? {
  match raw.op {
    Some(op) =>
      match scalar(raw.text) {
        Some(value) => Some(Comparison::compare(op, value))
        None => None
      }
    None => implicit(raw.text)
  }
}

///|
/// Split an extension list on `;`, ASCII-lowercasing and trimming each entry.
///
/// An empty entry is preserved: `ext:jpg;` means "jpg or no extension".
fn split_extensions(text : StringView) -> Array[String] {
  let result : Array[String] = []
  let length = text.length()
  let mut start = 0
  let mut index = 0
  while index < length {
    if text.get_char(index) is Some(';') {
      result.push(ascii_lower_string(trim_ascii_space(text[start:index])))
      start = index + 1
    }
    index = index + 1
  }
  result.push(ascii_lower_string(trim_ascii_space(text[start:length])))
  result
}

///|
/// Trim ASCII whitespace from both ends of a view.
fn trim_ascii_space(text : StringView) -> StringView {
  let mut start = 0
  let mut end = text.length()
  while start < end {
    match text.get_char(start) {
      Some(char) => if is_ascii_space(char) { start = start + 1 } else { break }
      None => break
    }
  }
  while end > start {
    match text.get_char(end - 1) {
      Some(char) => if is_ascii_space(char) { end = end - 1 } else { break }
      None => break
    }
  }
  text[start:end]
}
