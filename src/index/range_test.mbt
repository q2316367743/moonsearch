///|
/// A small tree with duplicate sizes, duplicate dates, several depths, and one
/// empty folder:
///
/// ```text
/// /r                      folder 0, size 65, mtime 1000
///   a.txt                 file 0, size 10, mtime 100
///   b.txt                 file 1, size 10, mtime 200
///   sub                   folder 1, size 20, mtime 300
///     c.bin               file 2, size 20, mtime 300
///   deep                  folder 2, size 25, mtime 400
///     deeper              folder 3, size 25, mtime 500
///       d.txt             file 3, size 25, mtime 500
/// ```
///
/// Global ids are folders `0..3` followed by files `4..7`.
fn range_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/r", false, 1000L)
  ignore(builder.add_file(root, "a.txt", 10L, 100L))
  ignore(builder.add_file(root, "b.txt", 10L, 200L))
  let sub = builder.add_folder(root, "sub", 300L)
  ignore(builder.add_file(sub, "c.bin", 20L, 300L))
  builder.set_child_counts(sub, 1U, 0U)
  builder.add_folder_size(sub, 20L)
  let deep = builder.add_folder(root, "deep", 400L)
  let deeper = builder.add_folder(deep, "deeper", 500L)
  ignore(builder.add_file(deeper, "d.txt", 25L, 500L))
  builder.set_child_counts(deeper, 1U, 0U)
  builder.add_folder_size(deeper, 25L)
  builder.add_folder_size(deep, 25L)
  builder.set_child_counts(deep, 0U, 1U)
  builder.set_child_counts(root, 2U, 2U)
  builder.add_folder_size(root, 65L)
  builder.set_root_stats(0, 4U, 4U, 65L)
  builder.finish(built_at=0L)
}

///|
/// Values of an index in sorted order.
fn range_values(index : @index.RangeIndex) -> Array[Int64] {
  let values : Array[Int64] = []
  for position in 0..<index.len() {
    values.push(index.value_at(position).unwrap())
  }
  values
}

///|
/// Ids of an index in sorted order.
fn range_ids(index : @index.RangeIndex) -> Array[Int32] {
  let ids : Array[Int32] = []
  for position in 0..<index.len() {
    ids.push(index.id_at(position).unwrap())
  }
  ids
}

///|
test "range index sorts pairs by value and then by id" {
  let index = @index.RangeIndex::build(
    [(5L, 40), (1L, 30), (1L, 10), (3L, 20), (5L, 5), (9L, 50)],
    total=60,
  )
  assert_eq(index.len(), 6)
  assert_eq(range_values(index), [1L, 1L, 3L, 5L, 5L, 9L])
  assert_eq(range_ids(index), [10, 30, 20, 5, 40, 50])
  assert_eq(index.value_at(-1), None)
  assert_eq(index.value_at(6), None)
  assert_eq(index.id_at(6), None)
}

///|
test "lower and upper bounds cover positions below, inside, and above" {
  let index = @index.RangeIndex::build([
    (1L, 10),
    (1L, 30),
    (3L, 20),
    (5L, 5),
    (5L, 40),
    (9L, 50),
  ])
  assert_eq(index.lower_bound(0L), 0)
  assert_eq(index.upper_bound(0L), 0)
  assert_eq(index.lower_bound(1L), 0)
  assert_eq(index.upper_bound(1L), 2)
  assert_eq(index.lower_bound(2L), 2)
  assert_eq(index.upper_bound(2L), 2)
  assert_eq(index.lower_bound(5L), 3)
  assert_eq(index.upper_bound(5L), 5)
  assert_eq(index.lower_bound(9L), 5)
  assert_eq(index.upper_bound(9L), 6)
  assert_eq(index.lower_bound(10L), 6)
  assert_eq(index.upper_bound(10L), 6)
  let empty = @index.RangeIndex::empty()
  assert_true(empty.is_empty())
  assert_eq(empty.lower_bound(0L), 0)
  assert_eq(empty.upper_bound(0L), 0)
}

