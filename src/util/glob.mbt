///|
/// Match a whole byte string against a glob pattern.
///
/// The pattern language is deliberately small:
///
/// - `*` matches any run of bytes, including none and including `/`;
/// - `?` matches exactly one Unicode scalar value: an ASCII byte, a complete
///   multi-byte UTF-8 sequence, or one invalid byte;
/// - `\` makes the next byte literal, so `\*` matches a literal asterisk;
/// - every other byte matches itself, case-sensitively.
///
/// The match is anchored at both ends: the whole `text` must be consumed. This
/// is the matcher used by the query and exclude layers; it works on raw bytes
/// so invalid UTF-8 names keep working.
pub fn glob_match(text : BytesView, pattern : BytesView) -> Bool {
  glob_match_with(text, pattern, false)
}

///|
/// Match a whole byte string against a glob pattern, optionally folding ASCII
/// case.
///
/// Folding is applied to both sides on every comparison, including the literal
/// byte after a backslash. The implementation keeps a backtracking point at the
/// most recent `*`, which gives linear scanning in the common case and
/// quadratic time only for pathological patterns. No recursion is used, so a
/// long pattern cannot overflow the stack.
pub fn glob_match_with(
  text : BytesView,
  pattern : BytesView,
  fold : Bool,
) -> Bool {
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
        ti = ti + scalar_width(text, ti)
        pi = pi + 1
        matched = true
      } else if pattern_byte == b'\\' && pi + 1 < pattern_len {
        if glob_byte_eq(pattern[pi + 1], text[ti], fold) {
          ti = ti + 1
          pi = pi + 2
          matched = true
        }
      } else if glob_byte_eq(pattern_byte, text[ti], fold) {
        ti = ti + 1
        pi = pi + 1
        matched = true
      }
    }
    if matched {
      continue
    }
    if star_pi >= 0 {
      // Backtrack one scalar, not one byte, so `?` after `*` never starts in
      // the middle of a multi-byte sequence.
      if star_ti < text_len {
        star_ti = star_ti + scalar_width(text, star_ti)
      }
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

///|
/// Width in bytes of the Unicode scalar starting at `pos`.
///
/// A leading byte with no complete, valid continuation is one invalid byte, so
/// `?` still consumes exactly one unit of malformed input.
fn scalar_width(text : BytesView, pos : Int32) -> Int32 {
  let length = text.length()
  if pos < 0 || pos >= length {
    return 1
  }
  let first = text[pos].to_int()
  if first < 0x80 {
    return 1
  }
  if first < 0xC2 {
    return 1
  }
  if first < 0xE0 {
    if pos + 1 < length && is_continuation(text, pos + 1) {
      return 2
    }
    return 1
  }
  if first < 0xF0 {
    if pos + 2 < length &&
      is_continuation(text, pos + 1) &&
      is_continuation(text, pos + 2) {
      let code = ((first & 0x0F) << 12) |
        ((text[pos + 1].to_int() & 0x3F) << 6) |
        (text[pos + 2].to_int() & 0x3F)
      if code >= 0x800 && !(code >= 0xD800 && code <= 0xDFFF) {
        return 3
      }
    }
    return 1
  }
  if first < 0xF5 {
    if pos + 3 < length &&
      is_continuation(text, pos + 1) &&
      is_continuation(text, pos + 2) &&
      is_continuation(text, pos + 3) {
      let code = ((first & 0x07) << 18) |
        ((text[pos + 1].to_int() & 0x3F) << 12) |
        ((text[pos + 2].to_int() & 0x3F) << 6) |
        (text[pos + 3].to_int() & 0x3F)
      if code >= 0x10000 && code <= 0x10FFFF {
        return 4
      }
    }
    return 1
  }
  1
}

///|
/// Whether the byte at `pos` is a UTF-8 continuation byte.
fn is_continuation(text : BytesView, pos : Int32) -> Bool {
  (text[pos].to_int() & 0xC0) == 0x80
}

///|
/// Compare two glob bytes, folding ASCII case when requested.
fn glob_byte_eq(left : Byte, right : Byte, fold : Bool) -> Bool {
  if fold {
    ascii_lower(left) == ascii_lower(right)
  } else {
    left == right
  }
}
