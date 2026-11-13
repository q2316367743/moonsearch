///|
/// Translate a parsed comparison into the matching `RangeIndex` operation.
///
/// This is the mapping S10 will use when it compiles `size:`, `dm:`, `depth:`,
/// and `childcount:` terms into candidate sets.
fn range_ids_of(
  index : @index.RangeIndex,
  comparison : @query.Comparison,
) -> @ids.Ids {
  match comparison.op {
    @query.Equal => index.equal(comparison.lo)
    @query.Greater => index.greater_than(comparison.lo)
    @query.GreaterEqual => index.at_least(comparison.lo)
    @query.Smaller => index.less_than(comparison.lo)
    @query.SmallerEqual => index.at_most(comparison.lo)
    @query.Range => index.range(comparison.lo, comparison.hi)
  }
}

///|
test "size range index matches the scan engine" {
  let store = compat_store()
  let ranges = @index.Ranges::build(store)
  let size = ranges.size()
  let cases : Array[(@query.Comparison, String)] = [
    (@query.Comparison::equal(0L), "size:0"),
    (@query.Comparison::equal(100L), "size:100"),
    (@query.Comparison::equal(500L), "size:500"),
    (@query.Comparison::equal(2000L), "size:2000"),
    (@query.Comparison::compare(@query.Greater, 1000L), "size:>1000"),
    (@query.Comparison::compare(@query.GreaterEqual, 1000L), "size:>=1000"),
    (@query.Comparison::compare(@query.Smaller, 500L), "size:<500"),
    (@query.Comparison::compare(@query.SmallerEqual, 500L), "size:<=500"),
    (@query.Comparison::range(100L, 2000L), "size:100..2000"),
    (@query.Comparison::range(2000L, 100L), "size:2000..100"),
  ]
  for pair in cases {
    let comparison = pair.0
    let query = pair.1
    assert_eq(
      dict_sorted_paths(store, range_ids_of(size, comparison)),
      sorted_copy(matched(query)),
    )
  }
}

///|
test "mtime range index matches the scan engine" {
  let store = compat_store()
  let ranges = @index.Ranges::build(store)
  let mtime = ranges.mtime()
  let zone = @time.utc_zone
  let february = @util.resolve_date_span("2024-02", TEST_NOW, zone).unwrap()
  let march = @util.resolve_date_span("2024-03", TEST_NOW, zone).unwrap()
  let january = @util.resolve_date_span("2024-01", TEST_NOW, zone).unwrap()
  // `dm:2024-03` is the whole month, i.e. the half-open span.
  assert_eq(
    dict_sorted_paths(store, mtime.range(march.start, march.end)),
    sorted_copy(matched("dm:2024-03")),
  )
  // `dm:>2024-02` starts after the whole of February.
  assert_eq(
    dict_sorted_paths(store, mtime.at_least(february.end)),
    sorted_copy(matched("dm:>2024-02")),
  )
  // `dm:<2024-03` stops at the start of March.
  assert_eq(
    dict_sorted_paths(store, mtime.less_than(march.start)),
    sorted_copy(matched("dm:<2024-03")),
  )
  // A date range maps to the start of its first and last unit.
  assert_eq(
    dict_sorted_paths(store, mtime.range(january.start, march.start)),
    sorted_copy(matched("dm:2024-01..2024-03")),
  )
}

///|
test "depth range index matches the scan engine" {
  let store = compat_store()
  let ranges = @index.Ranges::build(store)
  let depth = ranges.depth()
  let cases : Array[(@query.Comparison, String)] = [
    (@query.Comparison::equal(0L), "depth:0"),
    (@query.Comparison::equal(1L), "depth:1"),
    (@query.Comparison::equal(2L), "depth:2"),
    (@query.Comparison::compare(@query.SmallerEqual, 2L), "depth:<=2"),
    (@query.Comparison::compare(@query.Greater, 2L), "depth:>2"),
    (@query.Comparison::range(1L, 3L), "depth:1..3"),
  ]
  for pair in cases {
    assert_eq(
      dict_sorted_paths(store, range_ids_of(depth, pair.0)),
      sorted_copy(matched(pair.1)),
    )
  }
}

///|
test "child count range index matches the scan engine" {
  let store = compat_store()
  let ranges = @index.Ranges::build(store)
  let children = ranges.child_count()
  let cases : Array[(@query.Comparison, String)] = [
    (@query.Comparison::equal(0L), "childcount:0"),
    (@query.Comparison::equal(1L), "childcount:1"),
    (@query.Comparison::equal(2L), "childcount:2"),
    (@query.Comparison::compare(@query.GreaterEqual, 3L), "childcount:>=3"),
    (@query.Comparison::compare(@query.Smaller, 1L), "childcount:<1"),
    (@query.Comparison::range(2L, 6L), "childcount:2..6"),
  ]
  for pair in cases {
    assert_eq(
      dict_sorted_paths(store, range_ids_of(children, pair.0)),
      sorted_copy(matched(pair.1)),
    )
  }
  // `empty:` is the same predicate as a folder with no direct children.
  assert_eq(
    dict_sorted_paths(store, children.equal(0L)),
    sorted_copy(matched("empty:")),
  )
}

///|
test "parent range index matches the scan engine" {
  let store = compat_store()
  let ranges = @index.Ranges::build(store)
  assert_eq(
    dict_sorted_paths(store, ranges.parent_ids(b"/root"[:])),
    sorted_copy(matched("parent:/root")),
  )
  assert_eq(
    dict_sorted_paths(store, ranges.parent_ids(b"/root/docs"[:])),
    sorted_copy(matched("parent:/root/docs")),
  )
  assert_eq(
    dict_sorted_paths(store, ranges.parent_ids(b"/root/media"[:])),
    sorted_copy(matched("parent:/root/media")),
  )
  assert_eq(ranges.parent_ids(b"/missing"[:]).cardinality(), 0)
  assert_eq(
    dict_sorted_paths(store, ranges.parent_ids(b"/root/docs"[:])),
    sorted_copy(matched("parent:/root/docs/")),
  )
}
