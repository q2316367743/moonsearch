///|
/// How an exclude pattern is interpreted.
pub(all) enum ExcludeKind {
  /// Compare the subject byte for byte.
  Fixed
  /// Shell-style wildcard match (`*`, `?`, and `\` escapes).
  Glob
  /// Regular expression match. Accepted by the rule model but not implemented
  /// yet; the CLI rejects such rules when parsing options.
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
/// Rules are evaluated by the scanner before an entry is added. The subject is
/// raw bytes, so a rule never needs to decode a name. `pattern` is kept as text
/// for `--explain`-style diagnostics while `pattern_bytes` is what matching
/// uses.
pub struct ExcludeRule {
  priv kind : ExcludeKind
  priv scope : ExcludeScope
  priv target : ExcludeTarget
  priv pattern : String
  priv pattern_bytes : Bytes
  priv active : Bool
}

///|
/// Build a rule from an explicit kind and pattern.
pub fn ExcludeRule::new(
  kind~ : ExcludeKind,
  pattern~ : StringView,
  scope~ : ExcludeScope = FullPath,
  target~ : ExcludeTarget = Both,
  active~ : Bool = true,
) -> ExcludeRule {
  {
    kind,
    scope,
    target,
    pattern: "\{pattern}",
    pattern_bytes: @utf8.encode(pattern),
    active,
  }
}

///|
/// Build a rule from a command-line specification.
///
/// A leading `fixed:`, `glob:`, or `regex:` selects the kind; without a prefix
/// the pattern is a glob. Glob is the default because a pattern without
/// wildcards matches exactly, so literal names keep working and `*.tmp` does
/// what the user expects.
///
/// Raises `UnsupportedExclude` for `regex:` because the query regex engine
/// arrives in a later step.
pub fn ExcludeRule::parse(
  spec : StringView,
  scope~ : ExcludeScope = FullPath,
  target~ : ExcludeTarget = Both,
) -> ExcludeRule raise IndexError {
  let text = "\{spec}"
  if starts_with_literal(spec, "fixed:") {
    ExcludeRule::new(kind=Fixed, pattern=spec[6:], scope~, target~)
  } else if starts_with_literal(spec, "glob:") {
    ExcludeRule::new(kind=Glob, pattern=spec[5:], scope~, target~)
  } else if starts_with_literal(spec, "regex:") {
    raise UnsupportedExclude(
      "regex exclude rules are not implemented yet: \{text}",
    )
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
  path : StringView,
  name : StringView,
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
  let subject_bytes = @utf8.encode(subject)
  match self.kind {
    Fixed => subject_bytes == self.pattern_bytes
    Glob => @util.glob_match(subject_bytes[:], self.pattern_bytes[:])
    Regex => false
  }
}

///|
/// Whether any rule in the list excludes the entry.
fn any_rule_matches(
  rules : ArrayView[ExcludeRule],
  path : StringView,
  name : StringView,
  is_dir : Bool,
) -> Bool {
  for rule in rules {
    if rule.matches(path, name, is_dir) {
      return true
    }
  }
  false
}
