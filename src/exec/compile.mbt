///|
/// A query compiled into the form the linear scan engine evaluates.
///
/// Compilation resolves everything that does not depend on the entry being
/// tested: flags become a matcher kind, a regex is compiled once, extensions and
/// parent paths become bytes, and date expressions are resolved against the
/// current clock and time zone. The result is a tree of pure predicates over
/// `(Store, EntryRef)`.
priv enum ScanExpr {
  All
  None
  Test(ScanTerm)
  And(ScanExpr, ScanExpr)
  Or(ScanExpr, ScanExpr)
  Not(ScanExpr)
}

///|
/// One leaf predicate plus the kind and visibility filters that apply to it.
priv struct ScanTerm {
  kind : @query.KindFilter
  visibility : @query.VisibilityFilter
  body : ScanTest
}

///|
/// What a leaf predicate tests.
priv enum ScanTest {
  Name(NameMatcher)
  Kind(@query.KindFilter)
  Visibility(@query.VisibilityFilter)
  /// A built-in category macro together with its extension list, prepared once
  /// so evaluation does not rebuild the list per entry.
  Category(@util.TypeCategory, Array[Bytes])
  Extensions(Array[Bytes])
  Size(@query.Comparison)
  Depth(@query.Comparison)
  ChildCount(@query.Comparison)
  ChildFileCount(@query.Comparison)
  ChildFolderCount(@query.Comparison)
  /// `dm:` resolved to absolute Unix seconds.
  Modified(@query.Comparison)
  Parent(Bytes)
  Empty
  ContentType(String)
}

///|
/// How a name term is matched.
priv enum NameKind {
  Substring
  Exact
  Glob
  Regex
}

///|
/// A name term prepared for repeated evaluation.
///
/// `needle` keeps the original UTF-8 bytes for diagnostics; `fold` says whether
/// comparisons fold ASCII case. A regex is compiled once at query time.
priv struct NameMatcher {
  kind : NameKind
  needle : Bytes
  fold : Bool
  path : Bool
  regex : @string.Regex?
}

///|
/// Compile a query for the scan engine.
fn compile_query(
  query : @query.Query,
  now : Int64,
  zone : @time.Zone,
) -> ScanExpr raise @query.QueryError {
  match query {
    @query.MatchAll => All
    @query.MatchNone => None
    @query.Term(term) => Test(compile_term(term, now, zone))
    @query.And(left, right) => {
      let compiled_left = compile_query(left, now, zone)
      let compiled_right = compile_query(right, now, zone)
      match (compiled_left, compiled_right) {
        (None, _) | (_, None) => None
        (All, expr) | (expr, All) => expr
        _ => And(compiled_left, compiled_right)
      }
    }
    @query.Or(left, right) => {
      let compiled_left = compile_query(left, now, zone)
      let compiled_right = compile_query(right, now, zone)
      match (compiled_left, compiled_right) {
        (All, _) | (_, All) => All
        (None, expr) | (expr, None) => expr
        _ => Or(compiled_left, compiled_right)
      }
    }
    @query.Not(inner) =>
      match compile_query(inner, now, zone) {
        All => None
        None => All
        expr => Not(expr)
      }
  }
}

