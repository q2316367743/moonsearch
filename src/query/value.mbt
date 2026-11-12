///|
/// Comparison operator parsed from a field value.
///
/// A value may name a single threshold (`size:>1mb`), an exact value
/// (`depth:3`), or a half-open interval (`dm:lastweek..yesterday`).
pub(all) enum CmpOp {
  Equal
  Greater
  GreaterEqual
  Smaller
  SmallerEqual
  /// A half-open interval `[lo, hi)`.
  Range
}

///|
/// Symbol used by `describe`.
pub fn CmpOp::symbol(self : CmpOp) -> String {
  match self {
    Equal => "="
    Greater => ">"
    GreaterEqual => ">="
    Smaller => "<"
    SmallerEqual => "<="
    Range => ".."
  }
}

///|
/// A numeric comparison resolved to `Int64` values.
///
/// For every operator except `Range`, `hi` equals `lo` and only `lo` is
/// meaningful. `Range` is half-open: an entry matches when
/// `lo <= value < hi`.
pub(all) struct Comparison {
  op : CmpOp
  lo : Int64
  hi : Int64
}

///|
/// An exact-value comparison.
pub fn Comparison::equal(value : Int64) -> Comparison {
  { op: Equal, lo: value, hi: value, }
}

///|
/// Compare against one threshold.
pub fn Comparison::compare(op : CmpOp, value : Int64) -> Comparison {
  { op, lo: value, hi: value, }
}

///|
/// A half-open interval.
pub fn Comparison::range(lo : Int64, hi : Int64) -> Comparison {
  { op: Range, lo, hi, }
}

///|
/// Text form, used by `describe` and diagnostics.
pub fn Comparison::describe(self : Comparison) -> String {
  match self.op {
    Range => ".. \{self.lo} \{self.hi}"
    op => "\{op.symbol()} \{self.lo}"
  }
}

///|
/// A date comparison whose bounds are still text.
///
/// Dates need a calendar and a time zone, which arrive with the predicate layer.
/// The parser only captures the operator and the two bounds; an empty bound is
/// open. For `Equal`, `hi` is empty.
pub(all) struct DateComparison {
  op : CmpOp
  lo : String
  hi : String
}

///|
/// Build a date comparison.
pub fn DateComparison::new(
  op : CmpOp,
  lo~ : StringView = "",
  hi~ : StringView = "",
) -> DateComparison {
  { op, lo: "\{lo}", hi: "\{hi}", }
}

///|
/// Text form, used by `describe` and diagnostics.
pub fn DateComparison::describe(self : DateComparison) -> String {
  match self.op {
    Range =>
      if self.lo.is_empty() && self.hi.is_empty() {
        ".."
      } else if self.lo.is_empty() {
        ".. \{quote_text(self.hi)}"
      } else if self.hi.is_empty() {
        "\{quote_text(self.lo)} .."
      } else {
        "\{quote_text(self.lo)} .. \{quote_text(self.hi)}"
      }
    op =>
      if self.hi.is_empty() && self.lo.is_empty() {
        "\{op.symbol()}"
      } else {
        "\{op.symbol()} \{quote_text(self.lo)}"
      }
  }
}

///|
/// Maximum value used for an open upper bound, e.g. `size:1mb..`.
const MAX_BOUND : Int64 = 9223372036854775807L

///|
/// ASCII-fold a whole string.
fn ascii_lower_string(text : StringView) -> String {
  let chars : Array[Char] = []
  for char in text.iter() {
    chars.push(char.to_ascii_lowercase())
  }
  String::from_array(chars)
}

///|
/// Whether a character is an ASCII decimal digit.
fn is_digit_char(char : Char) -> Bool {
  char >= '0' && char <= '9'
}

///|
/// Parse a size such as `1024`, `1kb`, or `2GB` into bytes.
///
/// Units follow the decimal convention used by the query language: `k` is 1000,
/// `m` is 1,000,000, and so on. The suffix is ASCII case-insensitive. There is
/// no fractional part, and overflow, a missing number, or an unknown suffix
/// returns `None`.
pub fn parse_size(text : StringView) -> Int64? {
  let len = text.length()
  let mut pos = 0
  let mut value = 0L
  let mut digits = 0
  while pos < len {
    let char = match text.get_char(pos) {
      Some(char) => char
      None => return None
    }
    if !is_digit_char(char) {
      break
    }
    let digit = (char.to_int() - '0'.to_int()).to_int64()
    if value > (MAX_BOUND - digit) / 10L {
      return None
    }
    value = value * 10L + digit
    pos = pos + 1
    digits = digits + 1
  }
  if digits == 0 {
    return None
  }
  let multiplier = match ascii_lower_string(text[pos:len]) {
    "" => 1L
    "k" | "kb" => 1000L
    "m" | "mb" => 1000000L
    "g" | "gb" => 1000000000L
    "t" | "tb" => 1000000000000L
    _ => return None
  }
  if value > MAX_BOUND / multiplier {
    return None
  }
  Some(value * multiplier)
}

