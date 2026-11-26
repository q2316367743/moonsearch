///|
/// Compare a decoded id set with an expected ascending id list.
fn assert_codec_ids(ids : @ids.Ids, expected : Array[Int32]) -> Unit raise {
  let actual = ids.to_sorted_ids()
  assert_eq(actual.length(), expected.length())
  for index in 0..<expected.length() {
    assert_eq(actual[index], expected[index])
  }
}

///|
/// Decode bytes and return the raised error.
fn decode_error(bytes : BytesView) -> @ids.IdsError {
  try @ids.Ids::from_bytes(bytes) catch {
    err => err
  } noraise {
    _ => abort("expected the id set to be rejected")
  }
}

///|
/// Write a little-endian u32 into a codec fixture.
fn put_codec_u32(bytes : Array[Byte], offset : Int32, value : UInt32) -> Unit {
  for index in 0..<4 {
    bytes[offset + index] = ((value >> (index * 8)) & 0xFFU).to_byte()
  }
}

///|
test "encoding round-trips every representation" {
  let empty = @ids.Ids::empty()
  let small = @ids.Ids::from_sorted([0, 1, 5, 65535, 65536, 131072])
  let dense_values : Array[Int32] = []
  for index in 0..<5000 {
    dense_values.push(index * 2)
  }
  dense_values.push(200000)
  dense_values.push(200001)
  let dense = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids(dense_values))
  assert_true(dense is @ids.Ids::Bitmap(_))

  for ids in [empty, small, dense] {
    let decoded = @ids.Ids::from_bytes(ids.to_bytes())
    assert_codec_ids(decoded, ids.to_sorted_ids())
    // A canonical encoding is stable across a decode/re-encode cycle.
    assert_eq(decoded.to_bytes(), ids.to_bytes())
  }
}

///|
test "dense sets keep the bits container across a round-trip" {
  let values : Array[Int32] = []
  for index in 0..<6000 {
    values.push(index)
  }
  let ids = @ids.Ids::from_sorted(values)
  assert_true(ids is @ids.Ids::Bitmap(_))
  let decoded = @ids.Ids::from_bytes(ids.to_bytes())
  assert_true(decoded is @ids.Ids::Bitmap(_))
  assert_eq(decoded.cardinality(), 6000)
  assert_true(decoded.contains(0))
  assert_true(decoded.contains(5999))
  assert_false(decoded.contains(6000))
}

///|
test "decoding rejects truncated input" {
  let encoded = @ids.Ids::from_sorted([1, 2, 3]).to_bytes()
  let error = decode_error(encoded[:encoded.length() - 1])
  assert_eq(error.message(), "id set data is truncated")

  let bitmap = @ids.Ids::from_sorted([0, 70000]).to_bytes()
  let bitmap_error = decode_error(bitmap[:bitmap.length() - 2])
  assert_eq(bitmap_error.message(), "id set data is truncated")
}

///|
test "decoding rejects malformed headers and containers" {
  let bad_repr = decode_error(b"\x02"[0:1])
  assert_true(bad_repr.message().contains("unknown representation"))

  // repr=bitmap, cardinality=1, block_count=1, block=0, type=9, len=0
  let raw : FixedArray[Byte] = [
    b'\x00', b'\x01', b'\x00', b'\x00', b'\x00', b'\x01', b'\x00', b'\x00', b'\x00',
    b'\x00', b'\x00', b'\x00', b'\x00', b'\x09', b'\x00', b'\x00', b'\x00', b'\x00',
  ]
  let bad_type = decode_error(Bytes::from_array(raw))
  assert_true(bad_type.message().contains("unknown container"))

  // repr=bitmap, cardinality=1, but no blocks.
  let bad_count = decode_error(b"\x00\x01\x00\x00\x00\x00\x00\x00\x00"[0:9])
  assert_true(bad_count.message().contains("cardinality"))
}

///|
test "decoding rejects non-ascending sorted ids and trailing bytes" {
  // repr=sorted, count=2, deltas 5 and 0.
  let repeated = decode_error(b"\x01\x02\x00\x00\x00\x05\x00"[0:7])
  assert_true(repeated.message().contains("strictly ascending"))

  // repr=sorted, count=1, delta 1, then one trailing byte.
  let trailing = decode_error(b"\x01\x01\x00\x00\x00\x01\x00"[0:7])
  assert_true(trailing.message().contains("trailing bytes"))
}

///|
test "decoding rejects ids outside the Int32 range" {
  // repr=sorted, count=1, delta 2^31.
  let overflow = decode_error(b"\x01\x01\x00\x00\x00\x80\x80\x80\x80\x08"[0:10])
  assert_true(overflow.message().contains("Int32"))
}

///|
test "decoded sets report their maximum block and id without expansion" {
  let empty = @ids.Ids::from_bytes(@ids.Ids::empty().to_bytes())
  assert_eq(empty.max_block(), -1)
  assert_eq(empty.max_id(), -1)

  let sorted = @ids.Ids::from_bytes(
    @ids.Ids::from_sorted([0, 65535, 65536, 131072]).to_bytes(),
  )
  assert_eq(sorted.max_block(), 2)
  assert_eq(sorted.max_id(), 131072)

  let sparse = @ids.Ids::from_bytes(
    @ids.Ids::from_sorted([0, 70000]).to_bytes(),
  )
  assert_eq(sparse.max_block(), 1)
  assert_eq(sparse.max_id(), 70000)

  let values : Array[Int32] = []
  for index in 0..<6000 {
    values.push(index)
  }
  let dense = @ids.Ids::from_bytes(@ids.Ids::from_sorted(values).to_bytes())
  assert_eq(dense.max_block(), 0)
  assert_eq(dense.max_id(), 5999)
}

