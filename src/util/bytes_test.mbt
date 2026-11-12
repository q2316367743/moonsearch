///|
test "ascii character classes" {
  assert_true(@util.is_ascii_digit(b'0'))
  assert_true(@util.is_ascii_digit(b'9'))
  assert_false(@util.is_ascii_digit(b'a'))
  assert_true(@util.is_ascii_upper(b'A'))
  assert_true(@util.is_ascii_lower(b'z'))
  assert_true(@util.is_ascii_alpha(b'Q'))
  assert_false(@util.is_ascii_alpha(b'/'))
}

///|
test "ascii case folding" {
  assert_eq(@util.ascii_lower(b'A'), b'a')
  assert_eq(@util.ascii_lower(b'z'), b'z')
  assert_eq(@util.ascii_lower(b'0'), b'0')
  assert_eq(@util.ascii_upper(b'a'), b'A')
  assert_eq(@util.ascii_upper(b'A'), b'A')
  // Non-ASCII bytes are never folded.
  assert_eq(@util.ascii_lower(b'\xC3'), b'\xC3')
}

///|
test "ascii_fold copies and lowercases ASCII only" {
  assert_eq(@util.ascii_fold(b"AbC"[0:3]), b"abc")
  assert_eq(@util.ascii_fold(b"A\xC3\x89"[0:3]), b"a\xC3\x89")
  assert_eq(@util.ascii_fold(b""[0:0]), b"")
}

///|
test "eq_ignore_ascii_case" {
  assert_true(@util.eq_ignore_ascii_case(b"Report"[0:6], b"rEPORT"[0:6]))
  assert_false(@util.eq_ignore_ascii_case(b"report"[0:6], b"reports"[0:7]))
  assert_false(@util.eq_ignore_ascii_case(b"a\xC3\x89"[0:3], b"a\xC3\xA9"[0:3]))
  assert_true(@util.eq_ignore_ascii_case(b""[0:0], b""[0:0]))
}

///|
test "starts_with and ends_with" {
  let view = b"report.pdf"[0:10]
  assert_true(@util.starts_with(view, b"rep"[0:3]))
  assert_true(@util.starts_with(view, b""[0:0]))
  assert_false(@util.starts_with(view, b"repots"[0:6]))
  assert_true(@util.ends_with(view, b".pdf"[0:4]))
  assert_true(@util.ends_with(view, b""[0:0]))
  assert_false(@util.ends_with(view, b".pdfx"[0:5]))
}

///|
test "find_byte honours the start offset" {
  let view = b"abca"[0:4]
  assert_eq(@util.find_byte(view, b'a'), Some(0))
  assert_eq(@util.find_byte(view, b'a', from=1), Some(3))
  assert_eq(@util.find_byte(view, b'z'), None)
  assert_eq(@util.find_byte(view, b'a', from=-5), Some(0))
  assert_eq(@util.find_byte(view, b'a', from=4), None)
}

///|
test "find_bytes" {
  let view = b"the report report.pdf"[0:21]
  assert_eq(@util.find_bytes(view, b"report"[0:6]), Some(4))
  assert_eq(@util.find_bytes(view, b"report"[0:6], from=5), Some(11))
  assert_eq(@util.find_bytes(view, b"missing"[0:7]), None)
  assert_eq(@util.find_bytes(view, b""[0:0]), Some(0))
  assert_eq(@util.find_bytes(view, b""[0:0], from=21), Some(21))
  assert_true(@util.contains_bytes(view, b".pdf"[0:4]))
  assert_false(@util.contains_bytes(view, b".txt"[0:4]))
}

///|
test "find_bytes handles a needle at the very end" {
  let view = b"abc"[0:3]
  assert_eq(@util.find_bytes(view, b"c"[0:1]), Some(2))
  assert_eq(@util.find_bytes(view, b"abc"[0:3]), Some(0))
  assert_eq(@util.find_bytes(view, b"abcd"[0:4]), None)
}

///|
test "prefix and suffix helpers handle oversized needles" {
  let view = b"abc"[0:3]
  assert_false(@util.starts_with(view, b"abcd"[0:4]))
  assert_false(@util.ends_with(view, b"abcd"[0:4]))
  assert_true(@util.starts_with(b""[0:0], b""[0:0]))
  assert_true(@util.ends_with(b""[0:0], b""[0:0]))
  assert_false(@util.starts_with(b""[0:0], b"a"[0:1]))
  assert_false(@util.ends_with(b""[0:0], b"a"[0:1]))
}

///|
test "find_bytes clamps both ends of the start offset" {
  let view = b"abcabc"[0:6]
  assert_eq(@util.find_bytes(view, b"abc"[0:3], from=-10), Some(0))
  assert_eq(@util.find_bytes(view, b"abc"[0:3], from=6), None)
  assert_eq(@util.find_bytes(view, b"abc"[0:3], from=10), None)
  assert_eq(@util.find_bytes(view, b"abc"[0:3], from=1), Some(3))
  // An empty needle matches at the clamped start, even past the end.
  assert_eq(@util.find_bytes(view, b""[0:0], from=-1), Some(0))
  assert_eq(@util.find_bytes(view, b""[0:0], from=3), Some(3))
  assert_eq(@util.find_bytes(view, b""[0:0], from=99), Some(6))
}

///|
test "find_bytes finds overlapping occurrences" {
  let view = b"aaaa"[0:4]
  assert_eq(@util.find_bytes(view, b"aa"[0:2]), Some(0))
  assert_eq(@util.find_bytes(view, b"aa"[0:2], from=1), Some(1))
  assert_eq(@util.find_bytes(view, b"aa"[0:2], from=3), None)
  assert_eq(@util.find_bytes(view, b"aaa"[0:3]), Some(0))
  assert_eq(@util.find_bytes(view, b"aaa"[0:3], from=1), Some(1))
}

///|
test "ascii case folding leaves non-ASCII bytes alone" {
  assert_eq(@util.ascii_upper(b'\xC3'), b'\xC3')
  assert_eq(@util.ascii_upper(b'a'), b'A')
  assert_true(@util.eq_ignore_ascii_case(b"\xC3\xA9"[0:2], b"\xC3\xA9"[0:2]))
  assert_false(@util.eq_ignore_ascii_case(b"\xC3\xA9"[0:2], b"\xC3\x89"[0:2]))
  assert_eq(@util.find_byte(b"abc"[0:3], b'c', from=2), Some(2))
  assert_eq(@util.find_byte(b"abc"[0:3], b'a', from=3), None)
}
