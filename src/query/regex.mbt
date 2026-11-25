///|
/// A regular expression compiled once for repeated name or path matching.
///
/// Query terms and exclude rules share this compiler so they use the same
/// MoonBit regex syntax and the same `QueryError::BadRegex` failure model.
pub struct RegexPattern {
  priv regex : @string.Regex
}

///|
/// Compile a regular expression, optionally folding ASCII case.
///
/// Case-insensitive matching is implemented with the engine's `(?i:...)`
/// grouping, preserving the query layer's ASCII-only folding semantics. Errors
/// always report the original pattern, not the case-folding wrapper.
pub fn compile_regex(
  pattern : StringView,
  case_sensitive~ : Bool = false,
) -> RegexPattern raise QueryError {
  let prepared = if case_sensitive { "\{pattern}" } else { "(?i:\{pattern})" }
  let regex = @string.Regex::Regex(prepared) catch {
    _ => raise bad_regex(pattern)
  }
  { regex, }
}

///|
/// Match raw entry bytes with the compiled expression.
///
/// The query regex engine is Unicode/string based. Invalid UTF-8 subjects are
/// therefore non-matches, exactly as they are for query regex terms; fixed and
/// glob excludes continue to compare arbitrary bytes directly.
pub fn RegexPattern::matches_bytes(
  self : RegexPattern,
  text : BytesView,
) -> Bool {
  let decoded = @utf8.decode(text) catch { _ => return false }
  self.regex.execute(decoded) is Some(_)
}
