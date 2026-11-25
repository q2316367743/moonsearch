///|
test "regex compiler preserves query case and error semantics" {
  let folded = @query.compile_regex("^report\\.pdf$")
  assert_true(folded.matches_bytes(b"REPORT.PDF"[:]))
  assert_true(folded.matches_bytes(b"report.pdf"[:]))
  assert_false(folded.matches_bytes(b"report.pdf.bak"[:]))
  let sensitive = @query.compile_regex("^report\\.pdf$", case_sensitive=true)
  assert_true(sensitive.matches_bytes(b"report.pdf"[:]))
  assert_false(sensitive.matches_bytes(b"REPORT.PDF"[:]))
}

///|
test "regex compiler reports the original invalid pattern" {
  let err = try @query.compile_regex("[") catch {
    err => err
  } noraise {
    _ => abort("expected an invalid regex error")
  }
  match err {
    @query.BadRegex(pattern) => assert_eq(pattern, "[")
    _ => abort("expected BadRegex")
  }
}

///|
test "query regex treats invalid UTF-8 subjects as non-matches" {
  let regex = @query.compile_regex(".*", case_sensitive=true)
  assert_true(regex.matches_bytes(b"valid"[:]))
  assert_false(regex.matches_bytes(b"bad-\xff"[:]))
}