///|
/// Parse a non-negative integer used by `depth`, `childcount`, and friends.
///
/// A leading `+` is accepted; a sign, a fraction, or overflow returns `None`.
pub fn parse_count(text : StringView) -> Int64? {
  let len = text.length()
  let mut pos = 0
  if pos < len && text.get_char(pos) is Some('+') {
    pos = pos + 1
  }
  let mut value = 0L
  let mut digits = 0
  while pos < len {
    let char = match text.get_char(pos) {
      Some(char) => char
      None => return None
    }
    if !is_digit_char(char) {
      return None
    }
    let digit = (char.to_int() - '0'.to_int()).to_int64()
    if value > (MAX_BOUND - digit) / 10L {
      return None
    }
    value = value * 10L + digit
    pos = pos + 1
    digits = digits + 1
  }
  if digits == 0 {
    None
  } else {
    Some(value)
  }
}

///|
/// Locate the first `..` in a value, returning the text on both sides.
fn split_range(text : StringView) -> (StringView, StringView)? {
  let len = text.length()
  let mut index = 0
  while index + 1 < len {
    if text.get_char(index) is Some('.') &&
      text.get_char(index + 1) is Some('.') {
      return Some((text[:index], text[index + 2:]))
    }
    index = index + 1
  }
  None
}

///|
/// Whether a text still contains `..` after the first split.
fn has_range_separator(text : StringView) -> Bool {
  match split_range(text) {
    Some(_) => true
    None => false
  }
}

///|
/// Resolve an implicit comparison text into a `Comparison`.
///
/// Without `..` the text is an exact value. With `..` it is a half-open range;
/// an open lower bound starts at zero and an open upper bound ends at
/// `Int64::MAX`. A range whose bounds are equal collapses to an exact value, and
/// a second `..` is rejected.
fn parse_implicit_comparison(
  text : StringView,
  parse_value : (StringView) -> Int64?,
) -> Comparison? {
  match split_range(text) {
    None =>
      match parse_value(text) {
        Some(value) => Some(Comparison::equal(value))
        None => None
      }
    Some((lo_text, hi_text)) => {
      if has_range_separator(lo_text) || has_range_separator(hi_text) {
        return None
      }
      let lo = if lo_text.is_empty() { Some(0L) } else { parse_value(lo_text) }
      let hi = if hi_text.is_empty() {
        Some(MAX_BOUND)
      } else {
        parse_value(hi_text)
      }
      match (lo, hi) {
        (Some(lo), Some(hi)) =>
          if lo == hi {
            Some(Comparison::equal(lo))
          } else {
            Some(Comparison::range(lo, hi))
          }
        _ => None
      }
    }
  }
}

///|
/// Parse the text of a `size:` value into a comparison.
///
/// `1kb` means exactly 1,000 bytes; `1kb..2mb` means `[1000, 2000000)`.
pub fn parse_size_comparison(text : StringView) -> Comparison? {
  parse_implicit_comparison(text, parse_size)
}

///|
/// Parse the text of a counting field (`depth:`, `childcount:`, ...) into a
/// comparison.
pub fn parse_count_comparison(text : StringView) -> Comparison? {
  parse_implicit_comparison(text, parse_count)
}

///|
/// Parse the text of a `dm:` value into a date comparison.
///
/// The bounds stay text: `lastweek`, `2024-01`, and `2024-01-31 12:00` are
/// resolved by the predicate layer, which owns the calendar and the local time
/// zone.
pub fn parse_date_comparison(text : StringView) -> DateComparison? {
  if text.is_empty() {
    return None
  }
  match split_range(text) {
    None => Some(DateComparison::new(CmpOp::Equal, lo=text))
    Some((lo_text, hi_text)) => {
      if has_range_separator(lo_text) || has_range_separator(hi_text) {
        return None
      }
      if !lo_text.is_empty() && lo_text == hi_text {
        return Some(DateComparison::new(CmpOp::Equal, lo=lo_text))
      }
      Some(DateComparison::new(CmpOp::Range, lo=lo_text, hi=hi_text))
    }
  }
}
