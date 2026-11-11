///|
/// Join a directory path and a child name with exactly one separator.
///
/// An empty parent yields the name itself; a parent that already ends with `/`
/// is not given a second separator, so joining `/` and `tmp` gives `/tmp`
/// rather than `//tmp`.
pub fn join_path(parent : StringView, name : StringView) -> String {
  if parent.is_empty() {
    "\{name}"
  } else if parent.get_char(parent.length() - 1) is Some('/') {
    "\{parent}\{name}"
  } else {
    "\{parent}/\{name}"
  }
}

///|
/// Whether `path` names a direct or indirect child of `ancestor`.
///
/// Both paths are expected to be normalized absolute paths. The comparison is
/// component-wise: `/home/user2` is not inside `/home/user`, while `/home/user`
/// and `/home/user/docs` are both inside `/home/user`. A root of `/` contains
/// every other absolute path.
pub fn is_within(ancestor : StringView, path : StringView) -> Bool {
  if ancestor.is_empty() || path.is_empty() {
    return false
  }
  if ancestor == path {
    return true
  }
  let ancestor_len = ancestor.length()
  if ancestor_len == 1 && ancestor.get_char(0) is Some('/') {
    return path.get_char(0) is Some('/')
  }
  if path.length() <= ancestor_len {
    return false
  }
  let mut i = 0
  while i < ancestor_len {
    if path.get_char(i) != ancestor.get_char(i) {
      return false
    }
    i = i + 1
  }
  path.get_char(ancestor_len) is Some('/')
}

///|
/// Natural ordering for byte paths.
///
/// Paths are compared byte by byte with two exceptions:
///
/// 1. `\0` (end of string) weighs 0 and `/` weighs 1, so a path separator
///    sorts before every other byte. This keeps `a/b` before `a.b` and makes a
///    path component boundary compare before any character inside a component.
/// 2. Consecutive ASCII digits are compared numerically (`file2` < `file10`).
///    Leading zeros follow the `strverscmp` convention: a run that starts with
///    `0` is treated as a fractional part and compared digit by digit, which
///    is why `007` < `07` < `7` and `09` > `010`.
///
/// Bytes outside ASCII are compared as raw bytes, so valid UTF-8 keeps code
/// point order and invalid UTF-8 still has a deterministic order. The function
/// returns exactly `-1`, `0`, or `1`.
///
/// A byte view used as a path must not contain an embedded NUL: a NUL is read
/// as the end of the path.
pub fn cmp_paths(left : BytesView, right : BytesView) -> Int32 {
  let left_len = left.length()
  let right_len = right.length()
  let mut i = 0
  let mut j = 0
  let mut state = Normal
  while i < left_len || j < right_len {
    let left_byte = if i < left_len { left[i] } else { b'\x00' }
    let right_byte = if j < right_len { right[j] } else { b'\x00' }
    if left_byte == right_byte {
      if left_byte == b'\x00' {
        return 0
      }
      state = next_nat_state(state, left_byte)
      i = i + 1
      j = j + 1
    } else {
      return compare_at_difference(
        state, left, i, right, j, left_byte, right_byte,
      )
    }
  }
  0
}

///|
/// Digit-run state while comparing two paths.
///
/// `Zeros` covers a run that has only seen leading zeros, `Fraction` a run
/// that started with zeros and has since seen a nonzero digit, and `Integer` a
/// run that started with a nonzero digit.
priv enum NatState {
  Normal
  Integer
  Fraction
  Zeros
}

///|
/// Advance the digit-run state by one equal byte.
fn next_nat_state(state : NatState, byte : Byte) -> NatState {
  match state {
    Normal =>
      if byte == b'0' {
        Zeros
      } else if is_ascii_digit(byte) {
        Integer
      } else {
        Normal
      }
    Integer => if is_ascii_digit(byte) { Integer } else { Normal }
    Fraction => if is_ascii_digit(byte) { Fraction } else { Normal }
    Zeros =>
      if byte == b'0' {
        Zeros
      } else if is_ascii_digit(byte) {
        Fraction
      } else {
        Normal
      }
  }
}

///|
/// Weight of a byte in path order: end of string, then `/`, then the byte.
fn path_byte_weight(byte : Byte) -> Int32 {
  if byte == b'\x00' {
    0
  } else if byte == b'/' {
    1
  } else {
    byte.to_int() + 1
  }
}

///|
/// Normalize a comparison result to `-1`, `0`, or `1`.
fn sign_of(value : Int32) -> Int32 {
  if value < 0 {
    -1
  } else if value > 0 {
    1
  } else {
    0
  }
}

///|
/// Number of ASCII digits starting at `start`.
fn digit_run_length(view : BytesView, start : Int32) -> Int32 {
  let mut end = start
  while end < view.length() && is_ascii_digit(view[end]) {
    end = end + 1
  }
  end - start
}

///|
/// Compare two integral digit runs that share an equal prefix.
///
/// Neither run may have a leading zero here, so the longer run is the larger
/// number and equal lengths fall back to the first differing digit.
fn compare_digit_runs(
  left : BytesView,
  left_start : Int32,
  right : BytesView,
  right_start : Int32,
  left_byte : Byte,
  right_byte : Byte,
) -> Int32 {
  let left_len = digit_run_length(left, left_start)
  let right_len = digit_run_length(right, right_start)
  if left_len != right_len {
    sign_of(left_len - right_len)
  } else {
    sign_of(path_byte_weight(left_byte) - path_byte_weight(right_byte))
  }
}

///|
/// Compare the first pair of differing bytes, taking the current digit-run
/// state into account.
fn compare_at_difference(
  state : NatState,
  left : BytesView,
  left_index : Int32,
  right : BytesView,
  right_index : Int32,
  left_byte : Byte,
  right_byte : Byte,
) -> Int32 {
  let left_digit = is_ascii_digit(left_byte)
  let right_digit = is_ascii_digit(right_byte)
  match state {
    Normal =>
      if left_digit && right_digit && left_byte != b'0' && right_byte != b'0' {
        compare_digit_runs(
          left, left_index, right, right_index, left_byte, right_byte,
        )
      } else {
        sign_of(path_byte_weight(left_byte) - path_byte_weight(right_byte))
      }
    Integer =>
      if left_digit && right_digit {
        compare_digit_runs(
          left, left_index, right, right_index, left_byte, right_byte,
        )
      } else if left_digit {
        1
      } else if right_digit {
        -1
      } else {
        sign_of(path_byte_weight(left_byte) - path_byte_weight(right_byte))
      }
    Zeros =>
      if left_digit && right_digit {
        sign_of(path_byte_weight(left_byte) - path_byte_weight(right_byte))
      } else if left_digit {
        -1
      } else if right_digit {
        1
      } else {
        sign_of(path_byte_weight(left_byte) - path_byte_weight(right_byte))
      }
    Fraction =>
      sign_of(path_byte_weight(left_byte) - path_byte_weight(right_byte))
  }
}
