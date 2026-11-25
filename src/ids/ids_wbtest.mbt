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

///|
test "sorted strategy switches to galloping only beyond a difference of eight" {
  assert_true(sorted_strategy(10, 18) is Merge)
  assert_true(sorted_strategy(18, 10) is Merge)
  assert_true(sorted_strategy(9, 18) is GallopLeft)
  assert_true(sorted_strategy(18, 9) is GallopRight)
  assert_true(sorted_strategy(0, 9) is GallopLeft)
  assert_true(sorted_strategy(9, 0) is GallopRight)
}

///|
test "galloping intersection union and difference match linear merge" {
  let short : Array[Int32] = [0, 7, 63, 64, 4095, 4096, 65535, 65536, 200000]
  let long : Array[Int32] = []
  for index in 0..<20000 {
    long.push(index * 13)
  }

  let merge_and : Array[Int32] = []
  sorted_intersect_merge(short, long, merge_and)
  let gallop_and : Array[Int32] = []
  gallop_intersect(short, long, gallop_and)
  assert_eq(gallop_and, merge_and)
  assert_eq(sorted_intersect(short, long), merge_and)
  assert_eq(sorted_intersect(long, short), merge_and)

  let merge_union : Array[Int32] = []
  sorted_union_merge(short, long, merge_union)
  let gallop_union_result : Array[Int32] = []
  gallop_union(short, long, gallop_union_result)
  assert_eq(gallop_union_result, merge_union)
  assert_eq(sorted_union(short, long), merge_union)
  assert_eq(sorted_union(long, short), merge_union)

  let merge_difference : Array[Int32] = []
  sorted_difference_merge(short, long, merge_difference)
  let gallop_difference_result : Array[Int32] = []
  gallop_difference(short, long, gallop_difference_result)
  assert_eq(gallop_difference_result, merge_difference)
  assert_eq(sorted_difference(short, long), merge_difference)

  let reverse_difference : Array[Int32] = []
  sorted_difference_merge(long, short, reverse_difference)
  assert_eq(sorted_difference(long, short), reverse_difference)
}

///|
test "galloping lower bound handles starts gaps and block boundaries" {
  let values : Array[Int32] = []
  for index in 0..<7000 {
    values.push(index * 10)
  }
  assert_eq(gallop_lower_bound(values, -1, 0), 0)
  assert_eq(gallop_lower_bound(values, 0, 0), 0)
  assert_eq(gallop_lower_bound(values, 65530, 0), 6553)
  assert_eq(gallop_lower_bound(values, 65531, 0), 6554)
  assert_eq(gallop_lower_bound(values, 65530, 6500), 6553)
  assert_eq(gallop_lower_bound(values, 9990, 0), 999)
  assert_eq(gallop_lower_bound(values, 10000, 0), 1000)
  assert_eq(gallop_lower_bound(values, 0, 1000), 1000)
}