///|
/// Compile one term.
fn compile_term(
  term : @query.Term,
  now : Int64,
  zone : @time.Zone,
) -> ScanTerm raise @query.QueryError {
  let flags = term.flags()
  let body = match term.body() {
    @query.Name(text) => ScanTest::Name(compile_name(text, flags))
    @query.Kind(kind) => ScanTest::Kind(kind)
    @query.Visibility(filter) => ScanTest::Visibility(filter)
    @query.TypeCategory(category) =>
      ScanTest::Category(category, category_extensions(category))
    @query.Extensions(list) => {
      let extensions : Array[Bytes] = []
      for extension in list {
        extensions.push(@utf8.encode(extension))
      }
      ScanTest::Extensions(extensions)
    }
    @query.Size(comparison) => ScanTest::Size(comparison)
    @query.Modified(comparison) =>
      ScanTest::Modified(resolve_date_comparison(comparison, now, zone))
    @query.Depth(comparison) => ScanTest::Depth(comparison)
    @query.ChildCount(comparison) => ScanTest::ChildCount(comparison)
    @query.ChildFileCount(comparison) => ScanTest::ChildFileCount(comparison)
    @query.ChildFolderCount(comparison) =>
      ScanTest::ChildFolderCount(comparison)
    @query.Parent(path) => ScanTest::Parent(normalize_parent(path))
    @query.Empty => ScanTest::Empty
    @query.ContentType(text) => ScanTest::ContentType(text)
  }
  { kind: flags.kind, visibility: flags.visibility, body, }
}

///|
/// Encode a category's extension list once for the scan predicate.
fn category_extensions(category : @util.TypeCategory) -> Array[Bytes] {
  let extensions : Array[Bytes] = []
  for extension in category.extensions() {
    extensions.push(@utf8.encode(extension))
  }
  extensions
}

///|
/// Prepare a name term.
fn compile_name(
  text : String,
  flags : @query.Flags,
) -> NameMatcher raise @query.QueryError {
  let needle = @utf8.encode(text)
  let path = flags.search_path
  if flags.regex {
    let pattern = if flags.case_sensitive {
      text
    } else {
      // The v1 matcher folds ASCII only; `(?i:...)` gives the regex engine the
      // same case-insensitive behavior as the substring paths.
      "(?i:\{text})"
    }
    let compiled = Ok(@string.Regex::Regex(pattern)) catch { _ => Err(()) }
    match compiled {
      Ok(regex) =>
        {
          kind: Regex,
          needle,
          fold: !flags.case_sensitive,
          path,
          regex: Some(regex),
        }
      Err(_) => raise @query.bad_regex(text)
    }
  } else if flags.exact {
    { kind: Exact, needle, fold: !flags.case_sensitive, path, regex: None, }
  } else if @util.has_glob_meta(needle[:]) {
    { kind: Glob, needle, fold: !flags.case_sensitive, path, regex: None, }
  } else {
    { kind: Substring, needle, fold: !flags.case_sensitive, path, regex: None, }
  }
}

///|
/// Resolve a date comparison into an absolute numeric comparison.
///
/// A date names a calendar unit, so the operators apply to that unit's interval
/// `[start, end)`: `dm:>2020` starts at the end of 2020, while `dm:>=2020`
/// starts at its beginning. A range keeps the plan's half-open convention with
/// the two lower bounds.
fn resolve_date_comparison(
  comparison : @query.DateComparison,
  now : Int64,
  zone : @time.Zone,
) -> @query.Comparison raise @query.QueryError {
  match comparison.op {
    @query.Equal => {
      let span = resolve_date_text(comparison.lo, now, zone)
      @query.Comparison::range(span.start, span.end)
    }
    @query.Greater =>
      @query.Comparison::compare(
        @query.GreaterEqual,
        resolve_date_text(comparison.lo, now, zone).end,
      )
    @query.GreaterEqual =>
      @query.Comparison::compare(
        @query.GreaterEqual,
        resolve_date_text(comparison.lo, now, zone).start,
      )
    @query.Smaller =>
      @query.Comparison::compare(
        @query.Smaller,
        resolve_date_text(comparison.lo, now, zone).start,
      )
    @query.SmallerEqual =>
      @query.Comparison::compare(
        @query.Smaller,
        resolve_date_text(comparison.lo, now, zone).end,
      )
    @query.Range => {
      let lo = if comparison.lo.is_empty() {
        0L
      } else {
        resolve_date_text(comparison.lo, now, zone).start
      }
      let hi = if comparison.hi.is_empty() {
        9223372036854775807L
      } else {
        resolve_date_text(comparison.hi, now, zone).start
      }
      @query.Comparison::range(lo, hi)
    }
  }
}

