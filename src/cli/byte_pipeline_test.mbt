///|
#cfg(platform="linux")
#borrow(path)
extern "C" fn byte_test_mkdir(path : Bytes, path_len : Int32) -> Int32 = "ms_test_mkdir"

///|
#cfg(platform="linux")
#borrow(path, contents)
extern "C" fn byte_test_create_file(
  path : Bytes,
  path_len : Int32,
  contents : Bytes,
  contents_len : Int32,
) -> Int32 = "ms_test_create_file"

///|
#cfg(platform="linux")
#borrow(path)
extern "C" fn byte_test_unlink(path : Bytes, path_len : Int32) -> Int32 = "ms_test_unlink"

///|
#cfg(platform="linux")
#borrow(path)
extern "C" fn byte_test_rmdir(path : Bytes, path_len : Int32) -> Int32 = "ms_test_rmdir"

///|
#cfg(platform="linux")
async test "invalid UTF-8 survives real scan, DB load, match, and raw output" {
  let root = b"_build/moonsearch-byte-pipeline-\xff"
  let first = b"_build/moonsearch-byte-pipeline-\xff/bad-\xfe"
  let second = b"_build/moonsearch-byte-pipeline-\xff/bad-\xff"
  ignore(byte_test_unlink(first, first.length()))
  ignore(byte_test_unlink(second, second.length()))
  ignore(byte_test_rmdir(root, root.length()))
  if byte_test_mkdir(root, root.length()) != 0 {
    abort("mkdir failed")
  }
  defer {
    ignore(byte_test_unlink(first, first.length()))
    ignore(byte_test_unlink(second, second.length()))
    ignore(byte_test_rmdir(root, root.length()))
  }
  if byte_test_create_file(first, first.length(), b"x", 1) != 0 ||
    byte_test_create_file(second, second.length(), b"yy", 2) != 0 {
    abort("create file failed")
  }
  let canonical = @platform.canonical_path(root).unwrap()
  let report = @index.scan(
    @index.ScanConfig::new(
      roots=[@index.RootSpec::new(path=root)],
      default_excludes=false,
    ),
    @platform.system_source(),
  ) catch {
    err => abort(err.message())
  }
  assert_eq(report.store.roots()[0].path, canonical)
  assert_eq(report.store.file_count(), 2)
  let index = @index.Index::build(report.store)
  let bytes = index.to_bytes() catch { err => abort(err.message()) }

  // The query must work from the database after the source tree is gone.
  ignore(byte_test_unlink(first, first.length()))
  ignore(byte_test_unlink(second, second.length()))
  ignore(byte_test_rmdir(root, root.length()))
  let loaded = @index.Index::from_bytes(bytes[:], verify=true) catch {
    err => abort(err.message())
  }
  assert_eq(loaded.store().roots()[0].path, canonical)
  assert_eq(loaded.store().file_count(), 2)
  let query = @query.parse("bad-")
  let hits = @exec.exec_scan_with(loaded.store(), query) catch {
    err => abort(err.message())
  }
  let ids = @exec.exec_indexed(loaded, query) catch {
    err => abort(err.message())
  }
  assert_eq(hits.length(), 2)
  assert_eq(ids.cardinality(), 2)
  for entry in hits {
    assert_true(ids.contains(loaded.store().global_id(entry)))
  }
  assert_eq(loaded.store().entry_name(hits[0]), b"bad-\xfe"[:])
  assert_eq(loaded.store().entry_name(hits[1]), b"bad-\xff"[:])
  let first_path = @util.join_path(canonical, b"bad-\xfe")
  let second_path = @util.join_path(canonical, b"bad-\xff")
  let expected = @buffer.Buffer()
  expected.write_bytesview(first_path)
  expected.write_byte(b'\n')
  expected.write_bytesview(second_path)
  expected.write_byte(b'\n')
  assert_eq(
    @exec.format_hits(loaded.store(), hits, @exec.FormatOptions::new()).stdout_bytes(),
    expected.to_bytes(),
  )
  let expected_nul = @buffer.Buffer()
  expected_nul.write_bytesview(first_path)
  expected_nul.write_byte(b'\x00')
  expected_nul.write_bytesview(second_path)
  expected_nul.write_byte(b'\x00')
  assert_eq(
    @exec.format_hits(
      loaded.store(),
      hits,
      @exec.FormatOptions::new(null_terminated=true),
    ).stdout_bytes(),
    expected_nul.to_bytes(),
  )
  let json = @exec.format_hits(
    loaded.store(),
    hits,
    @exec.FormatOptions::new(format=@exec.Json),
  )
  assert_eq(json.invalid_utf8_records, 2)
  let _ = @utf8.decode(json.stdout_bytes()) catch {
    _ => abort("JSON output must be valid UTF-8")
  }
}
