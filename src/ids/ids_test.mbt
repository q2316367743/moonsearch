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
  let sparse_a : Array[Int32] = [
    0, 1, 2, 5, 8, 13, 21, 65535, 65536, 65537, 131071, 131072, 200000, 299999,
  ]
  let sparse_b : Array[Int32] = [
    1, 3, 5, 7, 11, 13, 65536, 100000, 131072, 250000, 299999,
  ]
  let dense_a : Array[Int32] = []
  let dense_b : Array[Int32] = []
  for index in 0..<6000 {
    dense_a.push(index * 37)
    dense_b.push(index * 41 + 3)
  }
  let sorted_a = @ids.Ids::from_sorted(sparse_a)
  let sorted_b = @ids.Ids::from_sorted(sparse_b)
  let bitmap_a = @ids.Ids::from_sorted(dense_a)
  let bitmap_b = @ids.Ids::from_sorted(dense_b)
  assert_true(sorted_a is @ids.Ids::Sorted(_))
  assert_true(sorted_b is @ids.Ids::Sorted(_))
  assert_true(bitmap_a is @ids.Ids::Bitmap(_))
  assert_true(bitmap_b is @ids.Ids::Bitmap(_))

  let cases : Array[(@ids.Ids, @ids.Ids, Array[Int32], Array[Int32])] = [
    (sorted_a, sorted_b, sparse_a, sparse_b),
    (sorted_a, bitmap_b, sparse_a, dense_b),
    (bitmap_a, sorted_b, dense_a, sparse_b),
    (bitmap_a, bitmap_b, dense_a, dense_b),
  ]
  for case in cases {
    let left = case.0
    let right = case.1
    let left_values = case.2
    let right_values = case.3
    let left_mask = mask_of(left_values, size)
    let right_mask = mask_of(right_values, size)
    assert_id_list(
      left.intersect_with_total(right, total=size),
      mask_and(left_mask, right_mask),
    )
    assert_id_list(
      left.union_with_total(right, total=size),
      mask_or(left_mask, right_mask),
    )
    assert_id_list(
      left.difference_with_total(right, total=size),
      mask_difference(left_mask, right_mask),
    )
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
      assert_id_list(left.intersect_with_total(right), expected_and)
      assert_id_list(left.union_with_total(right), expected_or)
      assert_id_list(left.difference_with_total(right), expected_difference)
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
    let evens = ids.filter_with_total(fn(id) { id % 2 == 0 })
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

///|
test "legacy set operation signatures remain usable as function values" {
  let operations : Array[(@ids.Ids, @ids.Ids) -> @ids.Ids] = [
    @ids.Ids::intersect,
    @ids.Ids::union,
    @ids.Ids::difference,
  ]
  let left = @ids.Ids::from_sorted([1, 2, 3])
  let right = @ids.Ids::from_sorted([3, 4, 5])
  assert_id_list(operations[0](left, right), [3])
  assert_id_list(operations[1](left, right), [1, 2, 3, 4, 5])
  assert_id_list(operations[2](left, right), [1, 2])
  let filter : (@ids.Ids, (Int32) -> Bool) -> @ids.Ids = @ids.Ids::filter
  assert_id_list(filter(left, fn(id) { id == 2 }), [2])
}

///|
test "empty operands short-circuit every representation pair" {
  let sorted = @ids.Ids::from_sorted([0, 65535, 65536, 131072])
  let dense : Array[Int32] = []
  for index in 0..<5000 {
    dense.push(index * 2)
  }
  let bitmap = @ids.Ids::from_sorted(dense)
  assert_true(bitmap is @ids.Ids::Bitmap(_))
  // The bitmap decoder preserves an explicitly encoded empty bitmap, allowing
  // the black-box test to cover both empty physical forms.
  let empty_bitmap = @ids.Ids::from_bytes(
    b"\x00\x00\x00\x00\x00\x00\x00\x00\x00"[0:9],
  ) catch {
    _ => abort("empty bitmap fixture is invalid")
  }
  assert_true(empty_bitmap is @ids.Ids::Bitmap(_))
  let empties : Array[@ids.Ids] = [@ids.Ids::empty(), empty_bitmap]
  for empty in empties {
    for value in [sorted, bitmap] {
      let expected = value.to_sorted_ids()
      assert_id_list(empty.intersect_with_total(value), [])
      assert_id_list(value.intersect_with_total(empty), [])
      assert_id_list(empty.union_with_total(value), expected)
      assert_id_list(value.union_with_total(empty), expected)
      assert_id_list(empty.difference_with_total(value), [])
      assert_id_list(value.difference_with_total(empty), expected)
    }
  }
}

///|
test "operations and filters apply the total-entry density rule" {
  let left = @ids.Ids::from_sorted([1, 2, 3])
  let right = @ids.Ids::from_sorted([3, 4, 5])
  assert_true(left.intersect_with_total(right, total=8) is @ids.Ids::Bitmap(_))
  assert_true(left.union_with_total(right, total=16) is @ids.Ids::Bitmap(_))
  assert_true(
    left.difference_with_total(right, total=64) is @ids.Ids::Sorted(_),
  )
  assert_true(
    left.filter_with_total(fn(id) { id == 1 }, total=8) is @ids.Ids::Bitmap(_),
  )
  // Without a known total, the cardinality threshold still keeps these sorted.
  assert_true(left.intersect_with_total(right) is @ids.Ids::Sorted(_))
  assert_true(left.union_with_total(right) is @ids.Ids::Sorted(_))
  assert_true(left.difference_with_total(right) is @ids.Ids::Sorted(_))
}

///|
test "filter_into clears and reuses a caller-owned buffer" {
  let values : Array[Int32] = []
  for index in 0..<5000 {
    values.push(index * 2)
  }
  values.push(65535)
  values.push(65536)
  values.push(131072)
  let bitmap = @ids.Ids::from_sorted(values)
  assert_true(bitmap is @ids.Ids::Bitmap(_))
  let buffer : Array[Int32] = [999, 998]
  bitmap.filter_into(fn(id) { id % 2 == 0 }, buffer)
  assert_eq(buffer.length(), 5002)
  assert_eq(buffer[4999], 9998)
  assert_eq(buffer[5000], 65536)
  assert_eq(buffer[5001], 131072)
  let result = @ids.Ids::from_sorted_canonical(buffer)
  assert_id_list(result, buffer)
}