///|
test "decoding enforces operation and memory budgets before allocation" {
  let bytes = @ids.Ids::from_sorted([1, 2, 3]).to_bytes()
  let operations = @ids.IdsDecodeBudget::with_limits(
    max_operations=2L,
    max_memory_bytes=1_048_576L,
  )
  let error = try @ids.Ids::from_bytes_with_budget(bytes[:], operations) catch {
    err => err
  } noraise {
    _ => abort("expected the operation budget to reject the id set")
  }
  match error {
    @ids.IdsError::LimitExceeded(message) =>
      assert_true(message.contains("operation budget"))
    _ => abort("expected a resource-limit error")
  }

  let memory = @ids.IdsDecodeBudget::with_limits(
    max_operations=1_000L,
    max_memory_bytes=1L,
  )
  let error = try @ids.Ids::from_bytes_with_budget(bytes[:], memory) catch {
    err => err
  } noraise {
    _ => abort("expected the memory budget to reject the id set")
  }
  match error {
    @ids.IdsError::LimitExceeded(message) =>
      assert_true(message.contains("memory budget"))
    _ => abort("expected a resource-limit error")
  }

  let shared = @ids.IdsDecodeBudget::with_limits(
    max_operations=3L,
    max_memory_bytes=1_048_576L,
  )
  for id in [1, 2, 3] {
    let one = @ids.Ids::from_sorted([id]).to_bytes()
    assert_eq(
      @ids.Ids::from_bytes_with_budget(one[:], shared).to_sorted_ids(),
      [id],
    )
  }
  let error = try @ids.Ids::from_bytes_with_budget(bytes[:], shared) catch {
    err => err
  } noraise {
    _ => abort("expected the shared budget to be exhausted")
  }
  assert_true(error is @ids.IdsError::LimitExceeded(_))
}

///|
test "declared cardinality and block bounds are checked before expansion" {
  let sorted = Array::make(13, b'\x00')
  sorted[0] = b'\x01'
  put_codec_u32(sorted, 1, 8U)
  for index in 0..<8 {
    sorted[5 + index] = index.to_byte()
  }
  let budget = @ids.IdsDecodeBudget::new()
  let error = try
    @ids.Ids::from_bytes_with_budget(
      Bytes::from_array(sorted[:])[:],
      budget,
      total=Some(7),
    )
  catch {
    err => err
  } noraise {
    _ => abort("expected the declared cardinality to be rejected")
  }
  assert_true(error.message().contains("cardinality exceeds"))

  let zero_bound = Array::make(5, b'\x00')
  zero_bound[0] = b'\x01'
  put_codec_u32(zero_bound, 1, 100_000_000U)
  let error = try
    @ids.Ids::from_bytes_with_budget(
      Bytes::from_array(zero_bound[:])[:],
      @ids.IdsDecodeBudget::new(),
      total=Some(0),
    )
  catch {
    err => err
  } noraise {
    _ => abort("expected a zero entry bound to reject the cardinality")
  }
  assert_true(error.message().contains("cardinality exceeds"))

  let bitmap = Array::make(18, b'\x00')
  put_codec_u32(bitmap, 1, 1U)
  put_codec_u32(bitmap, 5, 1U)
  put_codec_u32(bitmap, 9, 1U)
  put_codec_u32(bitmap, 14, 1U)
  let error = try
    @ids.Ids::from_bytes_with_budget(
      Bytes::from_array(bitmap[:])[:],
      @ids.IdsDecodeBudget::new(),
      total=Some(7),
    )
  catch {
    err => err
  } noraise {
    _ => abort("expected the out-of-range block to be rejected")
  }
  assert_true(error.message().contains("block index is out of range"))
}

///|
test "hostile codec lengths are rejected before large allocations" {
  let huge_sorted = decode_error(b"\x01\xff\xff\xff\xff"[0:5])
  assert_true(huge_sorted.message().contains("cardinality"))

  let huge_blocks = decode_error(b"\x00\x01\x00\x00\x00\xff\xff\xff\xff"[0:9])
  assert_true(huge_blocks.message().contains("too many blocks"))

  let huge_array = Array::make(18, b'\x00')
  put_codec_u32(huge_array, 1, 1U)
  put_codec_u32(huge_array, 5, 1U)
  put_codec_u32(huge_array, 9, 0U)
  put_codec_u32(huge_array, 14, 65_537U)
  let error = decode_error(Bytes::from_array(huge_array[:]))
  assert_true(error.message().contains("larger than a block"))

  let truncated_bits = Array::make(18, b'\x00')
  put_codec_u32(truncated_bits, 1, 1U)
  put_codec_u32(truncated_bits, 5, 1U)
  put_codec_u32(truncated_bits, 9, 0U)
  truncated_bits[13] = b'\x01'
  put_codec_u32(truncated_bits, 14, 1024U)
  let error = decode_error(Bytes::from_array(truncated_bits[:]))
  assert_eq(error.message(), "id set data is truncated")
}
