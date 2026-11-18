// S13 property tests that need a real index.
//
// Three properties from the plan are covered here:
//
// - **no false negatives**: for every generated needle, the trigram candidate
//   set is a superset of the linear-scan matches;
// - **persistence**: a database written and read back answers the corpus
//   identically, with and without trigram postings;
// - **order independence**: repeated evaluation and shuffled input produce the
//   same result, and the reverse scan is the exact mirror of the forward scan.

///|
/// Build an index over a deterministic random tree.
fn property_index(seed : UInt64, entries : Int32) -> @index.Index {
  let store = diff_random_store(seed, entries) catch {
    err => abort("random fixture failed: \{err.message()}")
  }
  diff_index(store)
}

///|
/// Scan matches for a needle under one flag set.
fn property_scan_matches(
  store : @core.Store,
  text : String,
  flags : @query.Flags,
) -> Array[Int32] {
  let query = @query.name_query(text, flags~)
  diff_scan_ids(store, query) catch {
    err => abort("scan failed for '\{text}': \{err.message()}")
  }
}

///|
test "trigram candidates never miss a linear-scan match" {
  let index = property_index(20241118UL, 60)
  let store = index.store()
  let trigram = match index.trigram() {
    Some(trigram) => trigram
    None => abort("the fixture index has no trigram postings")
  }
  let universe = @ids.Ids::from_sorted(
    Array::makei(store.entry_count(), fn(id) { id }),
    total=store.entry_count(),
  )
  let rng = @testkit.Rng::new(424242UL)
  let needles : Array[String] = []
  // Substrings of real names: these must be found if the index is sound.
  for entry in store.entries_in_order() {
    let name = @utf8.decode_lossy(store.entry_name(entry))
    let length = name.length()
    if length < 3 {
      continue
    }
    for _ in 0..<6 {
      let start = rng.below(length - 2)
      let span = rng.between(3, 6)
      let end = if start + span > length { length } else { start + span }
      needles.push(name[start:end].to_owned())
    }
  }
  // Arbitrary strings, including needles no name contains and one- and
  // two-byte needles that cannot use a trigram at all.
  let alphabet : Array[String] = [
    "a", "b", "c", "r", "e", "p", "o", "t", "-", ".", "0", "1", "t", "es", "re",
    "xyz", "report", "zzzz", "发票",
  ]
  for _ in 0..<120 {
    let parts = rng.between(0, 5)
    let out = StringBuilder()
    for _ in 0..<parts {
      out.write_string(rng.pick(alphabet))
    }
    needles.push(out.to_string())
  }
  let flag_sets : Array[@query.Flags] = [
    @query.Flags::new(),
    @query.Flags::new(case_sensitive=true),
    @query.Flags::new(exact=true),
    @query.Flags::new(case_sensitive=true, exact=true),
  ]
  let mut checks = 0
  for text in needles {
    let lookup = trigram.lookup(@utf8.encode(text))
    let candidates = match lookup.candidates() {
      Some(candidates) => candidates
      None => universe
    }
    for flags in flag_sets {
      let matches = property_scan_matches(store, text, flags)
      if lookup.is_missing() && matches.length() > 0 {
        abort("missing trigram '\{text}' still had \{matches.length()} matches")
      }
      for id in matches {
        if !candidates.contains(id) {
          abort(
            "candidate set for '\{text}' missed scan match \{id} (flags \{flags.describe()})",
          )
        }
      }
      checks = checks + 1
    }
  }
  assert_true(checks > 0)
}

///|
/// Compare the same corpus on two indexes and fail on the first difference.
fn property_compare_indexes(
  original : @index.Index,
  reloaded : @index.Index,
  label : String,
) -> Unit raise {
  let queries = diff_corpus(20241118UL, 60)
  for text in queries {
    let query = diff_parse(text)
    let expected = @exec.exec_indexed(
      original,
      query,
      options=diff_plan_options(optimize=true),
    ).to_sorted_ids()
    let actual = @exec.exec_indexed(
      reloaded,
      query,
      options=diff_plan_options(optimize=true),
    ).to_sorted_ids()
    if actual != expected {
      abort(
        "\{label} changed query '\{text}': before=\{diff_ids_text(expected)} after=\{diff_ids_text(actual)}",
      )
    }
    let count = @exec.exec_indexed_count(
      reloaded,
      query,
      options=diff_plan_options(optimize=true),
    )
    if count != expected.length() {
      abort("\{label} changed the count of '\{text}'")
    }
  }
}

