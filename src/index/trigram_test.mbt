///|
/// A tree with mixed case, repeated windows, short names, and non-ASCII bytes:
///
/// ```text
/// /r                  folder 0
///   docs              folder 1
///     report.pdf      file 3
///     notes.txt       file 4
///   media             folder 2
///     photo.JPG       file 5
///   Report-2024.md    file 6
///   aaaaa             file 7
///   a                 file 8
///   ab                file 9
///   发票.txt          file 10
///   .hidden           file 11
///   abbaab            file 12
/// ```
fn trigram_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/r", false, 0L)
  let docs = builder.add_folder(root, "docs", 0L)
  ignore(builder.add_file(docs, "report.pdf", 1L, 0L))
  ignore(builder.add_file(docs, "notes.txt", 1L, 0L))
  builder.set_child_counts(docs, 2U, 0U)
  let media = builder.add_folder(root, "media", 0L)
  ignore(builder.add_file(media, "photo.JPG", 1L, 0L))
  builder.set_child_counts(media, 1U, 0U)
  ignore(builder.add_file(root, "Report-2024.md", 1L, 0L))
  ignore(builder.add_file(root, "aaaaa", 1L, 0L))
  ignore(builder.add_file(root, "a", 1L, 0L))
  ignore(builder.add_file(root, "ab", 1L, 0L))
  ignore(builder.add_file(root, "发票.txt", 1L, 0L))
  ignore(
    builder.add_file(root, ".hidden", 1L, 0L, flags=@core.ENTRY_FLAG_HIDDEN),
  )
  ignore(builder.add_file(root, "abbaab", 1L, 0L))
  builder.set_child_counts(root, 6U, 2U)
  builder.set_root_stats(0, 10U, 2U, 0L)
  builder.finish(built_at=0L)
}

///|
/// Parse a fixture or abort the test.
fn trigram_fixture() -> @core.Store {
  trigram_store() catch {
    err => abort("trigram fixture failed: \{err.message()}")
  }
}

///|
/// Pack an ASCII trigram exactly as the index does.
fn trigram_key(text : String) -> UInt32 {
  let bytes = @utf8.encode(text)
  if bytes.length() != 3 {
    abort("trigram_key expects exactly three bytes, got \{text}")
  }
  (bytes[0].to_uint() << 16) | (bytes[1].to_uint() << 8) | bytes[2].to_uint()
}

///|
/// Copy a posting into a plain array for comparisons.
fn posting_ids(posting : @index.TrigramPosting) -> Array[Int32] {
  let ids : Array[Int32] = []
  for id in posting.ids() {
    ids.push(id)
  }
  ids
}

///|
/// Ids of a lookup, or `None` for a full scan.
fn lookup_ids(index : @index.TrigramIndex, needle : String) -> Array[Int32]? {
  let bytes = @utf8.encode(needle)
  match index.lookup(bytes[:]).candidates() {
    Some(ids) => Some(ids.to_sorted_ids())
    None => None
  }
}

///|
test "trigram index records keys, postings, and short names" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  assert_eq(index.entry_count(), 13)
  assert_true(index.key_count() > 0)
  assert_true(index.posting_count() > 0)
  // The root "/r" and the names "a" and "ab" are shorter than three bytes.
  assert_eq(index.short_name_count(), 3)
  assert_eq(index.posting_bytes(), index.posting_count().to_int64() * 4L)
}

///|
test "trigram keys and postings are strictly ordered" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  let mut total = 0
  let mut previous : UInt32? = None
  for position in 0..<index.key_count() {
    let key = index.key_at(position).unwrap()
    match previous {
      Some(value) => assert_true(value < key)
      None => ()
    }
    previous = Some(key)
    let posting = index.posting_at(position).unwrap()
    total = total + posting.len()
    let mut last : Int32? = None
    for id in posting.ids() {
      assert_true(id >= 0 && id < index.entry_count())
      match last {
        Some(value) => assert_true(id > value)
        None => ()
      }
      last = Some(id)
    }
  }
  assert_eq(total, index.posting_count())
  assert_eq(index.key_at(-1), None)
  assert_eq(index.key_at(index.key_count()), None)
  assert_true(index.posting_at(-1) is None)
  assert_true(index.posting_at(index.key_count()) is None)
}

///|
test "repeated windows are stored once per name" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  // "aaaaa" yields "aaa" three times; the posting must still hold one id.
  let posting = index.posting(trigram_key("aaa")).unwrap()
  assert_eq(posting_ids(posting), [7])
}

///|
test "lookup folds ASCII and intersects postings" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  // "report.pdf" and "Report-2024.md" share the folded "rep" trigram.
  assert_eq(lookup_ids(index, "rep"), Some([3, 6]))
  assert_eq(lookup_ids(index, "REP"), Some([3, 6]))
  assert_eq(lookup_ids(index, "REP"), lookup_ids(index, "rep"))
  // Every required trigram occurs in both names.
  assert_eq(lookup_ids(index, "report"), Some([3, 6]))
  // The uppercase name is matched through the folded index.
  assert_eq(lookup_ids(index, "2024"), Some([6]))
}

