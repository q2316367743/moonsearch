///|
/// Build a deterministic index for atomic-writer and golden tests.
fn write_fixture(seed : Int64) -> Index raise IndexError {
  let builder = Builder::new()
  let root = builder.add_root(b"/golden", false, seed)
  let sub = builder.add_folder(root, b"sub", seed + 1L)
  ignore(builder.add_file(root, b"A.TXT", 5L, seed + 2L))
  ignore(
    builder.add_file(
      sub,
      b".bad-\xff",
      9L,
      seed + 3L,
      flags=@core.ENTRY_FLAG_HIDDEN,
    ),
  )
  builder.set_child_counts(root, 1U, 1U)
  builder.set_child_counts(sub, 1U, 0U)
  builder.add_folder_size(sub, 9L)
  builder.add_folder_size(root, 14L)
  builder.set_root_stats(0, 2U, 1U, 14L)
  let rule = ExcludeRule::parse("glob:*.tmp", scope=Basename) catch {
    err => abort(err.message())
  }
  let rules : Array[ExcludeRule] = [rule]
  Index::build(builder.finish(built_at=seed), excludes=rules)
}

///|
/// Encode a fixture or abort with the writer error.
fn write_encoded(index : Index) -> Bytes {
  index.to_bytes() catch {
    err => abort(err.message())
  }
}

///|
async test "injected write, sync, and rename failures preserve the old database" {
  let dir = @fs.tmpdir(prefix="moonsearch-atomic-failures")
  let database = "\{dir}/index.msdb"
  let old = write_fixture(1L)
  let new = write_fixture(2L)
  let old_bytes = write_encoded(old)
  let new_bytes = write_encoded(new)
  old.write_database(database) catch {
    err => abort(err.message())
  }

  for
    fault in [DB_WRITE_FAULT_WRITE, DB_WRITE_FAULT_SYNC, DB_WRITE_FAULT_RENAME] {
    let outcome = try write_database_bytes(database, new_bytes, fault~) catch {
      err => Err(err)
    } noraise {
      _ => Ok(())
    }
    match outcome {
      Err(DbError::Io(message)) => assert_true(message.contains("injected"))
      _ => abort("expected an injected I/O failure")
    }
    assert_eq(@fs.read_binary(database), old_bytes)
    let names = @fs.readdir(dir, sort=true)
    for name in names {
      assert_false(name.contains(".tmp."))
    }
  }

  // Every failure path releases the lock and removes its temporary file, so a
  // later real write can still replace the database.
  write_database_bytes(database, new_bytes)
  assert_eq(@fs.read_binary(database), new_bytes)
  let loaded = Index::read_database(database, verify=true) catch {
    err => abort(err.message())
  }
  assert_eq(loaded.store().built_at(), 2L)
  @fs.remove(dir, recursive=true)
}

///|
test "deterministic database golden fingerprint and loaded reserialization" {
  let index = write_fixture(123L)
  let first = write_encoded(index)
  let second = write_encoded(index)
  assert_eq(first, second)
  assert_eq(first.length(), 1319)
  assert_eq(crc32(first[:]), 2_428_210_259U)
  let loaded = Index::from_bytes(first[:], verify=true) catch {
    err => abort(err.message())
  }
  assert_eq(write_encoded(loaded), first)
}
