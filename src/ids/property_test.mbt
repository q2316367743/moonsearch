// S13 property tests for the id-set algebra and its serialization.
//
// These are quickcheck-style tests: a deterministic generator builds random
// sets over several universe sizes, and every operation is compared with a
// naive boolean-mask reference. The same sets are also pushed through the
// encoder, mutated, and decoded, which checks that a corrupted id set either
// fails cleanly or still yields a canonical set.

///|
/// Build a random set of ids below `universe`.
///
/// Density is a parameter so the tests hit sparse (`Sorted`) and dense
/// (`Bitmap`) representations, including sets that span several 65536-id
/// bitmap blocks.
fn property_random_ids(
  rng : @testkit.Rng,
  universe : Int32,
  percent : Int32,
) -> Array[Int32] {
  let ids : Array[Int32] = []
  for id in 0..<universe {
    if rng.chance(percent) {
      ids.push(id)
    }
  }
  ids
}

///|
/// Turn a set into an `Ids` with the shape its density calls for.
fn property_ids(values : Array[Int32], universe : Int32) -> @ids.Ids {
  @ids.Ids::from_sorted(values, total=universe)
}

///|
/// Boolean-mask reference: mark every id in the set.
fn property_mask(values : Array[Int32], universe : Int32) -> Array[Bool] {
  let mask : Array[Bool] = Array::make(universe, false)
  for id in values {
    mask[id] = true
  }
  mask
}

///|
/// Convert a boolean mask back into an ascending id array.
fn property_mask_ids(mask : Array[Bool], universe : Int32) -> Array[Int32] {
  let ids : Array[Int32] = []
  for id in 0..<universe {
    if mask[id] {
      ids.push(id)
    }
  }
  ids
}

///|
/// Naive union over masks.
fn property_ref_union(
  left : Array[Int32],
  right : Array[Int32],
  universe : Int32,
) -> Array[Int32] {
  let mask = property_mask(left, universe)
  for id in right {
    mask[id] = true
  }
  property_mask_ids(mask, universe)
}

///|
/// Naive intersection over masks.
fn property_ref_intersect(
  left : Array[Int32],
  right : Array[Int32],
  universe : Int32,
) -> Array[Int32] {
  let mask = property_mask(left, universe)
  let right_mask = property_mask(right, universe)
  let result : Array[Bool] = Array::make(universe, false)
  for id in 0..<universe {
    result[id] = mask[id] && right_mask[id]
  }
  property_mask_ids(result, universe)
}

///|
/// Naive difference over masks.
fn property_ref_difference(
  left : Array[Int32],
  right : Array[Int32],
  universe : Int32,
) -> Array[Int32] {
  let mask = property_mask(left, universe)
  for id in right {
    mask[id] = false
  }
  property_mask_ids(mask, universe)
}

///|
/// Assert that an `Ids` denotes exactly the reference set.
fn property_assert_eq(
  result : @ids.Ids,
  expected : Array[Int32],
  label : String,
) -> Unit raise {
  let actual = result.to_sorted_ids()
  if actual != expected {
    let actual_text = actual.map(fn(id) { id.to_string() }).join(",")
    let expected_text = expected.map(fn(id) { id.to_string() }).join(",")
    abort("\{label}: got [\{actual_text}], expected [\{expected_text}]")
  }
  assert_eq(result.cardinality(), expected.length())
  for id in expected {
    assert_true(result.contains(id))
  }
}

///|
test "set algebra identities hold for random sets and shapes" {
  let cases : Array[(Int32, Int32, Int32)] = [
    (128, 30, 60),
    (5000, 10, 40),
    (70000, 4, 12),
  ]
  let rng = @testkit.Rng::new(20241118UL)
  let mut operations = 0
  for spec in cases {
    let universe = spec.0
    let percent = spec.1
    let rounds = spec.2
    let full = property_mask_ids(Array::make(universe, true), universe)
    for _ in 0..<rounds {
      let left_values = property_random_ids(rng, universe, percent)
      let middle_values = property_random_ids(rng, universe, percent)
      let right_values = property_random_ids(rng, universe, percent)
      let left = property_ids(left_values, universe)
      let middle = property_ids(middle_values, universe)
      let right = property_ids(right_values, universe)
      // commutativity
      property_assert_eq(
        left.union_with_total(middle),
        property_ref_union(left_values, middle_values, universe),
        "union",
      )
      property_assert_eq(
        middle.union_with_total(left),
        property_ref_union(middle_values, left_values, universe),
        "union commutative",
      )
      property_assert_eq(
        left.intersect_with_total(middle),
        property_ref_intersect(left_values, middle_values, universe),
        "intersect",
      )
      property_assert_eq(
        middle.intersect_with_total(left),
        property_ref_intersect(middle_values, left_values, universe),
        "intersect commutative",
      )
      property_assert_eq(
        left.difference_with_total(middle),
        property_ref_difference(left_values, middle_values, universe),
        "difference",
      )
      // distributivity: A ∩ (B ∪ C) = (A ∩ B) ∪ (A ∩ C)
      let union_bc = property_ref_union(middle_values, right_values, universe)
      let distributed_left = @ids.Ids::from_sorted(union_bc, total=universe).intersect_with_total(
        left,
      )
      let distributed_right = left
        .intersect_with_total(middle)
        .union_with_total(left.intersect_with_total(right))
      property_assert_eq(
        distributed_left,
        property_ref_intersect(union_bc, left_values, universe),
        "left distributivity",
      )
      property_assert_eq(
        distributed_right,
        property_ref_union(
          property_ref_intersect(left_values, middle_values, universe),
          property_ref_intersect(left_values, right_values, universe),
          universe,
        ),
        "right distributivity",
      )
      // A \ B = A ∩ (U \ B)
      let complement = @ids.Ids::from_sorted(full, total=universe).difference_with_total(
        middle,
      )
      property_assert_eq(
        left.difference_with_total(middle),
        left.intersect_with_total(complement).to_sorted_ids(),
        "difference as complement",
      )
      // normalize keeps the set and picks a legal shape.
      let normalized = @ids.Ids::from_sorted(left_values).normalize(universe)
      property_assert_eq(normalized, left_values, "normalize")
      operations = operations + 1
    }
  }
  assert_true(operations > 0)
}

