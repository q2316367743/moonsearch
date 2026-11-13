///|
/// Independent intersection reference: nested membership test.
fn reference_intersect(
  left : Array[Int32],
  right : Array[Int32],
) -> Array[Int32] {
  let result : Array[Int32] = []
  for a in left {
    for b in right {
      if a == b {
        result.push(a)
        break
      }
    }
  }
  result
}

///|
test "pack_trigram packs three bytes most significant first" {
  assert_eq(pack_trigram(b'a', b'b', b'c'), 0x616263U)
  assert_eq(pack_trigram(b'\x00', b'\x00', b'\x01'), 0x000001U)
  assert_eq(pack_trigram(b'\xff', b'\xff', b'\xff'), 0xFFFFFFU)
}

///|
test "name_trigrams folds ASCII, orders keys, and deduplicates" {
  assert_eq(name_trigrams(b""[:]), [])
  assert_eq(name_trigrams(b"a"[:]), [])
  assert_eq(name_trigrams(b"ab"[:]), [])
  assert_eq(name_trigrams(b"abc"[:]), [pack_trigram(b'a', b'b', b'c')])
  assert_eq(name_trigrams(b"ABC"[:]), name_trigrams(b"abc"[:]))
  // "aaaa" has two windows of "aaa"; only one key is kept.
  assert_eq(name_trigrams(b"aaaa"[:]), [pack_trigram(b'a', b'a', b'a')])
  assert_eq(name_trigrams(b"abcd"[:]), [
    pack_trigram(b'a', b'b', b'c'),
    pack_trigram(b'b', b'c', b'd'),
  ])
  // Non-ASCII bytes pass through unchanged.
  let non_ascii = @utf8.encode("发票")
  assert_eq(name_trigrams(non_ascii[:]).length(), 4)
}

///|
test "merge_intersect keeps the common ids in order" {
  assert_eq(merge_intersect([1, 3, 5, 7], [2, 3, 6, 7]), [3, 7])
  assert_eq(merge_intersect([1, 2, 3], [4, 5, 6]), [])
  assert_eq(merge_intersect([1, 2], [2]), [2])
  assert_eq(merge_intersect([], [1, 2]), [])
  assert_eq(merge_intersect([1, 2], []), [])
}

///|
test "gallop_lower_bound finds the first position at or above a value" {
  let ids : Array[Int32] = [10, 20, 30, 40]
  assert_eq(gallop_lower_bound(ids, 5, 0), 0)
  assert_eq(gallop_lower_bound(ids, 10, 0), 0)
  assert_eq(gallop_lower_bound(ids, 25, 0), 2)
  assert_eq(gallop_lower_bound(ids, 40, 0), 3)
  assert_eq(gallop_lower_bound(ids, 45, 0), 4)
  assert_eq(gallop_lower_bound(ids, 25, 1), 2)
  assert_eq(gallop_lower_bound(ids, 25, 3), 3)
  assert_eq(gallop_lower_bound(ids, 1, 4), 4)
  assert_eq(gallop_lower_bound(ids, 1, -5), 0)
}

///|
test "galloping_intersect agrees with the reference" {
  let large : Array[Int32] = []
  for value in 0..<1000 {
    large.push(value * 2)
  }
  let small : Array[Int32] = [0, 3, 500, 998, 1998, 1999, 2000]
  assert_eq(
    galloping_intersect(small, large),
    reference_intersect(small, large),
  )
  assert_eq(galloping_intersect([], large), [])
  assert_eq(galloping_intersect(small, []), [])
}

///|
test "posting_intersect chooses merge for similar lengths" {
  let left : Array[Int32] = []
  let right : Array[Int32] = []
  for value in 0..<100 {
    left.push(value)
    if value % 2 == 0 {
      right.push(value)
    }
  }
  assert_eq(posting_intersect(left, right), reference_intersect(left, right))
}

///|
test "posting_intersect chooses galloping for distant lengths" {
  let large : Array[Int32] = []
  for value in 0..<1000 {
    large.push(value * 2)
  }
  let small : Array[Int32] = [0, 3, 500, 998, 1998, 1999, 2000]
  // 7 * 32 < 1000, so the galloping branch runs.
  assert_eq(posting_intersect(small, large), reference_intersect(small, large))
  assert_eq(posting_intersect(large, small), reference_intersect(small, large))
  assert_eq(posting_intersect([], large), [])
  assert_eq(posting_intersect(large, []), [])
}
