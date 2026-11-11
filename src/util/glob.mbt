///|
/// Match a whole byte string against a glob pattern.
///
/// The pattern language is deliberately small:
///
/// - `*` matches any run of bytes, including none and including `/`;
/// - `?` matches exactly one byte;
/// - `\` makes the next byte literal, so `\*` matches a literal asterisk;
/// - every other byte matches itself, case-sensitively.
///
/// The match is anchored at both ends: the whole `text` must be consumed. This
/// is the matcher used by exclude rules; it works on raw bytes so invalid UTF-8
/// names keep working.
///
/// The implementation keeps a backtracking point at the most recent `*`, which
/// gives linear scanning in the common case and quadratic time only for
/// pathological patterns. No recursion is used, so a long pattern cannot
/// overflow the stack.
pub fn glob_match(text : BytesView, pattern : BytesView) -> Bool {
  let text_len = text.length()
  let pattern_len = pattern.length()
  let mut ti = 0
  let mut pi = 0
  let mut star_pi = -1
  let mut star_ti = 0
  while ti < text_len {
    let mut matched = false
    if pi < pattern_len {
      let pattern_byte = pattern[pi]
      if pattern_byte == b'*' {
        star_pi = pi
        star_ti = ti
        pi = pi + 1
        continue
      } else if pattern_byte == b'?' {
        ti = ti + 1
        pi = pi + 1
        matched = true
      } else if pattern_byte == b'\\' && pi + 1 < pattern_len {
        if pattern[pi + 1] == text[ti] {
          ti = ti + 1
          pi = pi + 2
          matched = true
        }
      } else if pattern_byte == text[ti] {
        ti = ti + 1
        pi = pi + 1
        matched = true
      }
    }
    if matched {
      continue
    }
    if star_pi >= 0 {
      star_ti = star_ti + 1
      ti = star_ti
      pi = star_pi + 1
    } else {
      return false
    }
  }
  // Trailing stars may still be unmatched, but nothing else can be.
  while pi < pattern_len && pattern[pi] == b'*' {
    pi = pi + 1
  }
  pi == pattern_len
}
