// S13 corruption fuzz for the MSDB reader.
//
// `db_test.mbt` already walks every truncation and every single-byte flip of a
// small database. This file adds the randomized layer the plan asks for:
// deterministic multi-operation mutations, garbage buffers, and — crucially —
// loads with `verify=false`, where the payload checksum is not consulted. A
// mutant is allowed to load in that mode, but then every accessor must stay
// in bounds and must not panic.

///|
/// Copy bytes into a mutable array.
fn fuzz_copy(bytes : Bytes) -> Array[Byte] {
  let out : Array[Byte] = []
  for index in 0..<bytes.length() {
    out.push(bytes[index])
  }
  out
}

///|
/// Whether two byte arrays are identical.
fn fuzz_same(left : Array[Byte], right : Bytes) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for index in 0..<left.length() {
    if left[index] != right[index] {
      return false
    }
  }
  true
}

///|
/// Decode with the payload checksum enabled.
fn fuzz_decode_verified(bytes : Array[Byte]) -> Result[@index.Index, Unit] {
  try
    @index.Index::from_bytes(Bytes::from_array(bytes[:])[:], verify=true)
  catch {
    _ => Err(())
  } noraise {
    value => Ok(value)
  }
}

///|
/// Read header information with the payload checksum enabled.
fn fuzz_info_verified(bytes : Array[Byte]) -> Result[@index.DbInfo, Unit] {
  try
    @index.DbInfo::from_bytes(Bytes::from_array(bytes[:])[:], verify=true)
  catch {
    _ => Err(())
  } noraise {
    value => Ok(value)
  }
}

///|
/// Decode without the payload checksum, as the CLI does by default.
fn fuzz_decode_unverified(bytes : Array[Byte]) -> Result[@index.Index, Unit] {
  try
    @index.Index::from_bytes(Bytes::from_array(bytes[:])[:], verify=false)
  catch {
    _ => Err(())
  } noraise {
    value => Ok(value)
  }
}

///|
/// Decode under a deliberately tiny shared budget. This exercises the resource
/// failure path on every mutant without allowing a corrupt length to allocate a
/// large intermediate structure first.
fn fuzz_decode_budgeted(bytes : Array[Byte]) -> Result[@index.Index, Unit] {
  let budget = @ids.IdsDecodeBudget::with_limits(
    max_operations=64L,
    max_memory_bytes=16_384L,
  )
  try
    @index.Index::from_bytes(
      Bytes::from_array(bytes[:])[:],
      verify=false,
      budget=Some(budget),
    )
  catch {
    _ => Err(())
  } noraise {
    value => Ok(value)
  }
}

///|
/// Assert that every id in a set belongs to the store.
fn fuzz_check_ids(ids : @ids.Ids, entry_count : Int32, label : String) -> Unit {
  for id in ids.to_sorted_ids() {
    if id < 0 || id >= entry_count {
      abort(
        "mutated index returned id \{id} for \{label} (count \{entry_count})",
      )
    }
  }
}

///|
/// Touch every structure a query can reach, so a corrupted-but-loadable index
/// cannot hide an out-of-bounds read behind lazy materialization.
fn fuzz_probe(index : @index.Index) -> Unit {
  let count = index.entry_count()
  for id in 0..<count {
    ignore(index.store().entry_at(id))
  }
  for entry in index.store().entries_in_order() {
    ignore(index.store().entry_name(entry))
    ignore(index.store().entry_path(entry))
  }
  for root in index.store().roots() {
    if root.folder < 0 || root.folder >= index.store().folder_count() {
      abort("mutated index returned an out-of-range root folder")
    }
    ignore(root.path)
    ignore(index.store().folder_path(root.folder))
  }
  let dict = index.dict()
  fuzz_check_ids(dict.all(), count, "dict.all")
  fuzz_check_ids(dict.files_all(), count, "dict.files_all")
  fuzz_check_ids(dict.folders_all(), count, "dict.folders_all")
  fuzz_check_ids(dict.extension(b"pdf"[:]), count, "dict.extension")
  fuzz_check_ids(dict.type_category(@util.TypeCategory::Doc), count, "dict.doc")
  let ranges = index.ranges()
  fuzz_check_ids(ranges.size().greater_than(0L), count, "ranges.size")
  fuzz_check_ids(ranges.mtime().less_than(2000000000L), count, "ranges.mtime")
  fuzz_check_ids(ranges.depth().at_most(3L), count, "ranges.depth")
  fuzz_check_ids(ranges.child_count().equal(0L), count, "ranges.child_count")
  fuzz_check_ids(ranges.parent_ids(b"/data/sub"[:]), count, "ranges.parent")
  match index.trigram() {
    Some(trigram) =>
      match trigram.lookup(b"same"[:]).candidates() {
        Some(candidates) =>
          fuzz_check_ids(candidates, count, "trigram candidates")
        None => ()
      }
    None => ()
  }
}

