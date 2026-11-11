///|
/// Compare two byte literals as paths.
fn cmp(left : Bytes, right : Bytes) -> Int32 {
  @util.cmp_paths(left[:], right[:])
}

///|
test "cmp_paths is a normalized comparison" {
  assert_eq(cmp(b"same", b"same"), 0)
  assert_eq(cmp(b"abc", b"abd"), -1)
  assert_eq(cmp(b"abd", b"abc"), 1)
  assert_eq(cmp(b"abc", b"abcd"), -1)
  assert_eq(cmp(b"abcd", b"abc"), 1)
}

///|
test "cmp_paths compares digit runs numerically" {
  assert_true(cmp(b"file2", b"file10") < 0)
  assert_true(cmp(b"file10", b"file2") > 0)
  assert_true(cmp(b"x2y", b"x10y") < 0)
  assert_eq(cmp(b"file007", b"file007"), 0)
}

///|
test "cmp_paths follows strverscmp for leading zeros" {
  assert_true(cmp(b"007", b"7") < 0)
  assert_true(cmp(b"007", b"07") < 0)
  assert_true(cmp(b"07", b"7") < 0)
  assert_true(cmp(b"09", b"010") > 0)
  assert_true(cmp(b"0", b"00") > 0)
  assert_true(cmp(b"0", b"01") > 0)
  assert_true(cmp(b"001", b"01") < 0)
  assert_true(cmp(b"01", b"1") < 0)
  // A leading-zero run on one side makes the comparison fractional.
  assert_true(cmp(b"a5", b"a07") > 0)
  assert_true(cmp(b"a07", b"a5") < 0)
}

///|
test "cmp_paths puts the separator before other bytes" {
  assert_true(cmp(b"a/b", b"a.b") < 0)
  assert_true(cmp(b"a", b"a/b") < 0)
  assert_true(cmp(b"a/b", b"a") > 0)
  // A second separator at the branch point sorts before a name byte.
  assert_true(cmp(b"a//b", b"a/b") < 0)
}

///|
test "cmp_paths handles empty and shared prefixes" {
  assert_eq(cmp(b"", b""), 0)
  assert_true(cmp(b"", b"a") < 0)
  assert_true(cmp(b"a", b"") > 0)
  assert_true(cmp(b"foo", b"foobar") < 0)
  assert_true(cmp(b"foobar", b"foo") > 0)
}

///|
test "cmp_paths orders non-ASCII and invalid UTF-8 by raw bytes" {
  // 'z' (0x7a) sorts before the first byte of U+00E9 (0xC3 0xA9).
  assert_true(cmp(b"z", b"\xC3\xA9") < 0)
  assert_true(cmp(b"\xC3\xA9", b"z") > 0)
  // Invalid UTF-8 still has a deterministic byte order.
  assert_true(cmp(b"\x7F", b"\xFF") < 0)
  assert_true(cmp(b"\x80", b"\xFF") < 0)
  assert_eq(cmp(b"\xFF\xFE", b"\xFF\xFE"), 0)
}

///|
test "sorting with cmp_paths is deterministic" {
  let names : Array[Bytes] = [
    b"file10", b"a.b", b"7", b"a/b", b"file2", b"007", b"a", b"07",
  ]
  names.sort_by(fn(left, right) { @util.cmp_paths(left[:], right[:]) })
  assert_eq(names, [
    b"007", b"07", b"7", b"a", b"a/b", b"a.b", b"file2", b"file10",
  ])
}

///|
test "cmp_paths is antisymmetric on a corpus" {
  let corpus : Array[Bytes] = [
    b"", b"a", b"a/b", b"a.b", b"007", b"07", b"7", b"file2", b"file10", b"report.pdf",
    b"report2.pdf", b"\xFF", b"z",
  ]
  for i in 0..<corpus.length() {
    for j in 0..<corpus.length() {
      let forward = cmp(corpus[i], corpus[j])
      let backward = cmp(corpus[j], corpus[i])
      assert_eq(forward, -backward)
    }
  }
}
