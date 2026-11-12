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

///|
test "a name at the maximum length fits the length field" {
  let pool = @core.NamePool::new()
  let long = Bytes::make(@core.MAX_NAME_LEN, b'x')
  let name = pool.add(long.exact_view())
  assert_eq(name.byte_len(), @core.MAX_NAME_LEN)
  assert_eq(pool.count(), 1)
  assert_eq(pool.byte_len(), @core.MAX_NAME_LEN)
  assert_eq(pool.view(name).length(), @core.MAX_NAME_LEN)
  assert_eq(pool.view(name)[0], b'x')
  assert_eq(pool.view(name)[@core.MAX_NAME_LEN - 1], b'x')
  assert_eq(pool.to_bytes().length(), @core.MAX_NAME_LEN)
}

///|
test "a name that exactly fills a chunk is readable" {
  let pool = @core.NamePool::with_chunk_size(4)
  let first = pool.add(b"aaaa"[:])
  // The add seals the chunk immediately; the reference must still work.
  assert_eq(pool.chunk_count(), 1)
  let second = pool.add(b"bb"[:])
  assert_eq(pool.view(first), b"aaaa"[:])
  assert_eq(pool.view(second), b"bb"[:])
  assert_eq(pool.to_bytes(), b"aaaabb")
}

///|
test "empty names consume no bytes and no chunks" {
  let pool = @core.NamePool::with_chunk_size(4)
  let first = pool.add(b""[0:0])
  let name = pool.add(b"aaaa"[:])
  let middle = pool.add(b""[0:0])
  let tail = pool.add(b"bb"[:])
  assert_eq(pool.count(), 4)
  assert_eq(pool.byte_len(), 6)
  assert_eq(pool.view(first), b""[0:0])
  assert_eq(pool.view(middle), b""[0:0])
  assert_eq(pool.view(name), b"aaaa"[:])
  assert_eq(pool.view(tail), b"bb"[:])
  assert_eq(pool.to_bytes(), b"aaaabb")
}

///|
test "to_bytes concatenates chunks in append order" {
  let pool = @core.NamePool::with_chunk_size(3)
  let names : Array[Bytes] = [b"a", b"bb", b"ccc", b"dddd", b"e"]
  let refs : Array[@core.NameRef] = []
  for name in names {
    refs.push(pool.add(name[:]))
  }
  assert_eq(pool.to_bytes(), b"abbcccdddde")
  for i in 0..<names.length() {
    assert_eq(pool.view(refs[i]), names[i][:])
  }
}

///|
test "an empty pool materializes as empty bytes" {
  let pool = @core.NamePool::new()
  assert_eq(pool.to_bytes(), b"")
  assert_eq(pool.chunk_count(), 0)
  assert_eq(pool.count(), 0)
  assert_eq(pool.byte_len(), 0)
}

///|
test "views and appends interleave across many chunks" {
  let pool = @core.NamePool::with_chunk_size(7)
  let names : Array[Bytes] = [b"a", b"bb", b"ccc", b"dddd", b"eeeee"]
  let refs : Array[@core.NameRef] = []
  for i in 0..<50 {
    let name = names[i % names.length()]
    refs.push(pool.add(name[:]))
    // Every earlier reference stays readable after each append.
    for j in 0..<refs.length() {
      assert_eq(pool.view(refs[j]), names[j % names.length()][:])
    }
  }
  assert_eq(pool.count(), 50)
  assert_true(pool.chunk_count() > 1)
  let expected : Array[Byte] = []
  for i in 0..<50 {
    for byte in names[i % names.length()][:].iter() {
      expected.push(byte)
    }
  }
  assert_eq(pool.to_bytes(), Bytes::from_array(expected))
}

///|
test "a rejected name does not disturb existing state" {
  let pool = @core.NamePool::with_chunk_size(8)
  let kept = pool.add(b"keep"[:])
  let sealed_name = pool.add(b"seal-me"[:])
  let chunk_count = pool.chunk_count()
  let bytes = pool.byte_len()
  let too_long = Bytes::make(@core.MAX_NAME_LEN + 1, b'z')
  let rejected = try {
    let _ = pool.add(too_long.exact_view())
    false
  } catch {
    NameTooLong(_) => true
    _ => false
  }
  assert_true(rejected)
  assert_eq(pool.count(), 2)
  assert_eq(pool.byte_len(), bytes)
  assert_eq(pool.chunk_count(), chunk_count)
  assert_eq(pool.view(kept), b"keep"[:])
  assert_eq(pool.view(sealed_name), b"seal-me"[:])
  let after = pool.add(b"after"[:])
  assert_eq(pool.view(after), b"after"[:])
  assert_eq(pool.to_bytes(), b"keepseal-meafter")
}

///|
test "compare works on names added after earlier chunks were sealed" {
  let pool = @core.NamePool::with_chunk_size(4)
  let first = pool.add(b"file2"[:])
  let second = pool.add(b"file10"[:])
  // Reading seals chunks; comparison must keep working afterwards.
  assert_eq(pool.view(first), b"file2"[:])
  assert_true(pool.compare(first, second) < 0)
  assert_true(pool.compare(second, first) > 0)
  let third = pool.add(b"file2"[:])
  assert_eq(pool.compare(first, third), 0)
  assert_eq(pool.compare(third, second), pool.compare(first, second))
}

///|
test "a chunk size below one is clamped to one" {
  let pool = @core.NamePool::with_chunk_size(0)
  let first = pool.add(b"ab"[:])
  let second = pool.add(b"c"[:])
  assert_eq(pool.view(first), b"ab"[:])
  assert_eq(pool.view(second), b"c"[:])
  assert_eq(pool.byte_len(), 3)
  assert_eq(pool.to_bytes(), b"abc")
  assert_true(pool.chunk_count() >= 1)
}
