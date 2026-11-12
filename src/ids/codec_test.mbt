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