///|
test "a database round trip preserves every query result" {
  let index = property_index(777UL, 60)
  let bytes = index.to_bytes() catch {
    err => abort("encode failed: \{err.message()}")
  }
  let reloaded = @index.Index::from_bytes(bytes[:], verify=true) catch {
    err => abort("decode failed: \{err.message()}")
  }
  assert_eq(reloaded.entry_count(), index.entry_count())
  assert_true(reloaded.trigram() is Some(_))
  property_compare_indexes(index, reloaded, "reloaded database")
  // A --no-trigram database stays without postings and still answers the same.
  let plain = @index.Index::build(
    index.store(),
    eager=@index.RangeFieldSet::all(),
    trigram=false,
  )
  let plain_bytes = plain.to_bytes() catch {
    err => abort("no-trigram encode failed: \{err.message()}")
  }
  let plain_reloaded = @index.Index::from_bytes(plain_bytes[:], verify=true) catch {
    err => abort("no-trigram decode failed: \{err.message()}")
  }
  assert_true(plain_reloaded.trigram() is None)
  property_compare_indexes(plain, plain_reloaded, "no-trigram database")
}

///|
/// Copy and deterministically shuffle an entry list.
fn property_shuffle(
  rng : @testkit.Rng,
  values : Array[@core.EntryRef],
) -> Array[@core.EntryRef] {
  let copy : Array[@core.EntryRef] = []
  for value in values {
    copy.push(value)
  }
  let mut index = copy.length() - 1
  while index > 0 {
    let other = rng.below(index + 1)
    let temporary = copy[index]
    copy[index] = copy[other]
    copy[other] = temporary
    index = index - 1
  }
  copy
}

///|
/// Paths of a hit list, for order comparisons.
fn property_paths(
  store : @core.Store,
  hits : Array[@core.EntryRef],
) -> Array[String] {
  hits.map(fn(entry) { @utf8.decode_lossy(store.entry_path(entry)) })
}

///|
test "query output is independent of repetition and input order" {
  let index = property_index(99UL, 60)
  let store = index.store()
  // Repeating the same query must be byte-identical, and the canonical
  // expansion of the indexed set must equal the scan order.
  for text in ["", "file:", "ext:txt", "report", "size:>1000", "!pdf"] {
    let query = diff_parse(text)
    let first = @exec.exec_indexed(
      index,
      query,
      options=diff_plan_options(optimize=true),
    ).to_sorted_ids()
    for _ in 0..<3 {
      let again = @exec.exec_indexed(
        index,
        query,
        options=diff_plan_options(optimize=true),
      ).to_sorted_ids()
      assert_eq(again, first)
    }
    let scan = diff_scan_ids(store, query) catch {
      err => abort("scan failed: \{err.message()}")
    }
    assert_eq(diff_canonical(store, @ids.Ids::from_sorted(first)), scan)
    // The reverse scan without a limit is the mirror image of the forward one.
    let forward = @exec.exec_scan_with(
      store,
      query,
      options=diff_scan_options(),
    ) catch {
      err => abort("forward scan failed: \{err.message()}")
    }
    let backward = @exec.exec_scan_reverse_with(
      store,
      query,
      options=diff_scan_options(),
    ) catch {
      err => abort("reverse scan failed: \{err.message()}")
    }
    let mirrored : Array[@core.EntryRef] = []
    for position in 0..<backward.length() {
      mirrored.push(backward[backward.length() - 1 - position])
    }
    assert_eq(property_paths(store, mirrored), property_paths(store, forward))
  }
  // Every sort key must ignore the order in which hits are supplied. Plain
  // forward name order is the exception: it deliberately returns canonical
  // input unchanged so the engine can stream, which is why `search` feeds it
  // the store's canonical order rather than an arbitrary hit array.
  let all = @exec.exec_scan_with(
    store,
    diff_parse(""),
    options=diff_scan_options(),
  ) catch {
    err => abort("scan failed: \{err.message()}")
  }
  let rng = @testkit.Rng::new(555UL)
  for key in @exec.SortKey::all() {
    for reverse in [false, true] {
      for folders_first in [false, true] {
        if key is @exec.Name && !reverse && !folders_first {
          continue
        }
        let options = @exec.OrderOptions::new(key~, reverse~, folders_first~)
        let expected = property_paths(
          store,
          @exec.order_hits(store, all, options),
        )
        let shuffled = property_shuffle(rng, all)
        let actual = property_paths(
          store,
          @exec.order_hits(store, shuffled, options),
        )
        assert_eq(actual, expected)
      }
    }
  }
  // The canonical identity is still checked, with canonical input.
  assert_eq(
    property_paths(
      store,
      @exec.order_hits(store, all, @exec.OrderOptions::new()),
    ),
    property_paths(store, all),
  )
}
