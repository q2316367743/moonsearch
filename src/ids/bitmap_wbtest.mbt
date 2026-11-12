///|
test "containers flip between array and bits at the cardinality threshold" {
  let bitmap = Bitmap::new()
  for index in 0..<4096 {
    bitmap.add(index)
  }
  assert_true(bitmap.containers[0] is Some(Container::Array(_)))
  assert_eq(bitmap.cardinality(), 4096)

  bitmap.add(4096)
  assert_true(bitmap.containers[0] is Some(Container::Bits(_)))
  assert_eq(bitmap.cardinality(), 4097)

  bitmap.remove(4096)
  assert_true(bitmap.containers[0] is Some(Container::Array(_)))
  assert_eq(bitmap.cardinality(), 4096)
}

///|
test "removing the last id clears and trims the block" {
  let bitmap = Bitmap::new()
  bitmap.add(65536 * 2 + 5)
  assert_eq(bitmap.containers.length(), 3)
  bitmap.remove(65536 * 2 + 5)
  assert_eq(bitmap.containers.length(), 0)
  assert_true(bitmap.is_empty())
}

///|
test "ids at a block boundary land in separate containers" {
  let bitmap = Bitmap::new()
  bitmap.add(65535)
  bitmap.add(65536)
  assert_eq(bitmap.containers.length(), 2)
  assert_true(bitmap.contains(65535))
  assert_true(bitmap.contains(65536))
  assert_false(bitmap.contains(65534))
  assert_false(bitmap.contains(65537))
  let ids = bitmap.to_sorted_ids()
  assert_eq(ids.length(), 2)
  assert_eq(ids[0], 65535)
  assert_eq(ids[1], 65536)
}

///|
test "block operations cover every container combination" {
  let left = Bitmap::new()
  let right = Bitmap::new()
  for index in 0..<100 {
    left.add(index)
  }
  // A dense block 0 and a sparse block 1 on the right side.
  for index in 0..<5000 {
    right.add(index * 2)
  }
  right.add(70001)

  let intersection = left.intersect(right)
  assert_eq(intersection.cardinality(), 50)
  assert_true(intersection.contains(0))
  assert_true(intersection.contains(98))
  assert_false(intersection.contains(1))
  assert_false(intersection.contains(100))

  let union = left.union(right)
  assert_eq(union.cardinality(), 100 + 5000 + 1 - 50)
  assert_true(union.contains(70001))

  let difference = left.difference(right)
  assert_eq(difference.cardinality(), 50)
  assert_true(difference.contains(1))
  assert_false(difference.contains(0))

  // Operands are never mutated by a set operation.
  assert_eq(left.cardinality(), 100)
  assert_eq(right.cardinality(), 5001)
}

///|
test "bits containers support removal without losing neighbors" {
  let bitmap = Bitmap::new()
  for index in 0..<5000 {
    bitmap.add(index * 2)
  }
  assert_true(bitmap.containers[0] is Some(Container::Bits(_)))
  bitmap.remove(100)
  assert_false(bitmap.contains(100))
  assert_true(bitmap.contains(98))
  assert_true(bitmap.contains(102))
  assert_eq(bitmap.cardinality(), 4999)
}

///|
test "negative ids and missing removals are no-ops" {
  let bitmap = Bitmap::new()
  bitmap.add(-1)
  assert_true(bitmap.is_empty())
  bitmap.remove(42)
  assert_true(bitmap.is_empty())
  bitmap.add(42)
  bitmap.add(42)
  assert_eq(bitmap.cardinality(), 1)
  bitmap.remove(42)
  assert_true(bitmap.is_empty())
}
