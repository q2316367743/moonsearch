///|
test "only primary-starting kinds start a primary" {
  assert_true(@query.TokenKind::Word("x").starts_primary())
  assert_true(@query.TokenKind::Field("size").starts_primary())
  assert_true(@query.TokenKind::FieldEmpty("size").starts_primary())
  assert_true(@query.TokenKind::LParen.starts_primary())
  assert_true(@query.TokenKind::Not.starts_primary())
  assert_false(@query.TokenKind::And.starts_primary())
  assert_false(@query.TokenKind::Or.starts_primary())
  assert_false(@query.TokenKind::Equal.starts_primary())
  assert_false(@query.TokenKind::Greater.starts_primary())
  assert_false(@query.TokenKind::GreaterEqual.starts_primary())
  assert_false(@query.TokenKind::Smaller.starts_primary())
  assert_false(@query.TokenKind::SmallerEqual.starts_primary())
  assert_false(@query.TokenKind::RParen.starts_primary())
  assert_false(@query.TokenKind::Eos.starts_primary())
}

///|
test "only AND and OR are binary operators" {
  assert_true(@query.TokenKind::And.is_binary_operator())
  assert_true(@query.TokenKind::Or.is_binary_operator())
  assert_false(@query.TokenKind::Not.is_binary_operator())
  assert_false(@query.TokenKind::Word("AND").is_binary_operator())
  assert_false(@query.TokenKind::LParen.is_binary_operator())
  assert_false(@query.TokenKind::Eos.is_binary_operator())
}

///|
test "token kinds describe themselves for diagnostics" {
  assert_eq(@query.TokenKind::Word("x").describe(), "'x'")
  assert_eq(@query.TokenKind::Field("size").describe(), "'size:'")
  assert_eq(@query.TokenKind::FieldEmpty("file").describe(), "'file:'")
  assert_eq(@query.TokenKind::And.describe(), "AND")
  assert_eq(@query.TokenKind::Or.describe(), "OR")
  assert_eq(@query.TokenKind::Not.describe(), "NOT")
  assert_eq(@query.TokenKind::Equal.describe(), "'='")
  assert_eq(@query.TokenKind::Greater.describe(), "'>'")
  assert_eq(@query.TokenKind::GreaterEqual.describe(), "'>='")
  assert_eq(@query.TokenKind::Smaller.describe(), "'<'")
  assert_eq(@query.TokenKind::SmallerEqual.describe(), "'<='")
  assert_eq(@query.TokenKind::LParen.describe(), "'('")
  assert_eq(@query.TokenKind::RParen.describe(), "')'")
  assert_eq(@query.TokenKind::Eos.describe(), "end of query")
}
