///|
/// Byte-level helpers shared by the scanner, the index, and the matchers.
///
/// Unix file names are arbitrary byte streams, so the hot paths work on
/// `BytesView` and never decode to `String`. The ASCII helpers cover the only
/// case folding this version performs; Unicode folding is deferred.

///|
/// Whether `byte` is an ASCII decimal digit (`0` through `9`).
pub fn is_ascii_digit(byte : Byte) -> Bool {
  byte >= b'0' && byte <= b'9'
}

///|
/// Whether `byte` is an ASCII uppercase letter (`A` through `Z`).
pub fn is_ascii_upper(byte : Byte) -> Bool {
  byte >= b'A' && byte <= b'Z'
}

///|
/// Whether `byte` is an ASCII lowercase letter (`a` through `z`).
pub fn is_ascii_lower(byte : Byte) -> Bool {
  byte >= b'a' && byte <= b'z'
}

///|
/// Whether `byte` is an ASCII letter.
pub fn is_ascii_alpha(byte : Byte) -> Bool {
  is_ascii_upper(byte) || is_ascii_lower(byte)
}

///|
/// Fold one ASCII uppercase letter to lowercase.
///
/// Every other byte, including non-ASCII bytes, is returned unchanged.
pub fn ascii_lower(byte : Byte) -> Byte {
  if is_ascii_upper(byte) {
    (byte.to_int() + 32).to_byte()
  } else {
    byte
  }
}

///|
/// Fold one ASCII lowercase letter to uppercase.
///
/// Every other byte, including non-ASCII bytes, is returned unchanged.
pub fn ascii_upper(byte : Byte) -> Byte {
  if is_ascii_lower(byte) {
    (byte.to_int() - 32).to_byte()
  } else {
    byte
  }
}

///|
/// Return a copy of `view` with ASCII uppercase letters folded to lowercase.
///
/// Non-ASCII bytes are preserved verbatim. This is the folding used by the
/// trigram index and by case-insensitive name matching.
pub fn ascii_fold(view : BytesView) -> Bytes {
  let buffer = @buffer.Buffer(size_hint=view.length())
  for byte in view.iter() {
    buffer.write_byte(ascii_lower(byte))
  }
  buffer.to_bytes()
}

///|
/// Compare two byte sequences for equality after ASCII case folding.
pub fn eq_ignore_ascii_case(left : BytesView, right : BytesView) -> Bool {
  if left.length() != right.length() {
    return false
  }
  let mut i = 0
  while i < left.length() {
    if ascii_lower(left[i]) != ascii_lower(right[i]) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Whether `view` starts with `prefix`.
///
/// An empty prefix matches every view.
pub fn starts_with(view : BytesView, prefix : BytesView) -> Bool {
  if prefix.length() > view.length() {
    return false
  }
  let mut i = 0
  while i < prefix.length() {
    if view[i] != prefix[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Whether `view` ends with `suffix`.
///
/// An empty suffix matches every view.
pub fn ends_with(view : BytesView, suffix : BytesView) -> Bool {
  if suffix.length() > view.length() {
    return false
  }
  let offset = view.length() - suffix.length()
  let mut i = 0
  while i < suffix.length() {
    if view[offset + i] != suffix[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Index of the first occurrence of `byte` at or after `from`, or `None`.
///
/// A negative `from` is treated as zero; a `from` at or past the end returns
/// `None`.
pub fn find_byte(view : BytesView, byte : Byte, from~ : Int32 = 0) -> Int32? {
  let mut i = if from < 0 { 0 } else { from }
  while i < view.length() {
    if view[i] == byte {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// Index of the first occurrence of `needle` at or after `from`, or `None`.
///
/// An empty needle matches at `from` (clamped into the view). This is the
/// straightforward scan used by cold paths; the matchers use a
/// Boyer–Moore–Horspool variant.
pub fn find_bytes(
  view : BytesView,
  needle : BytesView,
  from~ : Int32 = 0,
) -> Int32? {
  let start = if from < 0 {
    0
  } else if from > view.length() {
    view.length()
  } else {
    from
  }
  let needle_len = needle.length()
  if needle_len == 0 {
    return Some(start)
  }
  let last_start = view.length() - needle_len
  let mut i = start
  while i <= last_start {
    if view[i] == needle[0] {
      let mut matched = 1
      while matched < needle_len && view[i + matched] == needle[matched] {
        matched = matched + 1
      }
      if matched == needle_len {
        return Some(i)
      }
    }
    i = i + 1
  }
  None
}

///|
/// Whether `needle` occurs anywhere in `view`.
pub fn contains_bytes(view : BytesView, needle : BytesView) -> Bool {
  find_bytes(view, needle) is Some(_)
}

///|
/// Whether two byte sequences are equal, optionally folding ASCII case.
pub fn eq_bytes(left : BytesView, right : BytesView, fold : Bool) -> Bool {
  if left.length() != right.length() {
    return false
  }
  if !fold {
    return left == right
  }
  eq_ignore_ascii_case(left, right)
}

///|
/// Index of the first occurrence of `needle` at or after `from`, optionally
/// folding ASCII case.
///
/// The matcher is deliberately the same straightforward scan as `find_bytes`:
/// candidates have already been narrowed by the index, and keeping the two
/// implementations identical makes the oracle and the verification path agree
/// byte for byte.
pub fn find_bytes_with(
  view : BytesView,
  needle : BytesView,
  fold : Bool,
  from~ : Int32 = 0,
) -> Int32? {
  if !fold {
    return find_bytes(view, needle, from~)
  }
  let start = if from < 0 {
    0
  } else if from > view.length() {
    view.length()
  } else {
    from
  }
  let needle_len = needle.length()
  if needle_len == 0 {
    return Some(start)
  }
  let last_start = view.length() - needle_len
  let mut i = start
  while i <= last_start {
    if ascii_lower(view[i]) == ascii_lower(needle[0]) {
      let mut matched = 1
      while matched < needle_len &&
            ascii_lower(view[i + matched]) == ascii_lower(needle[matched]) {
        matched = matched + 1
      }
      if matched == needle_len {
        return Some(i)
      }
    }
    i = i + 1
  }
  None
}

///|
/// Whether `needle` occurs anywhere in `view`, optionally folding ASCII case.
pub fn contains_bytes_with(
  view : BytesView,
  needle : BytesView,
  fold : Bool,
) -> Bool {
  find_bytes_with(view, needle, fold) is Some(_)
}

///|
/// Whether a glob pattern contains an unescaped `*` or `?`.
///
/// The query layer uses this to decide between substring matching and the glob
/// matcher. A backslash escapes the next byte, so `\*` is a literal asterisk.
pub fn has_glob_meta(pattern : BytesView) -> Bool {
  let mut i = 0
  while i < pattern.length() {
    let byte = pattern[i]
    if byte == b'\\' {
      i = i + 2
    } else if byte == b'*' || byte == b'?' {
      return true
    } else {
      i = i + 1
    }
  }
  false
}
