///|
/// A fixture with enough distinct names that most trigrams stay below the 20%
/// stop-gram threshold. It mixes files, folders, short names, mixed case, and
/// non-ASCII bytes.
fn trigram_compat_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/t", false, 0L)
  let words = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india",
    "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo",
    "sierra", "tango", "uniform", "victor", "whiskey", "xray", "yankee", "zulu",
    "xylophone",
  ]
  for word in words {
    ignore(builder.add_file(root, "\{word}.txt", 1L, 0L))
  }
  ignore(builder.add_file(root, "Report-Final.md", 1L, 0L))
  ignore(builder.add_file(root, "发票.txt", 1L, 0L))
  ignore(builder.add_file(root, "a", 1L, 0L))
  ignore(builder.add_file(root, "ab", 1L, 0L))
  let files = words.length() + 4
  builder.set_child_counts(root, files.reinterpret_as_uint(), 0U)
  builder.set_root_stats(0, files.reinterpret_as_uint(), 0U, 0L)
  builder.finish(built_at=0L)
}

///|
/// Build the fixture or abort the test.
fn compat_trigram_store() -> @core.Store {
  trigram_compat_store() catch {
    err => abort("trigram compat fixture failed: \{err.message()}")
  }
}

///|
/// Every entry id as one set.
fn compat_all_ids(store : @core.Store) -> @ids.Ids {
  @ids.Ids::from_sorted(
    Array::makei(store.entry_count(), fn(id) { id }),
    total=store.entry_count(),
  )
}

///|
/// Run a query with the scan engine and return the matching ids as a set.
fn compat_scan_ids(store : @core.Store, query : @query.Query) -> @ids.Ids {
  let hits = @exec.exec_scan(store, query) catch {
    err => abort("scan failed: \{err.message()}")
  }
  let ids : Array[Int32] = []
  for entry in hits {
    ids.push(store.global_id(entry))
  }
  @ids.Ids::from_sorted(ids, total=store.entry_count())
}

///|
/// Assert that every scan match is inside the candidate set.
fn assert_superset(
  store : @core.Store,
  candidates : @ids.Ids,
  query : @query.Query,
  needle : String,
) -> Unit {
  let hits = @exec.exec_scan(store, query) catch {
    err => abort("scan failed for '\{needle}': \{err.message()}")
  }
  for entry in hits {
    let id = store.global_id(entry)
    if !candidates.contains(id) {
      abort("candidate set missed id \{id} for needle '\{needle}'")
    }
  }
}

///|
test "trigram candidates are a superset of every scan match" {
  let store = compat_trigram_store()
  let index = @index.TrigramIndex::build(store)
  let universe = compat_all_ids(store)
  assert_eq(index.short_name_count(), 3)
  let mut needles = 0
  let mut indexed = 0
  let mut full_scans = 0
  for entry in store.entries_in_order() {
    let name = store.entry_name(entry)
    let length = name.length()
    if length < 3 {
      continue
    }
    for start in 0..<(length - 2) {
      let mut end = start + 3
      while end <= length {
        let needle = name[start:end]
        let text = @utf8.decode_lossy(needle)
        needles = needles + 1
        let candidates = match index.lookup(needle).candidates() {
          Some(ids) => {
            indexed = indexed + 1
            ids
          }
          None => {
            full_scans = full_scans + 1
            universe
          }
        }
        // The default is a case-insensitive substring query.
        assert_superset(store, candidates, @query.name_query(text), text)
        // Folding only broadens the candidate set, so a case-sensitive query
        // is covered by the same candidates.
        assert_superset(
          store,
          candidates,
          @query.name_query(text, flags=@query.Flags::new(case_sensitive=true)),
          text,
        )
        // An exact match is a subset of the substring matches.
        assert_superset(
          store,
          candidates,
          @query.name_query(text, flags=@query.Flags::new(exact=true)),
          text,
        )
        end = end + 1
      }
    }
  }
  assert_true(needles > 0)
  // Both paths must be exercised: postings for long needles, full scans for
  // the three-byte needles that are too common to narrow.
  assert_true(indexed > 0)
  assert_true(full_scans > 0)
}

///|
test "absent needles have empty candidates and empty matches" {
  let store = compat_trigram_store()
  let index = @index.TrigramIndex::build(store)
  for text in ["zzzz", "qqqq", "$$$"] {
    let bytes = @utf8.encode(text)
    let lookup = index.lookup(bytes[:])
    assert_true(lookup.is_missing())
    assert_eq(lookup.candidates().unwrap().cardinality(), 0)
    assert_eq(compat_scan_ids(store, @query.name_query(text)).cardinality(), 0)
  }
}

///|
test "a needle shorter than three bytes always scans" {
  let store = compat_trigram_store()
  let index = @index.TrigramIndex::build(store)
  for text in ["a", "ab", "z", ""] {
    assert_true(index.lookup(@utf8.encode(text)[:]).is_full_scan())
  }
}

///|

///|
/// `/p/docs/report.pdf`, where "docs" occurs only in the folder name.
fn path_trigram_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/p", false, 0L)
  let docs = builder.add_folder(root, "docs", 0L)
  ignore(builder.add_file(docs, "report.pdf", 1L, 0L))
  // Enough unrelated names to keep "docs" below the 20% stop-gram threshold.
  for index in 0..<20 {
    ignore(builder.add_file(root, "filler\{index}", 1L, 0L))
  }
  builder.set_child_counts(docs, 1U, 0U)
  builder.set_child_counts(root, 20U, 1U)
  builder.set_root_stats(0, 21U, 1U, 21L)
  builder.finish(built_at=0L)
}

///|
test "name trigrams do not cover path terms" {
  let store = path_trigram_store() catch {
    err => abort("path fixture failed: \{err.message()}")
  }
  let index = @index.TrigramIndex::build(store)
  let candidates = index.lookup(@utf8.encode("docs")[:]).candidates().unwrap()
  let query = @query.name_query(
    "docs",
    flags=@query.Flags::new(search_path=true),
  )
  let hits = @exec.exec_scan(store, query) catch {
    err => abort("path scan failed: \{err.message()}")
  }
  // The folder path and the file path both contain "docs".
  assert_eq(hits.length(), 2)
  // The name-only candidate set holds the folder but not the file, which is
  // why a path term must fall back to the scan engine in S10.
  assert_true(candidates.contains(1))
  assert_true(!candidates.contains(2))
}

///|

///|
/// One root folder and one three-byte folder below it.
fn folder_trigram_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let parent = builder.add_root("/q", false, 0L)
  ignore(builder.add_folder(parent, "doc", 0L))
  // Keep the "doc" posting below the 20% stop-gram threshold.
  for index in 0..<10 {
    ignore(builder.add_file(parent, "n\{index}", 1L, 0L))
  }
  builder.set_child_counts(parent, 10U, 1U)
  builder.set_root_stats(0, 10U, 1U, 10L)
  builder.finish(built_at=0L)
}

///|
test "folder names participate in the same candidate space" {
  let store = compat_trigram_store()
  let index = @index.TrigramIndex::build(store)
  // The root folder is two bytes long and therefore has no trigram.
  let root = index.lookup(@utf8.encode("/t")[:])
  assert_true(root.is_full_scan())
  // A three-byte folder name resolves through the same postings as files.
  let folder_store = folder_trigram_store() catch {
    err => abort("folder fixture failed: \{err.message()}")
  }
  let folder_index = @index.TrigramIndex::build(folder_store)
  assert_eq(
    folder_index
    .lookup(@utf8.encode("doc")[:])
    .candidates()
    .unwrap()
    .to_sorted_ids(),
    [1],
  )
}
