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
test "join_path adds exactly one separator" {
  assert_eq(@util.join_path("/home/user", "docs"), "/home/user/docs")
  assert_eq(@util.join_path("/home/user/", "docs"), "/home/user/docs")
  assert_eq(@util.join_path("/", "tmp"), "/tmp")
  assert_eq(@util.join_path("", "name"), "name")
  assert_eq(@util.join_path("relative", "name"), "relative/name")
}

///|
test "is_within compares whole components" {
  assert_true(@util.is_within("/home/user", "/home/user"))
  assert_true(@util.is_within("/home/user", "/home/user/docs"))
  assert_false(@util.is_within("/home/user", "/home/user2"))
  assert_false(@util.is_within("/home/user/docs", "/home/user"))
  assert_true(@util.is_within("/", "/home"))
  assert_false(@util.is_within("/home", "/"))
  assert_false(@util.is_within("", "/home"))
  assert_false(@util.is_within("/home", ""))
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

///|
test "cmp_paths covers every digit-run state transition" {
  // Normal -> Integer: the longer integral run is the larger number.
  assert_true(cmp(b"a2", b"a10") < 0)
  assert_true(cmp(b"a10", b"a2") > 0)
  // Integer vs a non-digit on either side.
  assert_true(cmp(b"10a", b"1b") > 0)
  assert_true(cmp(b"1b", b"10a") < 0)
  assert_true(cmp(b"10", b"1") > 0)
  assert_true(cmp(b"1", b"10") < 0)
  // Zeros -> Fraction when a nonzero digit appears.
  assert_true(cmp(b"007", b"01") < 0)
  assert_true(cmp(b"019", b"020") < 0)
  assert_true(cmp(b"020", b"019") > 0)
  // Zeros vs digits: byte order decides, not numeric length.
  assert_true(cmp(b"00", b"01") < 0)
  assert_true(cmp(b"0a", b"00a") > 0)
  assert_true(cmp(b"000", b"00") < 0)
  // Normal -> Zeros when the run starts with zero.
  assert_true(cmp(b"0", b"00") > 0)
  assert_true(cmp(b"00", b"0") < 0)
  // Fraction state compares byte by byte.
  assert_true(cmp(b"a01x", b"a02x") < 0)
  assert_true(cmp(b"a01x", b"a010x") > 0)
  // A separator always weighs less than any name byte.
  assert_true(cmp(b"a/b", b"a_b") < 0)
  assert_true(cmp(b"a/0", b"a.0") < 0)
}

///|
/// Prefix a byte name with a fixed root, for path-level comparisons.
fn under_root(name : Bytes) -> Bytes {
  let out : Array[Byte] = [b'/', b'r', b'/']
  for byte in name[:].iter() {
    out.push(byte)
  }
  Bytes::from_array(out)
}

///|
test "cmp_paths never collapses distinct names" {
  // The upstream database relies on distinct names never comparing equal so
  // that sibling ranges stay contiguous.
  let names : Array[Bytes] = [
    b"01", b"1", b"2", b"02", b"10", b"010", b"b", b"b.d", b"b2", b"bb",
  ]
  for i in 0..<names.length() {
    for j in 0..<names.length() {
      if i != j {
        assert_true(cmp(names[i], names[j]) != 0)
        assert_true(cmp(under_root(names[i]), under_root(names[j])) != 0)
      }
    }
  }
}

///|
/// Generate a deterministic corpus of short paths over bytes that exercise the
/// digit states, separators, dots, and non-ASCII-free ordering.
fn generated_corpus() -> Array[Bytes] {
  let alphabet : Array[Byte] = [b'a', b'b', b'0', b'1', b'.', b'/', b'_']
  let corpus : Array[Bytes] = [b""]
  for length in 1..<5 {
    let mut total = 1
    for _ in 0..<length {
      total = total * alphabet.length()
    }
    for code in 0..<total {
      // Keep the corpus small: for length 4 take one combination in seven.
      if length == 4 && code % 7 != 0 {
        continue
      }
      let digits : Array[Int32] = []
      let mut value = code
      for _ in 0..<length {
        digits.push(value % alphabet.length())
        value = value / alphabet.length()
      }
      corpus.push(Bytes::makei(length, fn(index) { alphabet[digits[index]] }))
    }
  }
  corpus
}

///|
test "cmp_paths is a total order on a generated corpus" {
  let corpus = generated_corpus()
  // Antisymmetry and trichotomy on every pair.
  for i in 0..<corpus.length() {
    for j in 0..<corpus.length() {
      let forward = cmp(corpus[i], corpus[j])
      let backward = cmp(corpus[j], corpus[i])
      assert_eq(forward, -backward)
      assert_true(forward == -1 || forward == 0 || forward == 1)
      // Equal comparison means equal bytes.
      if forward == 0 {
        assert_true(corpus[i] == corpus[j])
      }
    }
  }
  // Transitivity, sampled systematically to keep the test quadratic-ish.
  let mut i = 0
  while i < corpus.length() {
    let mut j = 0
    while j < corpus.length() {
      let mut k = 0
      while k < corpus.length() {
        if cmp(corpus[i], corpus[j]) <= 0 && cmp(corpus[j], corpus[k]) <= 0 {
          assert_true(cmp(corpus[i], corpus[k]) <= 0)
        }
        k = k + 43
      }
      j = j + 41
    }
    i = i + 37
  }
  // Sorting yields a sequence that is already in comparator order.
  let sorted = corpus.copy()
  sorted.sort_by(fn(left, right) { cmp(left, right) })
  for index in 0..<(sorted.length() - 1) {
    assert_true(cmp(sorted[index], sorted[index + 1]) <= 0)
  }
}

///|
test "is_within accepts the root and rejects lookalike prefixes" {
  assert_true(@util.is_within("/", "/"))
  assert_true(@util.is_within("/", "/anything/at/all"))
  assert_true(@util.is_within("/a/b", "/a/b/c/d"))
  assert_false(@util.is_within("/a/b", "/a/bc"))
  assert_false(@util.is_within("/a/bc", "/a/b"))
  assert_false(@util.is_within("/", "relative"))
}