///|
/// Flip one to three random bytes.
fn fuzz_flip(rng : @testkit.Rng, bytes : Array[Byte]) -> Unit {
  if bytes.is_empty() {
    return
  }
  let flips = rng.between(1, 3)
  for _ in 0..<flips {
    let position = rng.below(bytes.length())
    let mask = rng.between(1, 255)
    bytes[position] = (bytes[position].to_int() ^ mask).to_byte()
  }
}

///|
/// Remove a random span.
fn fuzz_delete_span(rng : @testkit.Rng, bytes : Array[Byte]) -> Array[Byte] {
  if bytes.is_empty() {
    return bytes
  }
  let start = rng.below(bytes.length())
  let length = rng.between(1, 8)
  let out : Array[Byte] = []
  for index in 0..<bytes.length() {
    if index < start || index >= start + length {
      out.push(bytes[index])
    }
  }
  out
}

///|
/// Insert a short random span.
fn fuzz_insert_span(rng : @testkit.Rng, bytes : Array[Byte]) -> Array[Byte] {
  let position = rng.between(0, bytes.length())
  let length = rng.between(1, 8)
  let out : Array[Byte] = []
  let total = bytes.length() + length
  for index in 0..<total {
    if index == position {
      for _ in 0..<length {
        out.push(rng.below(256).to_byte())
      }
    }
    if index < bytes.length() {
      out.push(bytes[index])
    }
  }
  out
}

///|
/// Overwrite a span with a repeated byte.
fn fuzz_overwrite_span(rng : @testkit.Rng, bytes : Array[Byte]) -> Unit {
  if bytes.is_empty() {
    return
  }
  let start = rng.below(bytes.length())
  let length = rng.between(1, 8)
  let value : Byte = if rng.chance(50) { b'\x00' } else { b'\xFF' }
  let end = if start + length > bytes.length() {
    bytes.length()
  } else {
    start + length
  }
  for index in start..<end {
    bytes[index] = value
  }
}

///|
/// Apply one to three random mutation operations.
fn fuzz_mutate(rng : @testkit.Rng, original : Bytes) -> Array[Byte] {
  let mut bytes = fuzz_copy(original)
  let operations = rng.between(1, 3)
  for _ in 0..<operations {
    match rng.below(4) {
      0 => fuzz_flip(rng, bytes)
      1 => bytes = fuzz_delete_span(rng, bytes)
      2 => bytes = fuzz_insert_span(rng, bytes)
      _ => fuzz_overwrite_span(rng, bytes)
    }
  }
  // Two operations could cancel out; make sure the mutant really differs.
  if fuzz_same(bytes, original) {
    fuzz_flip(rng, bytes)
  }
  bytes
}

///|
test "random database mutations are rejected by full verification" {
  let original = encoded(sample_index())
  let rng = @testkit.Rng::new(0xC0FFEEUL)
  let mut rejected = 0
  for _ in 0..<600 {
    let mutant = fuzz_mutate(rng, original)
    match fuzz_decode_verified(mutant) {
      Ok(_) =>
        abort(
          "a mutated database passed verification (\{mutant.length()} bytes)",
        )
      Err(_) => rejected = rejected + 1
    }
    match fuzz_info_verified(mutant) {
      Ok(_) => abort("a mutated header passed verification")
      Err(_) => ()
    }
    // The unverified path may accept the file; if it does, every accessor
    // must still stay in bounds.
    match fuzz_decode_unverified(mutant) {
      Ok(index) => fuzz_probe(index)
      Err(_) => ()
    }
    match fuzz_decode_budgeted(mutant) {
      Ok(index) => fuzz_probe(index)
      Err(_) => ()
    }
  }
  assert_eq(rejected, 600)
}

///|
test "random garbage is rejected without panicking" {
  let rng = @testkit.Rng::new(0xBADF00DUL)
  for _ in 0..<300 {
    let length = rng.below(600)
    let bytes : Array[Byte] = []
    for _ in 0..<length {
      bytes.push(rng.below(256).to_byte())
    }
    // Force a non-magic prefix: a random buffer that happens to start with
    // "MSDB" would be testing a different property.
    let magic = b"MSDB"
    for index in 0..<4 {
      if index < bytes.length() {
        bytes[index] = (magic[index].to_int() ^ 0xFF).to_byte()
      }
    }
    if fuzz_decode_verified(bytes) is Ok(_) {
      abort("random garbage passed verification")
    }
    if fuzz_info_verified(bytes) is Ok(_) {
      abort("random garbage passed header verification")
    }
    match fuzz_decode_unverified(bytes) {
      Ok(index) => fuzz_probe(index)
      Err(_) => ()
    }
    match fuzz_decode_budgeted(bytes) {
      Ok(index) => fuzz_probe(index)
      Err(_) => ()
    }
  }
}
