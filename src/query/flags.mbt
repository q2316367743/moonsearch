///|
/// Which entry kinds a term is allowed to match.
///
/// `AnyKind` is the default. `file:` and `folder:` narrow a term or a whole
/// parenthesized group; a term that can only match the other kind is pruned to
/// the empty set when the query is compiled.
pub(all) enum KindFilter {
  AnyKind
  FilesOnly
  FoldersOnly
}

///|
/// Canonical text of a kind filter, used by `describe` and diagnostics.
pub fn KindFilter::describe(self : KindFilter) -> String {
  match self {
    AnyKind => "any"
    FilesOnly => "file"
    FoldersOnly => "folder"
  }
}

///|
/// Term-level matching options.
///
/// The parser starts from the flags supplied by the caller (the CLI's
/// `--case-sensitive`, `--exact`, `--search-path`, `--regex`, and `--type`
/// options) and lets prefix modifiers override them for the following term or
/// group. Term-level modifiers are local: a `case:` written inside a group does
/// not leak out of it.
///
/// Two behaviors are decided per term after modifiers are applied (see
/// `MIGRATION_PLAN.md` section 5.10.6):
///
/// - a needle containing `/` searches the full path unless `nopath:` was
///   written explicitly;
/// - a needle containing a non-ASCII uppercase letter becomes case-sensitive
///   unless `nocase:` was written explicitly, because this version only folds
///   ASCII case.
pub(all) struct Flags {
  case_sensitive : Bool
  exact : Bool
  search_path : Bool
  regex : Bool
  kind : KindFilter
}

///|
/// Build a flag set, defaulting to case-insensitive substring search over
/// names of any kind.
pub fn Flags::new(
  case_sensitive~ : Bool = false,
  exact~ : Bool = false,
  search_path~ : Bool = false,
  regex~ : Bool = false,
  kind~ : KindFilter = AnyKind,
) -> Flags {
  { case_sensitive, exact, search_path, regex, kind, }
}

///|
/// Copy with a different case-sensitivity setting.
pub fn Flags::with_case_sensitive(self : Flags, value : Bool) -> Flags {
  { ..self, case_sensitive: value, }
}

///|
/// Copy with a different exact-match setting.
pub fn Flags::with_exact(self : Flags, value : Bool) -> Flags {
  { ..self, exact: value, }
}

///|
/// Copy with a different path-search setting.
pub fn Flags::with_search_path(self : Flags, value : Bool) -> Flags {
  { ..self, search_path: value, }
}

///|
/// Copy with a different regex setting.
pub fn Flags::with_regex(self : Flags, value : Bool) -> Flags {
  { ..self, regex: value, }
}

///|
/// Copy with a different kind filter.
pub fn Flags::with_kind(self : Flags, value : KindFilter) -> Flags {
  { ..self, kind: value, }
}

///|
/// Whether every flag is at its default value.
pub fn Flags::is_default(self : Flags) -> Bool {
  !self.case_sensitive &&
  !self.exact &&
  !self.search_path &&
  !self.regex &&
  self.kind is AnyKind
}

///|
/// Text form of the non-default flags, for `describe`.
///
/// The result is a space-separated list such as `"case exact kind=file"`, or an
/// empty string when every flag is default.
pub fn Flags::describe(self : Flags) -> String {
  let parts : Array[String] = []
  if self.case_sensitive {
    parts.push("case")
  }
  if self.exact {
    parts.push("exact")
  }
  if self.search_path {
    parts.push("path")
  }
  if self.regex {
    parts.push("regex")
  }
  if !(self.kind is AnyKind) {
    parts.push("kind=\{self.kind.describe()}")
  }
  parts.join(" ")
}

///|
/// Whether the text contains a character this version cannot case-fold.
///
/// The v1 matcher folds ASCII only, so a term written with a non-ASCII
/// uppercase letter would silently stop matching its lowercase form. Such terms
/// switch to case-sensitive matching. The check is a deliberately conservative
/// range test for the common scripts: missing a rare uppercase letter only
/// leaves the term case-insensitive, which is what the matcher supports anyway.
/// Full Unicode category tables are a later step.
fn contains_non_ascii_upper(text : StringView) -> Bool {
  for char in text.iter() {
    let code = char.to_int()
    if code > 0x7F && is_common_upper(code) {
      return true
    }
  }
  false
}

///|
/// Uppercase letters from the Latin, Greek, and Cyrillic blocks.
///
/// Latin Extended-A and the extended Cyrillic runs are not one simple
/// alternating range: their case pairing switches direction part way through
/// the block. The ranges below follow the actual Unicode pairings for the
/// common blocks this version claims to detect.
fn is_common_upper(code : Int32) -> Bool {
  // Latin-1 Supplement: À-Ö and Ø-Þ.
  if (code >= 0x00C0 && code <= 0x00D6) || (code >= 0x00D8 && code <= 0x00DE) {
    return true
  }
  // Latin Extended-A: even/odd runs, with ĸ, ŉ, and ſ left lowercase.
  if code >= 0x0100 && code <= 0x0137 {
    return code % 2 == 0
  }
  if code >= 0x0139 && code <= 0x0148 {
    return code % 2 == 1
  }
  if code >= 0x014A && code <= 0x0177 {
    return code % 2 == 0
  }
  if code == 0x0178 || code == 0x0179 || code == 0x017B || code == 0x017D {
    return true
  }
  // Greek: Ά, Έ-Ί, Ό, Ύ-Ώ, Α-Ρ, Σ-Ϋ.
  if code == 0x0386 ||
    (code >= 0x0388 && code <= 0x038A) ||
    code == 0x038C ||
    (code >= 0x038E && code <= 0x038F) ||
    (code >= 0x0391 && code <= 0x03A1) ||
    (code >= 0x03A3 && code <= 0x03AB) {
    return true
  }
  // Cyrillic: А-Я, Ѐ-Џ.
  if code >= 0x0400 && code <= 0x042F {
    return true
  }
  // Extended Cyrillic pairs; Ӂ-ӎ pair in the opposite direction.
  if (code >= 0x0460 && code <= 0x0481) && code % 2 == 0 {
    return true
  }
  if (code >= 0x048A && code <= 0x04BF) && code % 2 == 0 {
    return true
  }
  if code == 0x04C0 {
    return true
  }
  if (code >= 0x04C1 && code <= 0x04CE) && code % 2 == 1 {
    return true
  }
  if (code >= 0x04D0 && code <= 0x04FF) && code % 2 == 0 {
    return true
  }
  if (code >= 0x0500 && code <= 0x052F) && code % 2 == 0 {
    return true
  }
  // Fullwidth Latin capitals.
  code >= 0xFF21 && code <= 0xFF3A
}
