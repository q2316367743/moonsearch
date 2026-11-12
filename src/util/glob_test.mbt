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

///|
test "a trailing backslash is a literal backslash" {
  assert_true(matches(b"\\", b"\\"))
  assert_false(matches(b"a", b"\\"))
  assert_true(matches(b"a\\", b"a\\"))
  // The escape consumes exactly the next byte.
  assert_true(matches(b"\\*", b"\\\\\\*"))
}

///|
test "escapes work on ordinary characters" {
  assert_true(matches(b"a", b"\\a"))
  assert_false(matches(b"b", b"\\a"))
  assert_true(matches(b"\\a", b"\\\\a"))
}

///|
/// Independent reference matcher, written as a dynamic program over the whole
/// pattern. It shares no backtracking logic with `@util.glob_match`.
fn glob_reference(text : BytesView, pattern : BytesView) -> Bool {
  let text_len = text.length()
  let pattern_len = pattern.length()
  let mut reachable = Array::make(pattern_len + 1, false)
  reachable[0] = true
  // Epsilon closure: `*` may match nothing, including a run of stars.
  for p in 0..<pattern_len {
    if reachable[p] && pattern[p] == b'*' {
      reachable[p + 1] = true
    }
  }
  for ti in 0..<text_len {
    let next = Array::make(pattern_len + 1, false)
    let byte = text[ti]
    for p in 0..<pattern_len {
      if !reachable[p] {
        continue
      }
      let pattern_byte = pattern[p]
      if pattern_byte == b'*' {
        next[p] = true
      } else if pattern_byte == b'?' {
        next[p + 1] = true
      } else if pattern_byte == b'\\' {
        if p + 1 < pattern_len {
          if pattern[p + 1] == byte {
            next[p + 2] = true
          }
        } else if byte == b'\\' {
          next[p + 1] = true
        }
      } else if pattern_byte == byte {
        next[p + 1] = true
      }
    }
    for p in 0..<pattern_len {
      if next[p] && pattern[p] == b'*' {
        next[p + 1] = true
      }
    }
    reachable = next
  }
  reachable[pattern_len]
}

///|
/// Enumerate every byte string over `alphabet` up to `max_len`.
fn all_strings(alphabet : Array[Byte], max_len : Int32) -> Array[Bytes] {
  let result : Array[Bytes] = [b""]
  let mut level : Array[Bytes] = [b""]
  for _ in 0..<max_len {
    let next : Array[Bytes] = []
    for prefix in level {
      for byte in alphabet {
        next.push(
          Bytes::makei(prefix.length() + 1, fn(index) {
            if index == prefix.length() {
              byte
            } else {
              prefix[index]
            }
          }),
        )
      }
    }
    for bytes in next {
      result.push(bytes)
    }
    level = next
  }
  result
}

///|
test "glob_match agrees with an independent reference matcher" {
  let pattern_alphabet : Array[Byte] = [b'a', b'*', b'?', b'\\']
  let text_alphabet : Array[Byte] = [b'a', b'b', b'\\']
  let patterns = all_strings(pattern_alphabet, 4)
  let texts = all_strings(text_alphabet, 4)
  for pattern in patterns {
    for text in texts {
      let actual = @util.glob_match(text[:], pattern[:])
      let expected = glob_reference(text[:], pattern[:])
      if actual != expected {
        abort(
          "glob mismatch: text=\{text.to_string()} pattern=\{pattern.to_string()} actual=\{actual} expected=\{expected}",
        )
      }
    }
  }
}
