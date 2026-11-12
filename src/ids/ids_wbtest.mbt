///|
test "large sorted operands match the bitmap paths" {
  let evens : Array[Int32] = []
  for index in 0..<20000 {
    evens.push(index * 2)
  }
  let multiples : Array[Int32] = []
  for index in 0..<13000 {
    multiples.push(index * 3)
  }
  // Raw construction is only available inside the package; it exercises the
  // plan's "Sorted(large) x Bitmap" strategy row.
  let sorted_evens = Ids::Sorted(evens)
  let bitmap_multiples = Ids::from_sorted(multiples)
  assert_true(bitmap_multiples is Ids::Bitmap(_))

  let intersection = sorted_evens.intersect(bitmap_multiples)
  assert_eq(intersection.cardinality(), 6500)
  assert_true(intersection.contains(0))
  assert_true(intersection.contains(38994))
  assert_false(intersection.contains(2))

  let difference = sorted_evens.difference(bitmap_multiples)
  assert_eq(difference.cardinality(), 20000 - 6500)
  assert_true(difference.contains(2))
  assert_false(difference.contains(0))

  let union = sorted_evens.union(bitmap_multiples)
  assert_eq(union.cardinality(), 20000 + 13000 - 6500)
  assert_true(union.contains(2))
  assert_true(union.contains(3))
}

///|
test "decoding a large sorted set upgrades it to a bitmap" {
  let values : Array[Int32] = []
  for index in 0..<5000 {
    values.push(index)
  }
  let decoded = Ids::from_bytes(Ids::Sorted(values).to_bytes())
  assert_true(decoded is Ids::Bitmap(_))
  assert_eq(decoded.cardinality(), 5000)
  assert_true(decoded.contains(4999))
}
