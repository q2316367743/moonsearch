///|
test "validate_ids checks cardinality and maximum block before expansion" {
  let total = 7
  let too_many = @ids.Ids::from_sorted([0, 1, 2, 3, 4, 5, 6, 7])
  assert_eq(too_many.cardinality(), 8)
  let outcome = try validate_ids(too_many, total) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(DbError::Corrupt(message)) =>
      assert_true(message.contains("exceeds the entry count"))
    _ => abort("expected the cardinality check to reject the set")
  }

  let sparse = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids([0, 65536]))
  assert_eq(sparse.cardinality(), 2)
  assert_eq(sparse.max_block(), 1)
  let outcome = try validate_ids(sparse, total) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  match outcome {
    Err(DbError::Corrupt(message)) =>
      assert_true(message.contains("block is out of range"))
    _ => abort("expected the block check to reject the set")
  }

  let valid = @ids.Ids::from_bitmap(@ids.Bitmap::from_ids([0, 3, 6]))
  validate_ids(valid, total)
}

///|
test "DbReader ensure uses remaining length without integer overflow" {
  let reader = DbReader::new(b"\x00\x00"[:])
  reader.pos = 1
  let outcome = try reader.ensure(2147483647) catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  assert_true(outcome is Err(DbError::Truncated))
  reader.ensure(1)
}

///|
test "database size guard accepts the Int32 boundary and rejects one byte more" {
  ensure_database_size(DB_MAX_FILE_BYTES, "index.msdb")
  let outcome = try
    ensure_database_size(DB_MAX_FILE_BYTES + 1L, "index.msdb")
  catch {
    err => Err(err)
  } noraise {
    _ => Ok(())
  }
  assert_true(outcome is Err(DbError::TooLarge(_)))
}