///|
test "range is half-open and an empty interval selects nothing" {
  let index = @index.RangeIndex::build([
    (1L, 10),
    (1L, 30),
    (3L, 20),
    (5L, 5),
    (5L, 40),
    (9L, 50),
  ])
  assert_eq(index.range(1L, 3L).to_sorted_ids(), [10, 30])
  assert_eq(index.range(1L, 5L).to_sorted_ids(), [10, 20, 30])
  assert_eq(index.range(4L, 6L).to_sorted_ids(), [5, 40])
  assert_eq(index.range(0L, 100L).to_sorted_ids(), [5, 10, 20, 30, 40, 50])
  assert_eq(index.range(5L, 5L).cardinality(), 0)
  assert_eq(index.range(6L, 5L).cardinality(), 0)
  assert_eq(index.range(9L, 9L).cardinality(), 0)
  assert_eq(index.range(-10L, 0L).cardinality(), 0)
}

///|
test "equal returns the whole run of duplicate values" {
  let index = @index.RangeIndex::build([
    (1L, 10),
    (1L, 30),
    (3L, 20),
    (5L, 5),
    (5L, 40),
    (9L, 50),
  ])
  assert_eq(index.equal(1L).to_sorted_ids(), [10, 30])
  assert_eq(index.equal(3L).to_sorted_ids(), [20])
  assert_eq(index.equal(5L).to_sorted_ids(), [5, 40])
  assert_eq(index.equal(9L).to_sorted_ids(), [50])
  assert_eq(index.equal(4L).cardinality(), 0)
  assert_eq(index.equal(0L).cardinality(), 0)
}

///|
test "comparison helpers agree with their mathematical definitions" {
  let index = @index.RangeIndex::build([
    (1L, 10),
    (1L, 30),
    (3L, 20),
    (5L, 5),
    (5L, 40),
    (9L, 50),
  ])
  assert_eq(index.at_least(5L).to_sorted_ids(), [5, 40, 50])
  assert_eq(index.greater_than(5L).to_sorted_ids(), [50])
  assert_eq(index.at_most(5L).to_sorted_ids(), [5, 10, 20, 30, 40])
  assert_eq(index.less_than(5L).to_sorted_ids(), [10, 20, 30])
  assert_eq(index.at_least(10L).cardinality(), 0)
  assert_eq(index.at_most(0L).cardinality(), 0)
  assert_eq(index.greater_than(9L).cardinality(), 0)
  assert_eq(index.less_than(1L).cardinality(), 0)
}

///|
test "range results use the index-wide density rule" {
  let entries : Array[(Int64, Int32)] = Array::makei(5000, fn(id) { (7L, id) })
  let dense = @index.RangeIndex::build(entries, total=10000)
  let ids = dense.equal(7L)
  assert_eq(ids.cardinality(), 5000)
  assert_true(ids is @ids.Ids::Bitmap(_))
  let sparse = @index.RangeIndex::build(
    [(7L, 1), (7L, 2), (7L, 3)],
    total=10000,
  )
  assert_true(sparse.equal(7L) is @ids.Ids::Sorted(_))
}

///|
test "field sets parse names, aliases, spaces, and reject unknown names" {
  let default = match @index.RangeFieldSet::parse("size,mtime") {
    Ok(set) => set
    Err(message) => abort("default fast fields failed: \{message}")
  }
  assert_true(default.contains(@index.RangeField::Size))
  assert_true(default.contains(@index.RangeField::MTime))
  assert_false(default.contains(@index.RangeField::Depth))
  assert_eq(default.size(), 2)
  assert_eq(default.describe(), "size,mtime")
  let aliased = match @index.RangeFieldSet::parse(" dm , children , parent ") {
    Ok(set) => set
    Err(message) => abort("aliased fast fields failed: \{message}")
  }
  assert_true(aliased.contains(@index.RangeField::MTime))
  assert_true(aliased.contains(@index.RangeField::ChildCount))
  assert_true(aliased.contains(@index.RangeField::Parent))
  assert_eq(aliased.describe(), "mtime,childcount,parent")
  let empty = match @index.RangeFieldSet::parse("  ") {
    Ok(set) => set
    Err(message) => abort("empty fast fields failed: \{message}")
  }
  assert_true(empty.is_empty())
  match @index.RangeFieldSet::parse("size,bogus") {
    Err(message) => assert_true(message.contains("bogus"))
    Ok(_) => abort("an unknown field must be rejected")
  }
  match @index.RangeFieldSet::parse("size,,mtime") {
    Err(_) => ()
    Ok(_) => abort("an empty field name must be rejected")
  }
  let all = @index.RangeFieldSet::all()
  assert_eq(all.size(), 5)
  assert_eq(all.describe(), "size,mtime,depth,childcount,parent")
  assert_eq(@index.RangeFieldSet::empty().describe(), "")
}