///|
/// Resolve date text or report a query error.
fn resolve_date_text(
  text : String,
  now : Int64,
  zone : @time.Zone,
) -> @util.DateSpan raise @query.QueryError {
  match @util.resolve_date_span(text, now, zone) {
    Some(span) => span
    None =>
      raise @query.bad_value(
        0, "dm", text, "expected a date such as today, 2024-01, or lastweek..yesterday",
      )
  }
}

///|
/// Turn a `parent:` path into the bytes compared against a folder path.
///
/// One trailing slash is the difference between `parent:/home/user/` and the
/// stored `/home/user`; every trailing slash is dropped except for the root
/// itself.
fn normalize_parent(path : String) -> Bytes {
  let bytes = @utf8.encode(path)
  let mut end = bytes.length()
  while end > 1 && bytes[end - 1] == b'/' {
    end = end - 1
  }
  bytes[:end].to_owned()
}

///|
/// Human-readable plan, used by `--explain` and by tests.
fn explain_expr(expr : ScanExpr) -> String {
  match expr {
    All => "all"
    None => "none"
    Test(term) => explain_term(term)
    And(left, right) => "(and \{explain_expr(left)} \{explain_expr(right)})"
    Or(left, right) => "(or \{explain_expr(left)} \{explain_expr(right)})"
    Not(inner) => "(not \{explain_expr(inner)})"
  }
}

///|
/// Human-readable form of one term.
fn explain_term(term : ScanTerm) -> String {
  let body = match term.body {
    Name(matcher) =>
      match matcher.kind {
        Substring =>
          "(substring \{quote_bytes(matcher.needle)} \{matcher_flags(matcher)})"
        Exact =>
          "(exact \{quote_bytes(matcher.needle)} \{matcher_flags(matcher)})"
        Glob =>
          "(glob \{quote_bytes(matcher.needle)} \{matcher_flags(matcher)})"
        Regex =>
          "(regex \{quote_bytes(matcher.needle)} \{matcher_flags(matcher)})"
      }
    Kind(kind) => "(kind \{kind.describe()})"
    Visibility(filter) => "(visibility \{filter.describe()})"
    Category(category, _) => "(type \{category.name()})"
    Extensions(list) => {
      let parts : Array[String] = []
      for extension in list {
        parts.push(quote_bytes(extension))
      }
      "(ext \{parts.join(" ")})"
    }
    Size(comparison) => "(size \{comparison.describe()})"
    Depth(comparison) => "(depth \{comparison.describe()})"
    ChildCount(comparison) => "(childcount \{comparison.describe()})"
    ChildFileCount(comparison) => "(childfilecount \{comparison.describe()})"
    ChildFolderCount(comparison) =>
      "(childfoldercount \{comparison.describe()})"
    Modified(comparison) => "(dm \{comparison.describe()})"
    Parent(path) => "(parent \{quote_bytes(path)})"
    Empty => "(empty)"
    ContentType(text) => "(contenttype \{quote_text(text)})"
  }
  let prefix : Array[String] = []
  if !(term.kind is @query.AnyKind) {
    prefix.push(term.kind.describe())
  }
  if !(term.visibility is @query.AnyVisibility) {
    prefix.push(term.visibility.describe())
  }
  if prefix.is_empty() {
    body
  } else {
    "(\{prefix.join(" ")} \{body})"
  }
}

///|
/// Flags that affect how a name matcher compares.
fn matcher_flags(matcher : NameMatcher) -> String {
  let parts : Array[String] = []
  if matcher.fold {
    parts.push("nocase")
  } else {
    parts.push("case")
  }
  if matcher.path {
    parts.push("path")
  }
  parts.join(" ")
}

///|
/// Quote bytes as an ASCII string for diagnostics.
fn quote_bytes(bytes : BytesView) -> String {
  quote_text(@utf8.decode_lossy(bytes))
}

///|
/// Quote text for `describe`-style output.
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
