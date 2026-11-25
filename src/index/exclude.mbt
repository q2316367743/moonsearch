///|
/// How an exclude pattern is interpreted.
pub(all) enum ExcludeKind {
  /// Compare the subject byte for byte.
  Fixed
  /// Shell-style wildcard match (`*`, `?`, and `\` escapes).
  Glob
  /// Regular expression match using the query regex compiler and syntax.
  Regex
}

///|
/// Which string a rule is matched against.
pub(all) enum ExcludeScope {
  /// The full path of the entry.
  FullPath
  /// The last path component only.
  Basename
}

///|
/// Which kinds of entry a rule applies to.
pub(all) enum ExcludeTarget {
  Both
  Files
  Folders
}

///|
/// One exclude rule.
///
/// Rules are evaluated by the scanner before an entry is added. Fixed and glob
/// rules match raw bytes and never decode a name. Regex rules reuse the query
/// compiler, so their subjects must be valid UTF-8. `pattern` is kept as text
/// for diagnostics while `pattern_bytes` is what fixed/glob matching uses.
pub struct ExcludeRule {
  priv kind : ExcludeKind
  priv scope : ExcludeScope
  priv target : ExcludeTarget
  priv pattern : String
  priv pattern_bytes : Bytes
  priv regex : @query.RegexPattern?
  priv active : Bool
}

///|
/// Build a rule from an explicit kind and pattern.
///
/// Regex patterns compile once, with case-sensitive matching like fixed/glob
/// excludes. Invalid patterns raise the same `QueryError::BadRegex` used by
/// query terms. Inactive rules are still validated so a typo cannot hide in a
/// disabled rule.
pub fn ExcludeRule::new(
  kind~ : ExcludeKind,
  pattern~ : StringView,
  scope~ : ExcludeScope = FullPath,
  target~ : ExcludeTarget = Both,
  active~ : Bool = true,
) -> ExcludeRule raise @query.QueryError {
  let regex = match kind {
    Regex => Some(@query.compile_regex(pattern, case_sensitive=true))
    _ => None
  }
  {
    kind,
    scope,
    target,
    pattern: "\{pattern}",
    pattern_bytes: @utf8.encode(pattern),
    regex,
    active,
  }
}

///|
/// Build a rule from a command-line specification.
///
/// A leading `fixed:`, `glob:`, or `regex:` selects the kind; without a prefix
/// the pattern is a glob. Glob is the default because a pattern without
/// wildcards matches exactly, so literal names keep working and `*.tmp` does
/// what the user expects. Regex errors use the query error model.
pub fn ExcludeRule::parse(
  spec : StringView,
  scope~ : ExcludeScope = FullPath,
  target~ : ExcludeTarget = Both,
) -> ExcludeRule raise @query.QueryError {
  if starts_with_literal(spec, "fixed:") {
    ExcludeRule::new(kind=Fixed, pattern=spec[6:], scope~, target~)
  } else if starts_with_literal(spec, "glob:") {
    ExcludeRule::new(kind=Glob, pattern=spec[5:], scope~, target~)
  } else if starts_with_literal(spec, "regex:") {
    ExcludeRule::new(kind=Regex, pattern=spec[6:], scope~, target~)
  } else {
    ExcludeRule::new(kind=Glob, pattern=spec, scope~, target~)
  }
}

///|
/// Whether `text` starts with the literal ASCII `prefix`.
///
/// Kept local so the rule parser does not need to encode the subject.
fn starts_with_literal(text : StringView, prefix : StringView) -> Bool {
  if prefix.length() > text.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if text.get_char(i) != prefix.get_char(i) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// The pattern text, for diagnostics.
pub fn ExcludeRule::pattern(self : ExcludeRule) -> String {
  self.pattern
}

///|
/// The pattern interpretation.
pub fn ExcludeRule::kind(self : ExcludeRule) -> ExcludeKind {
  self.kind
}

///|
/// The matched scope.
pub fn ExcludeRule::scope(self : ExcludeRule) -> ExcludeScope {
  self.scope
}

///|
/// The matched entry kinds.
pub fn ExcludeRule::target(self : ExcludeRule) -> ExcludeTarget {
  self.target
}

///|
/// Whether this rule is currently active.
pub fn ExcludeRule::is_active(self : ExcludeRule) -> Bool {
  self.active
}

///|
/// Test whether an entry is excluded.
///
/// `path` and `name` are the entry's full path and last component. `is_dir`
/// selects the target filter: a `Folders` rule never matches a file and vice
/// versa. An inactive rule never matches.
pub fn ExcludeRule::matches(
  self : ExcludeRule,
  path : BytesView,
  name : BytesView,
  is_dir : Bool,
) -> Bool {
  if !self.active {
    return false
  }
  let target_matches = match self.target {
    Both => true
    Files => !is_dir
    Folders => is_dir
  }
  if !target_matches {
    return false
  }
  let subject = match self.scope {
    FullPath => path
    Basename => name
  }
  match self.kind {
    Fixed => @util.eq_bytes(subject, self.pattern_bytes, false)
    Glob => @util.glob_match(subject, self.pattern_bytes[:])
    Regex =>
      match self.regex {
        Some(regex) => regex.matches_bytes(subject)
        None => false
      }
  }
}

///|
/// Whether any rule in the list excludes the entry.
fn any_rule_matches(
  rules : ArrayView[ExcludeRule],
  path : BytesView,
  name : BytesView,
  is_dir : Bool,
) -> Bool {
  for rule in rules {
    if rule.matches(path, name, is_dir) {
      return true
    }
  }
  false
}
