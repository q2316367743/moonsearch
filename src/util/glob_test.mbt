///|
/// Match two byte literals.
fn matches(text : Bytes, pattern : Bytes) -> Bool {
  @util.glob_match(text[:], pattern[:])
}

///|
test "glob matches literal patterns exactly" {
  assert_true(matches(b"report.pdf", b"report.pdf"))
  assert_false(matches(b"report.pdf.bak", b"report.pdf"))
  assert_false(matches(b"Report.pdf", b"report.pdf"))
  assert_true(matches(b"", b""))
  assert_false(matches(b"x", b""))
}

///|
test "glob star matches any run including separators" {
  assert_true(matches(b"report.pdf", b"*.pdf"))
  assert_true(matches(b".pdf", b"*.pdf"))
  assert_true(matches(b"a/b/c.txt", b"a/*/c.txt"))
  assert_true(matches(b"a/b/c.txt", b"a/*"))
  assert_true(matches(b"anything", b"*"))
  assert_true(matches(b"", b"*"))
  assert_false(matches(b"report.pdf", b"*.txt"))
}

///|
test "glob question mark matches exactly one byte" {
  assert_true(matches(b"file1", b"file?"))
  assert_false(matches(b"file", b"file?"))
  assert_false(matches(b"file12", b"file?"))
  assert_true(matches(b"a/b", b"a?b"))
  // A multi-byte UTF-8 character is not one byte.
  assert_false(matches(b"\xC3\xA9", b"?"))
}

///|
test "glob supports escapes" {
  assert_true(matches(b"a*b", b"a\\*b"))
  assert_false(matches(b"axxb", b"a\\*b"))
  assert_true(matches(b"a?b", b"a\\?b"))
  assert_true(matches(b"a\\b", b"a\\\\b"))
}

///|
test "glob backtracks across stars" {
  assert_true(matches(b"abbb", b"a*b"))
  assert_true(matches(b"a/b/c", b"*b*"))
  assert_true(matches(b"xxabyyab", b"*ab"))
  assert_false(matches(b"xxabyy", b"*ab*cd"))
  assert_true(matches(b"aaaaab", b"a*a*a*a*b"))
}

///|
test "glob handles star combinations" {
  assert_true(matches(b"abc", b"**"))
  assert_true(matches(b"abc", b"*a*c*"))
  assert_false(matches(b"abc", b"*a*d*"))
  assert_true(matches(b"", b"**"))
  assert_true(matches(b"abc", b"a**c"))
}
