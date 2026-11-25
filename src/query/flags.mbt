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
/// Which entries a term is allowed to match by visibility.
///
/// `AnyVisibility` is the default. `hidden:` and `nohidden:` narrow a term or a
/// parenthesized group, mirroring the `file:` / `folder:` kind modifiers. The
/// field dictionary stores the hidden entries as one bitmap, so the indexed
/// engine can turn the filter into an intersection or a difference.
pub(all) enum VisibilityFilter {
  AnyVisibility
  HiddenOnly
  VisibleOnly
}

///|
/// Canonical text of a visibility filter, used by `describe` and diagnostics.
pub fn VisibilityFilter::describe(self : VisibilityFilter) -> String {
  match self {
    AnyVisibility => "any"
    HiddenOnly => "hidden"
    VisibleOnly => "visible"
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
  visibility : VisibilityFilter
}

///|
/// Build a flag set, defaulting to case-insensitive substring search over
/// names of any kind and visibility.
pub fn Flags::new(
  case_sensitive~ : Bool = false,
  exact~ : Bool = false,
  search_path~ : Bool = false,
  regex~ : Bool = false,
  kind~ : KindFilter = AnyKind,
  visibility~ : VisibilityFilter = AnyVisibility,
) -> Flags {
  { case_sensitive, exact, search_path, regex, kind, visibility, }
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
/// Copy with a different visibility filter.
pub fn Flags::with_visibility(self : Flags, value : VisibilityFilter) -> Flags {
  { ..self, visibility: value, }
}

///|
/// Apply the term-level automatic path and case rules to a whole-query name.
///
/// This is the same rule the parser applies to a bare word:
///
/// - a name containing `/` searches the full path;
/// - a name containing a non-ASCII uppercase letter becomes case-sensitive,
///   because this version folds ASCII case only.
///
/// The CLI uses it for `--regex`, where the whole query bypasses the parser and
/// therefore never passes through `Parser::name_flags`. Explicit `--search-path`
/// and `--case-sensitive` already set the flag, so they still win.
pub fn Flags::with_name_heuristics(self : Flags, text : StringView) -> Flags {
  let mut flags = self
  if !flags.search_path && text.contains_char('/') {
    flags = flags.with_search_path(true)
  }
  if !flags.case_sensitive && contains_non_ascii_upper(text) {
    flags = flags.with_case_sensitive(true)
  }
  flags
}

///|
/// Whether every flag is at its default value.
pub fn Flags::is_default(self : Flags) -> Bool {
  !self.case_sensitive &&
  !self.exact &&
  !self.search_path &&
  !self.regex &&
  self.kind is AnyKind &&
  self.visibility is AnyVisibility
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
  if !(self.visibility is AnyVisibility) {
    parts.push(self.visibility.describe())
  }
  parts.join(" ")
}

///|
/// Whether the text contains a character this version cannot case-fold.
///
/// The v1 matcher folds ASCII only, so a term written with a non-ASCII
/// uppercase letter would silently stop matching its lowercase form. Such terms
/// switch to case-sensitive matching. The check is a range test for the scripts
/// this version documents: Latin (including Extended-A/B/Additional), Greek
/// (including Extended), Cyrillic, Armenian, Georgian, Glagolitic, and
/// fullwidth Latin. Missing a rare uppercase letter only leaves the term
/// case-insensitive, which is what the matcher supports anyway. Full Unicode
/// category tables are a later step.
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
/// Uppercase letters from the Latin, Greek, and Cyrillic blocks, plus the other
/// scripts this version documents.
///
/// Latin Extended-A, Latin Extended-B, and the extended Cyrillic runs are not
/// single simple alternating ranges: their case pairing switches direction part
/// way through the block. The ranges below follow the actual Unicode pairings
/// for the blocks this version claims to detect.
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
  // Latin Extended-B has irregular capital positions.
  if is_latin_ext_b_upper(code) {
    return true
  }
  // Greek: Ά, Έ-Ί, Ό, Ύ-Ώ, Α-Ρ, Σ-Ϋ.
  if code == 0x0386 ||
    (code >= 0x0388 && code <= 0x038A) ||
    code == 0x038C ||
    (code >= 0x038E && code <= 0x038F) ||
    (code >= 0x0391 && code <= 0x03A1) ||
    (code >= 0x03A3 && code <= 0x03AB) ||
    (code >= 0x03D2 && code <= 0x03D4) {
    return true
  }
  if (code >= 0x03D8 && code <= 0x03EF) && code % 2 == 0 {
    return true
  }
  if code == 0x03F4 || code == 0x03F7 || code == 0x03F9 || code == 0x03FA {
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
  // Armenian capitals.
  if code >= 0x0531 && code <= 0x0556 {
    return true
  }
  // Georgian Mkhedruli capitals and Mtavruli.
  if (code >= 0x10A0 && code <= 0x10C5) || code == 0x10C7 || code == 0x10CD {
    return true
  }
  if code >= 0x1C90 && code <= 0x1CBA {
    return true
  }
  // Latin Extended Additional alternates capitals at even code points.
  if code >= 0x1E00 && code <= 0x1EFF && code % 2 == 0 {
    return true
  }
  // Greek Extended capitals.
  if (code >= 0x1F08 && code <= 0x1F0F) ||
    (code >= 0x1F18 && code <= 0x1F1D) ||
    (code >= 0x1F28 && code <= 0x1F2F) ||
    (code >= 0x1F38 && code <= 0x1F3F) ||
    (code >= 0x1F48 && code <= 0x1F4D) ||
    code == 0x1F59 ||
    code == 0x1F5B ||
    code == 0x1F5D ||
    code == 0x1F5F ||
    (code >= 0x1F68 && code <= 0x1F6F) ||
    (code >= 0x1F88 && code <= 0x1F8F) ||
    (code >= 0x1F98 && code <= 0x1F9F) ||
    (code >= 0x1FA8 && code <= 0x1FAF) ||
    (code >= 0x1FB8 && code <= 0x1FBC) ||
    (code >= 0x1FC8 && code <= 0x1FCB) ||
    (code >= 0x1FD8 && code <= 0x1FDB) ||
    (code >= 0x1FE8 && code <= 0x1FEC) ||
    (code >= 0x1FF8 && code <= 0x1FFB) {
    return true
  }
  // Glagolitic capitals.
  if code >= 0x2C00 && code <= 0x2C2E {
    return true
  }
  // Cyrillic Extended-B and Latin Extended-D/E alternating capital runs.
  if (code >= 0xA640 && code <= 0xA66D) && code % 2 == 0 {
    return true
  }
  if (code >= 0xA680 && code <= 0xA69B) && code % 2 == 0 {
    return true
  }
  if (code >= 0xA722 && code <= 0xA72F) && code % 2 == 0 {
    return true
  }
  if (code >= 0xA732 && code <= 0xA76F) && code % 2 == 0 {
    return true
  }
  if (code >= 0xA790 && code <= 0xA7AE) && code % 2 == 0 {
    return true
  }
  // Fullwidth Latin capitals.
  code >= 0xFF21 && code <= 0xFF3A
}

///|
/// Latin Extended-B capitals.
///
/// The block mixes pairs that advance by one with capitals that stand alone, so
/// the positions are listed rather than derived from parity.
fn is_latin_ext_b_upper(code : Int32) -> Bool {
  (code >= 0x0181 && code <= 0x0182) ||
  code == 0x0184 ||
  (code >= 0x0186 && code <= 0x0187) ||
  (code >= 0x0189 && code <= 0x018B) ||
  (code >= 0x018E && code <= 0x0191) ||
  (code >= 0x0193 && code <= 0x0194) ||
  (code >= 0x0196 && code <= 0x0198) ||
  (code >= 0x019C && code <= 0x019D) ||
  (code >= 0x019F && code <= 0x01A0) ||
  code == 0x01A2 ||
  code == 0x01A4 ||
  (code >= 0x01A6 && code <= 0x01A7) ||
  code == 0x01A9 ||
  code == 0x01AC ||
  (code >= 0x01AE && code <= 0x01AF) ||
  (code >= 0x01B1 && code <= 0x01B3) ||
  code == 0x01B5 ||
  (code >= 0x01B7 && code <= 0x01B8) ||
  code == 0x01BC ||
  code == 0x01C4 ||
  code == 0x01C7 ||
  code == 0x01CA ||
  ((code >= 0x01CD && code <= 0x01DB) && code % 2 == 1) ||
  ((code >= 0x01DE && code <= 0x01EE) && code % 2 == 0) ||
  code == 0x01F1 ||
  code == 0x01F4 ||
  (code >= 0x01F6 && code <= 0x01F8) ||
  code == 0x01FA ||
  code == 0x01FC ||
  code == 0x01FE ||
  ((code >= 0x0200 && code <= 0x0216) && code % 2 == 0) ||
  ((code >= 0x0218 && code <= 0x0232) && code % 2 == 0) ||
  (code >= 0x023A && code <= 0x023B) ||
  (code >= 0x023D && code <= 0x023E) ||
  code == 0x0241 ||
  (code >= 0x0243 && code <= 0x0244) ||
  ((code >= 0x0246 && code <= 0x024E) && code % 2 == 0)
}