///|
test "ranges build the five default fields" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  assert_eq(ranges.entry_count(), 8)
  assert_eq(ranges.size().len(), 8)
  assert_eq(ranges.mtime().len(), 8)
  assert_eq(ranges.depth().len(), 8)
  assert_eq(ranges.child_count().len(), 4)
  assert_eq(ranges.parent().len(), 7)
  assert_eq(ranges.size().is_empty(), false)
}

///|
test "size index orders files and folders together" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  let size = ranges.size()
  assert_eq(range_values(size), [10L, 10L, 20L, 20L, 25L, 25L, 25L, 65L])
  assert_eq(range_ids(size), [4, 5, 1, 6, 2, 3, 7, 0])
  // A folder's size is its subtree total, so the root is the largest entry.
  assert_eq(size.equal(65L).to_sorted_ids(), [0])
  assert_eq(size.equal(20L).to_sorted_ids(), [1, 6])
  assert_eq(size.equal(25L).to_sorted_ids(), [2, 3, 7])
  assert_eq(size.range(10L, 25L).to_sorted_ids(), [1, 4, 5, 6])
}

///|
test "mtime index keeps duplicate timestamps in id order" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  let mtime = ranges.mtime()
  assert_eq(range_values(mtime), [
    100L, 200L, 300L, 300L, 400L, 500L, 500L, 1000L,
  ])
  assert_eq(range_ids(mtime), [4, 5, 1, 6, 2, 3, 7, 0])
  assert_eq(mtime.equal(300L).to_sorted_ids(), [1, 6])
  assert_eq(mtime.equal(500L).to_sorted_ids(), [3, 7])
  assert_eq(mtime.range(300L, 500L).to_sorted_ids(), [1, 2, 6])
}

///|
test "depth index matches the scan engine definition" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  let depth = ranges.depth()
  assert_eq(range_values(depth), [0L, 1L, 1L, 1L, 1L, 2L, 2L, 3L])
  assert_eq(range_ids(depth), [0, 1, 2, 4, 5, 3, 6, 7])
  assert_eq(depth.equal(0L).to_sorted_ids(), [0])
  assert_eq(depth.equal(1L).to_sorted_ids(), [1, 2, 4, 5])
  assert_eq(depth.equal(2L).to_sorted_ids(), [3, 6])
  assert_eq(depth.equal(3L).to_sorted_ids(), [7])
  assert_eq(depth.at_least(2L).to_sorted_ids(), [3, 6, 7])
}

///|
test "child count index covers folders only" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  let children = ranges.child_count()
  assert_eq(range_values(children), [1L, 1L, 1L, 4L])
  assert_eq(range_ids(children), [1, 2, 3, 0])
  assert_eq(children.equal(0L).cardinality(), 0)
  assert_eq(children.equal(4L).to_sorted_ids(), [0])
  assert_eq(children.equal(1L).to_sorted_ids(), [1, 2, 3])
}

///|
test "parent index is counting-sorted and skips roots" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  let parent = ranges.parent()
  assert_eq(parent.len(), 7)
  assert_eq(range_values(parent), [0L, 0L, 0L, 0L, 1L, 2L, 3L])
  assert_eq(range_ids(parent), [1, 2, 4, 5, 6, 3, 7])
  assert_eq(parent.equal(0L).to_sorted_ids(), [1, 2, 4, 5])
  assert_eq(parent.equal(1L).to_sorted_ids(), [6])
  assert_eq(parent.equal(2L).to_sorted_ids(), [3])
  assert_eq(parent.equal(3L).to_sorted_ids(), [7])
}

