///|
/// A parsed query.
///
/// The AST keeps the user's structure: boolean combinators, negation, and
/// leaves that name what to match. It contains no candidate sets and no
/// execution strategy; compiling it into set algebra is a later step.
///
/// `MatchAll` is the empty query and the neutral element of `And`.
/// `MatchNone` is produced only by `--compat` error recovery, where a malformed
/// field or a stray `)` matches nothing instead of failing.
pub enum Query {
  MatchAll
  MatchNone
  Term(Term)
  And(Query, Query)
  Or(Query, Query)
  Not(Query)
}

///|
/// One leaf of the query tree: a name search or a field predicate, together
/// with the flags that apply to it.
pub struct Term {
  priv flags : Flags
  priv body : TermBody
}

///|
/// Assemble a term from its body and flags.
pub fn Term::new(body : TermBody, flags~ : Flags = Flags::new()) -> Term {
  { flags, body, }
}

///|
/// Build a query consisting of one name term.
///
/// `Query` and `TermBody` constructors are read-only outside this package, so
/// the CLI and the execution layer build the few trees they need through
/// helpers such as this one.
pub fn name_query(text : StringView, flags~ : Flags = Flags::new()) -> Query {
  Query::Term(Term::new(TermBody::Name("\{text}"), flags~))
}

///|
/// Build a query consisting of one standalone kind term.
pub fn kind_query(kind : KindFilter) -> Query {
  Query::Term(Term::new(TermBody::Kind(kind)))
}

///|
/// Flags that apply to this term.
pub fn Term::flags(self : Term) -> Flags {
  self.flags
}

///|
/// What the term matches.
pub fn Term::body(self : Term) -> TermBody {
  self.body
}

///|
/// The payload of a term.
///
/// Name searches keep the needle as text; the predicate layer encodes it to
/// UTF-8 bytes to match against the byte-oriented index. Date bounds stay text
/// because resolving them needs a calendar and a time zone.
pub enum TermBody {
  /// A bare word or quoted phrase, matched as a substring, a whole name, a
  /// glob, or a regular expression depending on the term flags.
  Name(String)
  /// A standalone kind filter, produced by `file:` or `folder:` with no
  /// following term. Any other term carries its kind in its flags instead.
  Kind(KindFilter)
  /// `ext:` — a list of extensions, ASCII-lowercased. An empty entry stands
  /// for a file without an extension.
  Extensions(Array[String])
  /// `size:` — bytes.
  Size(Comparison)
  /// `dm:` / `datemodified:` — modification time.
  Modified(DateComparison)
  /// `depth:` / `parents:`.
  Depth(Comparison)
  /// `childcount:`.
  ChildCount(Comparison)
  /// `childfilecount:`.
  ChildFileCount(Comparison)
  /// `childfoldercount:`.
  ChildFolderCount(Comparison)
  /// `parent:` — an exact parent directory path.
  Parent(String)
  /// `empty:` — a folder without children.
  Empty
  /// `contenttype:` — a MIME type or type prefix.
  ContentType(String)
}

///|
/// Compact, unambiguous text form of the tree.
///
/// This is a diagnostic form for tests and `--explain`-style output: `*` is the
/// empty query, `none` the empty set, and each term lists its body followed by
/// its non-default flags.
pub fn Query::describe(self : Query) -> String {
  match self {
    MatchAll => "*"
    MatchNone => "none"
    Term(term) => term.describe()
    And(left, right) => "(and \{left.describe()} \{right.describe()})"
    Or(left, right) => "(or \{left.describe()} \{right.describe()})"
    Not(inner) => "(not \{inner.describe()})"
  }
}

///|
/// Compact text form of one term.
pub fn Term::describe(self : Term) -> String {
  let parts : Array[String] = match self.body {
    Name(text) => ["name", quote_text(text)]
    Kind(kind) => ["kind", kind.describe()]
    Extensions(list) => {
      let parts = ["ext"]
      for extension in list {
        parts.push(quote_text(extension))
      }
      parts
    }
    Size(comparison) => ["size", comparison.describe()]
    Modified(comparison) => ["dm", comparison.describe()]
    Depth(comparison) => ["depth", comparison.describe()]
    ChildCount(comparison) => ["childcount", comparison.describe()]
    ChildFileCount(comparison) => ["childfilecount", comparison.describe()]
    ChildFolderCount(comparison) => ["childfoldercount", comparison.describe()]
    Parent(path) => ["parent", quote_text(path)]
    Empty => ["empty"]
    ContentType(text) => ["contenttype", quote_text(text)]
  }
  let flag_text = self.flags.describe()
  if flag_text.length() > 0 {
    parts.push(flag_text)
  }
  "(\{parts.join(" ")})"
}

///|
/// Quote text for `describe`, escaping backslashes and double quotes.
fn quote_text(text : StringView) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for char in text.iter() {
    if char == '"' {
      out.write_string("\\\"")
    } else if char == '\\' {
      out.write_string("\\\\")
    } else {
      out.write_char(char)
    }
  }
  out.write_char('"')
  out.to_string()
}
