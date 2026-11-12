///|
/// Build a membership mask over `[0, size)`.
fn mask_of(values : Array[Int32], size : Int32) -> Array[Bool] {
  let mask : Array[Bool] = []
  for _ in 0..<size {
    mask.push(false)
  }
  for value in values {
    if value >= 0 && value < size {
      mask[value] = true
    }
  }
  mask
}

///|
/// Naive intersection over two membership masks.
fn mask_and(left : Array[Bool], right : Array[Bool]) -> Array[Int32] {
  let values : Array[Int32] = []
  for index in 0..<left.length() {
    if left[index] && right[index] {
      values.push(index)
    }
  }
  values
}

///|
/// Naive union over two membership masks.
fn mask_or(left : Array[Bool], right : Array[Bool]) -> Array[Int32] {
  let values : Array[Int32] = []
  for index in 0..<left.length() {
    if left[index] || right[index] {
      values.push(index)
    }
  }
  values
}

///|
/// Naive difference over two membership masks.
fn mask_difference(left : Array[Bool], right : Array[Bool]) -> Array[Int32] {
  let values : Array[Int32] = []
  for index in 0..<left.length() {
    if left[index] && !right[index] {
      values.push(index)
    }
  }
  values
}

///|
/// Compare an id set with an expected ascending id list.
fn assert_id_list(ids : @ids.Ids, expected : Array[Int32]) -> Unit raise {
  let actual = ids.to_sorted_ids()
  assert_eq(actual.length(), expected.length())
  for index in 0..<expected.length() {
    assert_eq(actual[index], expected[index])
  }
}

///|
test "set operations match the naive reference across every shape" {
  let size = 300000
  let a_values : Array[Int32] = [
    0, 1, 2, 5, 8, 13, 21, 65535, 65536, 65537, 131071, 131072, 200000, 299999,
  ]
  let b_values : Array[Int32] = [
    1, 3, 5, 7, 11, 13, 65536, 100000, 131072, 250000, 299999,
  ]
  let a_mask = mask_of(a_values, size)
  let b_mask = mask_of(b_values, size)
  let expected_and = mask_and(a_mask, b_mask)
  let expected_or = mask_or(a_mask, b_mask)
  let expected_difference = mask_difference(a_mask, b_mask)

  let sorted_a = @ids.Ids::from_sorted(a_values)
  let sorted_b = @ids.Ids::from_sorted(b_values)
  let bitmap_a = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids(a_values))
  let bitmap_b = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids(b_values))
  assert_true(sorted_a is @ids.Ids::Sorted(_))
  assert_true(sorted_b is @ids.Ids::Sorted(_))
  assert_true(bitmap_a is @ids.Ids::Sorted(_))
  assert_true(bitmap_b is @ids.Ids::Sorted(_))

  let lefts : Array[@ids.Ids] = [sorted_a, bitmap_a]
  let rights : Array[@ids.Ids] = [sorted_b, bitmap_b]
  for left in lefts {
    for right in rights {
      assert_id_list(left.intersect(right), expected_and)
      assert_id_list(left.union(right), expected_or)
      assert_id_list(left.difference(right), expected_difference)
    }
  }
}

///|
test "large canonical sets match the reference across shapes" {
  let size = 40000
  let evens : Array[Int32] = []
  for index in 0..<20000 {
    evens.push(index * 2)
  }
  let multiples : Array[Int32] = []
  for index in 0..<13000 {
    multiples.push(index * 3)
  }
  let even_mask = mask_of(evens, size)
  let multiple_mask = mask_of(multiples, size)
  let expected_and = mask_and(even_mask, multiple_mask)
  let expected_or = mask_or(even_mask, multiple_mask)
  let expected_difference = mask_difference(even_mask, multiple_mask)

  let bitmap_evens = @ids.Ids::from_sorted(evens)
  let bitmap_multiples = @ids.Ids::from_sorted(multiples)
  assert_true(bitmap_evens is @ids.Ids::Bitmap(_))
  assert_true(bitmap_multiples is @ids.Ids::Bitmap(_))

  let lefts : Array[@ids.Ids] = [bitmap_evens]
  let rights : Array[@ids.Ids] = [bitmap_multiples]
  for left in lefts {
    for right in rights {
      assert_id_list(left.intersect(right), expected_and)
      assert_id_list(left.union(right), expected_or)
      assert_id_list(left.difference(right), expected_difference)
    }
  }
}

///|
test "shape selection follows the cardinality and density thresholds" {
  let below : Array[Int32] = []
  for index in 0..<4096 {
    below.push(index * 3)
  }
  assert_true(@ids.Ids::from_sorted(below) is @ids.Ids::Sorted(_))

  below.push(4096 * 3)
  assert_true(@ids.Ids::from_sorted(below) is @ids.Ids::Bitmap(_))

  // At cardinality 10 of a 320-entry universe the density is exactly 1/32.
  let sparse : Array[Int32] = []
  for index in 0..<10 {
    sparse.push(index * 3)
  }
  assert_true(@ids.Ids::from_sorted(sparse, total=320) is @ids.Ids::Sorted(_))
  sparse.push(30)
  assert_true(@ids.Ids::from_sorted(sparse, total=320) is @ids.Ids::Bitmap(_))

  // A small bitmap normalizes back to the sorted form.
  let small_bitmap = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids([1, 2, 3]))
  assert_true(small_bitmap is @ids.Ids::Sorted(_))
  assert_true(
    @ids.Ids::from_sorted([1, 2, 3]).normalize(1000) is @ids.Ids::Sorted(_),
  )
  assert_true(
    @ids.Ids::from_sorted([1, 2, 3]).normalize(64) is @ids.Ids::Bitmap(_),
  )
}

///|
test "contains, cardinality, and filter agree with the reference" {
  let values : Array[Int32] = [0, 2, 65535, 65536, 131072]
  let sorted = @ids.Ids::from_sorted(values)
  let bitmap = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids(values))
  for ids in [sorted, bitmap] {
    assert_eq(ids.cardinality(), 5)
    assert_true(ids.contains(0))
    assert_true(ids.contains(65536))
    assert_false(ids.contains(1))
    assert_false(ids.contains(-1))
    let evens = ids.filter(fn(id) { id % 2 == 0 })
    assert_id_list(evens, [0, 2, 65536, 131072])
  }
}

///|
test "conversion helpers preserve the set" {
  let values : Array[Int32] = [3, 1, 3, 5]
  let ids = @ids.Ids::from_sorted(values)
  assert_eq(ids.cardinality(), 3)
  assert_id_list(ids, [1, 3, 5])
  assert_id_list(@ids.Ids::from_bitmap(ids.to_bitmap()), [1, 3, 5])
  assert_true(@ids.Ids::from_sorted([-1, -5]).is_empty())
}