///|
test "parent paths resolve to folder ids and parent sets" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let ranges = @index.Ranges::build(store)
  assert_eq(ranges.parent_of(b"/r"[:]), Some(0))
  assert_eq(ranges.parent_of(b"/r/sub"[:]), Some(1))
  assert_eq(ranges.parent_of(b"/r/deep/deeper"[:]), Some(3))
  assert_true(ranges.parent_of(b"/missing"[:]) is None)
  assert_true(ranges.parent_of(b"/r/sub/"[:]) is None)
  assert_eq(ranges.parent_ids(b"/r"[:]).to_sorted_ids(), [1, 2, 4, 5])
  assert_eq(ranges.parent_ids(b"/r/sub"[:]).to_sorted_ids(), [6])
  assert_eq(ranges.parent_ids(b"/missing"[:]).cardinality(), 0)
}

///|
test "eager fields are built up front and the rest are lazy" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let eager = @index.RangeFieldSet::of([@index.RangeField::Size])
  let ranges = @index.Ranges::build(store, eager~)
  assert_true(ranges.is_loaded(@index.RangeField::Size))
  assert_false(ranges.is_loaded(@index.RangeField::MTime))
  assert_false(ranges.is_loaded(@index.RangeField::Depth))
  assert_false(ranges.is_loaded(@index.RangeField::ChildCount))
  assert_false(ranges.is_loaded(@index.RangeField::Parent))
  assert_eq(ranges.mtime().len(), 8)
  assert_true(ranges.is_loaded(@index.RangeField::MTime))
  assert_eq(ranges.depth().equal(2L).to_sorted_ids(), [3, 6])
  assert_true(ranges.is_loaded(@index.RangeField::Depth))
  assert_eq(ranges.child_count().equal(4L).to_sorted_ids(), [0])
  assert_true(ranges.is_loaded(@index.RangeField::ChildCount))
  assert_eq(ranges.parent_ids(b"/r/sub"[:]).to_sorted_ids(), [6])
  assert_true(ranges.is_loaded(@index.RangeField::Parent))
}

///|
test "depth resolves a parent stored after its child" {
  // The builder always assigns parents first, but Store::new accepts any array
  // order; the memoized depth pass must still find the chain.
  let names = @core.NamePool::new()
  let root_name = names.add(b"/late"[:])
  let child_name = names.add(b"c"[:])
  let file_name = names.add(b"f.txt"[:])
  let store = @core.Store::new(
    names~,
    folders=[
      @core.Entry::folder(parent=1, name=child_name, mtime=0L),
      @core.Entry::folder(parent=@core.NO_PARENT, name=root_name, mtime=0L),
    ],
    files=[@core.Entry::file(parent=0, name=file_name, size=1L, mtime=0L)],
    roots=[
      {
        path: "/late",
        one_file_system: false,
        folder: 1,
        files: 1U,
        folders: 1U,
        size: 1L,
      },
    ],
    built_at=0L,
  )
  let ranges = @index.Ranges::build(store)
  assert_eq(ranges.depth().equal(0L).to_sorted_ids(), [1])
  assert_eq(ranges.depth().equal(1L).to_sorted_ids(), [0])
  assert_eq(ranges.depth().equal(2L).to_sorted_ids(), [2])
  // The root has no parent, so only the child and the file enter the index.
  assert_eq(range_values(ranges.parent()), [0L, 1L])
  assert_eq(range_ids(ranges.parent()), [2, 0])
  assert_eq(ranges.parent().equal(1L).to_sorted_ids(), [0])
  assert_eq(ranges.parent().equal(0L).to_sorted_ids(), [2])
}

///|
test "an empty store produces empty range indexes" {
  let store = @index.Builder::new().finish(built_at=0L)
  let ranges = @index.Ranges::build(store)
  assert_eq(ranges.entry_count(), 0)
  for field in @index.RangeField::all() {
    assert_eq(ranges.field(field).len(), 0)
  }
  assert_true(ranges.parent_of(b"/"[:]) is None)
  assert_eq(ranges.parent_ids(b"/"[:]).cardinality(), 0)
}

///|
test "range builds are deterministic" {
  let store = range_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let first = @index.Ranges::build(store)
  let second = @index.Ranges::build(store)
  for field in @index.RangeField::all() {
    assert_eq(
      range_values(first.field(field)),
      range_values(second.field(field)),
    )
    assert_eq(range_ids(first.field(field)), range_ids(second.field(field)))
  }
}