///|
test "lookup returns a superset that still needs verification" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  // "abbaab" contains both trigrams of "aabb" but not the substring itself.
  // The posting intersection is a superset; byte verification rejects it.
  assert_eq(lookup_ids(index, "aabb"), Some([12]))
  let name = @utf8.encode("abbaab")
  assert_true(!@util.contains_bytes(name[:], @utf8.encode("aabb")[:]))
}

///|
test "short and empty needles degrade to a full scan" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  for needle in ["", "r", "re", "ab"] {
    let bytes = @utf8.encode(needle)
    let lookup = index.lookup(bytes[:])
    assert_true(lookup.is_full_scan())
    assert_true(lookup.candidates() is None)
    assert_eq(lookup.key_count(), 0)
  }
}

///|
test "an absent trigram yields a certain empty candidate set" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  let lookup = index.lookup(@utf8.encode("zzz")[:])
  assert_true(!lookup.is_full_scan())
  assert_true(lookup.is_missing())
  assert_eq(lookup.candidates().unwrap().cardinality(), 0)
  assert_eq(lookup.describe(), "trigram: miss")
}

///|
test "non-ASCII needles use byte trigrams" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  // The name is six UTF-8 bytes, so four byte trigrams exist.
  assert_eq(lookup_ids(index, "发票"), Some([10]))
  // A byte that does not occur anywhere has no posting.
  assert_eq(lookup_ids(index, "发票x"), Some([]))
}

///|
test "hidden names are indexed like every other name" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  assert_eq(lookup_ids(index, "hidden"), Some([11]))
}

///|
test "keys cover folders as well as files" {
  let store = trigram_fixture()
  let index = @index.TrigramIndex::build(store)
  // Folder names are part of the candidate space too.
  assert_eq(lookup_ids(index, "docs"), Some([1]))
  assert_eq(lookup_ids(index, "media"), Some([2]))
}

///|
test "rebuilding produces the same keys and postings" {
  let store = trigram_fixture()
  let first = @index.TrigramIndex::build(store)
  let second = @index.TrigramIndex::build(store)
  assert_eq(first.key_count(), second.key_count())
  assert_eq(first.posting_count(), second.posting_count())
  for position in 0..<first.key_count() {
    assert_eq(first.key_at(position), second.key_at(position))
    assert_eq(
      first.posting_at(position).unwrap().ids(),
      second.posting_at(position).unwrap().ids(),
    )
  }
}

///|
test "an empty index has no keys and scans everything" {
  let index = @index.TrigramIndex::empty()
  assert_eq(index.key_count(), 0)
  assert_eq(index.posting_count(), 0)
  assert_eq(index.short_name_count(), 0)
  assert_eq(index.stop_gram_count(), 0)
  assert_true(index.lookup(@utf8.encode("abc")[:]).is_missing())
  assert_true(index.lookup(@utf8.encode("ab")[:]).is_full_scan())
}

///|
/// A store built to cross the stop-gram threshold: 40 names share the
/// `common` trigrams, one name mixes them with a rare tail, and one name is
/// unrelated.
fn stop_gram_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/s", false, 0L)
  for index in 0..<40 {
    let name = if index < 10 { "common0\{index}" } else { "common\{index}" }
    ignore(builder.add_file(root, name, 1L, 0L))
  }
  ignore(builder.add_file(root, "commonapple.txt", 1L, 0L))
  ignore(builder.add_file(root, "xylophone.txt", 1L, 0L))
  builder.set_child_counts(root, 42U, 0U)
  builder.set_root_stats(0, 42U, 0U, 0L)
  builder.finish(built_at=0L)
}

///|
test "stop-grams are skipped and never filter a query" {
  let store = stop_gram_store() catch {
    err => abort("stop-gram fixture failed: \{err.message()}")
  }
  let index = @index.TrigramIndex::build(store)
  assert_true(index.stop_gram_count() > 0)
  // Every trigram of "common" occurs in more than 20% of the entries, so the
  // lookup cannot narrow the search.
  let common = index.lookup(@utf8.encode("common")[:])
  assert_true(common.is_full_scan())
  assert_eq(common.stop_gram_count(), 4)
  // "commonapple" mixes the four stop-grams with five rare trigrams; only the
  // rare ones participate.
  let mixed = index.lookup(@utf8.encode("commonapple")[:])
  assert_eq(mixed.stop_gram_count(), 4)
  assert_true(!mixed.is_full_scan())
  assert_eq(mixed.key_count(), 3)
  assert_eq(mixed.candidates().unwrap().to_sorted_ids(), [41])
}

///|
test "a rare needle intersects the shortest postings" {
  let store = stop_gram_store() catch {
    err => abort("stop-gram fixture failed: \{err.message()}")
  }
  let index = @index.TrigramIndex::build(store)
  // "xylophone" has seven rare trigrams; the lookup uses three of them.
  let lookup = index.lookup(@utf8.encode("xylophone")[:])
  assert_eq(lookup.stop_gram_count(), 0)
  assert_eq(lookup.key_count(), 3)
  assert_eq(lookup.candidates().unwrap().to_sorted_ids(), [42])
  assert_eq(lookup.describe(), "trigram: 3 keys, 1 candidate ids")
}