///|
test "skewed sorted sets match masks and exercise the galloping path" {
  let universe = 240000
  let short_values : Array[Int32] = [
    0, 13, 64, 65535, 65536, 131071, 131072, 200000, 239999,
  ]
  let long_values : Array[Int32] = []
  for index in 0..<3000 {
    let value = index * 73
    long_values.push(if index % 5 == 0 { value + 1 } else { value })
  }
  // Both operands stay below 4096 and below the density threshold, so the public
  // operations take the Sorted x Sorted path and select galloping from length.
  let short = @ids.Ids::from_sorted(short_values, total=universe)
  let long = @ids.Ids::from_sorted(long_values, total=universe)
  assert_true(short is @ids.Ids::Sorted(_))
  assert_true(long is @ids.Ids::Sorted(_))
  assert_true(
    short_values.length() + @ids.IDS_GALLOP_MIN_LENGTH_DIFF <
    long_values.length(),
  )

  let pairs : Array[(@ids.Ids, @ids.Ids, Array[Int32], Array[Int32])] = [
    (short, long, short_values, long_values),
    (long, short, long_values, short_values),
  ]
  for pair in pairs {
    let left = pair.0
    let right = pair.1
    let left_values = pair.2
    let right_values = pair.3
    property_assert_eq(
      left.intersect_with_total(right, total=universe),
      property_ref_intersect(left_values, right_values, universe),
      "skewed intersect",
    )
    property_assert_eq(
      left.union_with_total(right, total=universe),
      property_ref_union(left_values, right_values, universe),
      "skewed union",
    )
    property_assert_eq(
      left.difference_with_total(right, total=universe),
      property_ref_difference(left_values, right_values, universe),
      "skewed difference",
    )
  }
}

///|
/// Copy bytes into a mutable array.
fn property_byte_array(bytes : Bytes) -> Array[Byte] {
  let out : Array[Byte] = []
  for index in 0..<bytes.length() {
    out.push(bytes[index])
  }
  out
}

///|
/// Decode without letting a panic or a raised error escape the test.
fn property_decode(bytes : Array[Byte]) -> Result[@ids.Ids, Unit] {
  try @ids.Ids::from_bytes(Bytes::from_array(bytes[:])[:]) catch {
    _ => Err(())
  } noraise {
    value => Ok(value)
  }
}

///|
test "id set serialization round-trips and rejects mutations safely" {
  let rng = @testkit.Rng::new(987654321UL)
  let universes : Array[Int32] = [64, 5000, 70000]
  let mut mutations = 0
  for universe in universes {
    for _ in 0..<12 {
      let values = property_random_ids(rng, universe, 20)
      let original = @ids.Ids::from_sorted(values, total=universe)
      let bytes = original.to_bytes()
      let decoded = @ids.Ids::from_bytes(bytes[:]) catch {
        err => abort("round trip failed: \{err.message()}")
      }
      property_assert_eq(decoded, values, "round trip")
      // Corrupt one to four bytes at random positions and decode again. Any
      // successful decode must still be a canonical id set.
      for _ in 0..<6 {
        let mutated = property_byte_array(bytes)
        let flips = rng.between(1, 4)
        for _ in 0..<flips {
          let position = rng.below(mutated.length())
          let mask = rng.between(1, 255)
          mutated[position] = (mutated[position].to_int() ^ mask).to_byte()
        }
        match property_decode(mutated) {
          Ok(ids) => {
            let sorted = ids.to_sorted_ids()
            let mut previous : Int32 = -1
            for id in sorted {
              assert_true(id >= 0)
              assert_true(id > previous)
              previous = id
            }
            assert_eq(ids.cardinality(), sorted.length())
          }
          Err(_) => ()
        }
        mutations = mutations + 1
      }
      // Truncation must never yield a valid set.
      let shorter = rng.below(bytes.length())
      let truncated : Array[Byte] = []
      for index in 0..<shorter {
        truncated.push(bytes[index])
      }
      if property_decode(truncated) is Ok(_) {
        abort("truncated id set decoded successfully")
      }
      mutations = mutations + 1
    }
  }
  assert_true(mutations > 0)
}
