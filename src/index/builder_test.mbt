///|
/// Build an ASCII name of exactly `length` bytes.
fn builder_long_name(length : Int32) -> String {
  let chars : Array[Char] = []
  for _ in 0..<length {
    chars.push('b')
  }
  String::from_array(chars)
}

///|
test "the builder tracks entries and root statistics" {
  let builder = @index.Builder::new()
  let root = builder.add_root("/r", false, 10L)
  assert_eq(root, 0)
  assert_eq(builder.root_count(), 1)
  assert_eq(builder.folder_count(), 1)
  let sub = builder.add_folder(root, "sub", 11L, flags=@core.ENTRY_FLAG_HIDDEN)
  assert_eq(sub, 1)
  let file = builder.add_file(sub, "a.txt", 7L, 12L)
  assert_eq(file, 0)
  assert_eq(builder.folder_count(), 2)
  assert_eq(builder.file_count(), 1)
  builder.set_child_counts(sub, 1U, 0U)
  builder.add_folder_size(sub, 7L)
  builder.add_folder_size(root, 7L)
  builder.set_root_stats(0, 1U, 1U, 7L)
  let store = builder.finish(built_at=99L)
  assert_eq(store.built_at(), 99L)
  assert_eq(store.folder_count(), 2)
  assert_eq(store.file_count(), 1)
  assert_eq(store.folder(1).unwrap().num_files(), 1U)
  assert_eq(store.folder(1).unwrap().size(), 7L)
  assert_eq(store.roots()[0].files, 1U)
  assert_eq(store.roots()[0].folders, 1U)
  assert_eq(store.roots()[0].size, 7L)
  assert_eq(store.file_path(0), b"/r/sub/a.txt")
}

///|
test "finish without an explicit timestamp uses the current time" {
  let builder = @index.Builder::new()
  ignore(builder.add_root("/r", false, 0L))
  let store = builder.finish()
  assert_true(store.built_at() > 0L)
}

///|
test "the builder translates an over-long name into an index error" {
  let builder = @index.Builder::new()
  let name = builder_long_name(@core.MAX_NAME_LEN + 1)
  let err = try {
    let _ = builder.add_file(0, name, 1L, 0L)
    ()
  } catch {
    err => err
  } noraise {
    _ => abort("expected the name to be rejected")
  }
  match err {
    @index.NameTooLong(length) => {
      assert_eq(length, @core.MAX_NAME_LEN + 1)
      assert_true(err.message().contains("too long"))
    }
    _ => abort("expected NameTooLong, got \{err.message()}")
  }
  // The rejected name did not add an entry.
  assert_eq(builder.file_count(), 0)
}
