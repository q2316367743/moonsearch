///|
/// Expand a macro into its parsed query.
///
/// The expansion uses its own token stream and parser, so the macro's text can
/// contain any query syntax. The active-name stack detects direct and indirect
/// cycles. Errors inside a macro are reported at the use site with the inner
/// message attached.
fn Parser::expand_macro(
  self : Parser,
  key : String,
  entry : Macro,
  pos : Int32,
) -> Query raise QueryError {
  if self.active.contains(key) {
    raise MacroCycle(pos, entry.name)
  }
  if self.depth + 1 > MAX_QUERY_DEPTH {
    raise Parse(pos, "the query nests too deeply")
  }
  self.active.push(key)
  try
    parse_macro_query(
      entry,
      self.macros,
      self.compat,
      self.active,
      self.depth + 1,
    )
  catch {
    err => {
      ignore(self.active.pop())
      match err {
        // A cycle is reported as such no matter how deep it was detected;
        // wrapping it in each enclosing macro would hide the cause.
        MacroCycle(cycle_pos, cycle_name) =>
          raise MacroCycle(cycle_pos, cycle_name)
        _ => raise MacroError(pos, entry.name, err.message())
      }
    }
  } noraise {
    query => {
      ignore(self.active.pop())
      query
    }
  }
}

///|
/// Parse a macro's own query with the macro's flags.
fn parse_macro_query(
  entry : Macro,
  macros : Macros,
  compat : Bool,
  active : Array[String],
  depth : Int32,
) -> Query raise QueryError {
  let parser : Parser = {
    tokens: lex(entry.query),
    index: 0,
    macros,
    compat,
    active,
    depth,
  }
  parser.parse_top(entry.flags)
}
