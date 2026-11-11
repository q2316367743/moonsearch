///|
test "names round trip through the pool" {
  let pool = @core.NamePool::new()
  assert_true(pool.is_empty())
  let alpha = pool.add(b"alpha"[:])
  let beta = pool.add(b"beta"[:])
  assert_false(pool.is_empty())
  assert_eq(pool.count(), 2)
  assert_eq(pool.byte_len(), 9)
  assert_eq(alpha.offset, 0U)
  assert_eq(alpha.byte_len(), 5)
  assert_eq(beta.offset, 5U)
  assert_eq(beta.byte_len(), 4)
  assert_eq(beta.end_offset(), 9U)
  assert_eq(pool.view(alpha), b"alpha"[:])
  assert_eq(pool.view(beta), b"beta"[:])
  assert_eq(pool.to_bytes(), b"alphabeta")
}

///|
test "empty names are allowed" {
  let pool = @core.NamePool::new()
  let empty = pool.add(b""[0:0])
  assert_eq(pool.count(), 1)
  assert_eq(pool.byte_len(), 0)
  assert_eq(empty.byte_len(), 0)
  assert_eq(pool.view(empty), b""[0:0])
  let name = pool.add(b"x"[:])
  assert_eq(name.offset, 0U)
  let trailing = pool.add(b""[0:0])
  assert_eq(trailing.offset, 1U)
  assert_eq(pool.view(trailing).length(), 0)
}

///|
test "the pool seals chunks instead of allocating per name" {
  let pool = @core.NamePool::with_chunk_size(16)
  let names : Array[Bytes] = [b"aaaa", b"bbbb", b"cccc", b"dddd"]
  let refs : Array[@core.NameRef] = []
  for i in 0..<100 {
    refs.push(pool.add(names[i % 4][:]))
  }
  assert_eq(pool.count(), 100)
  assert_eq(pool.byte_len(), 400)
  assert_true(pool.chunk_count() > 1)
  assert_true(pool.chunk_count() < 100)
  for i in 0..<refs.length() {
    assert_eq(pool.view(refs[i]), names[i % 4][:])
    if i > 0 {
      assert_true(refs[i].offset > refs[i - 1].offset)
    }
  }
}

///|
test "views stay valid while the pool keeps growing" {
  let pool = @core.NamePool::with_chunk_size(8)
  let a = pool.add(b"aaaa"[:])
  let b = pool.add(b"bbbb"[:])
  assert_eq(pool.view(a), b"aaaa"[:])
  assert_eq(pool.view(b), b"bbbb"[:])
  // This add seals the first chunk; the earlier references must still work.
  let c = pool.add(b"cccc"[:])
  assert_eq(pool.view(a), b"aaaa"[:])
  assert_eq(pool.view(b), b"bbbb"[:])
  assert_eq(pool.view(c), b"cccc"[:])
  assert_eq(pool.to_bytes(), b"aaaabbbbcccc")
}

///|
test "large names occupy one chunk" {
  let pool = @core.NamePool::with_chunk_size(4)
  let long = Bytes::make(9, b'x')
  let name = pool.add(long.exact_view())
  assert_eq(name.byte_len(), 9)
  assert_eq(pool.view(name), long.exact_view())
  assert_eq(pool.chunk_count(), 1)
}

///|
test "compare uses natural path order" {
  let pool = @core.NamePool::new()
  let file10 = pool.add(b"file10"[:])
  let file2 = pool.add(b"file2"[:])
  let separator = pool.add(b"a/b"[:])
  let dot = pool.add(b"a.b"[:])
  assert_true(pool.compare(file2, file10) < 0)
  assert_true(pool.compare(file10, file2) > 0)
  assert_true(pool.compare(separator, dot) < 0)
  assert_eq(pool.compare(file2, file2), 0)
}

///|
test "names longer than the length field are rejected" {
  let pool = @core.NamePool::new()
  let long = Bytes::make(@core.MAX_NAME_LEN + 1, b'a')
  let rejected = try {
    let _ = pool.add(long.exact_view())
    false
  } catch {
    NameTooLong(length) => length == @core.MAX_NAME_LEN + 1
    _ => false
  }
  assert_true(rejected)
  assert_eq(pool.count(), 0)
  assert_eq(pool.byte_len(), 0)
}
