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

///|
test "block operations cover all four container shape combinations" {
  let array_left = Bitmap::from_ids(Array::makei(100, fn(index) { index * 2 }))
  let array_right = Bitmap::from_ids(
    Array::makei(100, fn(index) { index * 2 + 1 }),
  )
  let bits_left = Bitmap::from_ids(Array::makei(5000, fn(index) { index }))
  let bits_overlap = Bitmap::from_ids(
    Array::makei(5000, fn(index) { index + 100 }),
  )
  let bits_right = Bitmap::from_ids(
    Array::makei(5000, fn(index) { index + 2500 }),
  )
  assert_true(array_left.containers[0] is Some(Container::Array(_)))
  assert_true(array_right.containers[0] is Some(Container::Array(_)))
  assert_true(bits_left.containers[0] is Some(Container::Bits(_)))
  assert_true(bits_overlap.containers[0] is Some(Container::Bits(_)))
  assert_true(bits_right.containers[0] is Some(Container::Bits(_)))

  let cases : Array[(Bitmap, Bitmap, Int32, Int32, Int32)] = [
    (array_left, array_right, 0, 200, 100),
    (array_left, bits_overlap, 50, 5050, 50),
    (bits_left, array_right, 100, 5000, 4900),
    (bits_left, bits_right, 2500, 7500, 2500),
  ]
  for case in cases {
    let left = case.0
    let right = case.1
    let intersection = left.intersect(right)
    let union = left.union(right)
    let difference = left.difference(right)
    assert_eq(intersection.cardinality(), case.2)
    assert_eq(union.cardinality(), case.3)
    assert_eq(difference.cardinality(), case.4)
    assert_eq(
      intersection.cardinality() + difference.cardinality(),
      left.cardinality(),
    )
    assert_eq(
      intersection.cardinality() + right.difference(left).cardinality(),
      right.cardinality(),
    )
  }
  // The first array/array intersection empties and trims its only block.
  assert_true(array_left.intersect(array_right).containers.is_empty())
  // Operands retain their original container forms and cardinalities.
  assert_eq(array_left.cardinality(), 100)
  assert_eq(bits_left.cardinality(), 5000)
  assert_true(bits_left.containers[0] is Some(Container::Bits(_)))
}

///|
test "set operations preserve internal empty blocks at block boundaries" {
  let left = Bitmap::from_ids([1, 65535, 131073])
  let right = Bitmap::from_ids([65536, 131073, 196609])
  let intersection = left.intersect(right)
  assert_eq(intersection.to_sorted_ids(), [131073])
  assert_eq(intersection.containers.length(), 3)
  assert_true(intersection.containers[0] is None)
  assert_true(intersection.containers[1] is None)
  assert_true(intersection.containers[2] is Some(Container::Array(_)))

  assert_eq(left.union(right).to_sorted_ids(), [1, 65535, 65536, 131073, 196609])
  assert_eq(left.difference(right).to_sorted_ids(), [1, 65535])
  assert_eq(right.difference(left).to_sorted_ids(), [65536, 196609])
}

///|
test "bulk sorted removal handles bits arrays holes and out-of-range blocks" {
  let bitmap = Bitmap::from_ids(Array::makei(5000, fn(index) { index }))
  bitmap.add(131073)
  bitmap.add(131075)
  let removed : Array[Int32] = [-1]
  for index in 0..<1000 {
    removed.push(index)
  }
  removed.push(131073)
  removed.push(196609)
  bitmap.remove_ids(removed)
  assert_eq(bitmap.cardinality(), 4001)
  assert_true(bitmap.containers[0] is Some(Container::Array(_)))
  assert_true(bitmap.containers[1] is None)
  assert_true(bitmap.containers[2] is Some(Container::Array(_)))
  assert_eq(bitmap.containers.length(), 3)
  assert_false(bitmap.contains(0))
  assert_false(bitmap.contains(999))
  assert_true(bitmap.contains(1000))
  assert_true(bitmap.contains(4999))
  assert_false(bitmap.contains(131073))
  assert_true(bitmap.contains(131075))

  let tail = Bitmap::from_ids([131073])
  tail.remove_ids([131073, 196609])
  assert_true(tail.is_empty())
  assert_true(tail.containers.is_empty())
}
