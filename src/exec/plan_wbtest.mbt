///|
/// A three-file store for exercising the evaluator's owned work buffers.
fn workspace_store() -> @core.Store {
  let names = @core.NamePool::new()
  let a = names.add(b"a"[:]) catch { _ => abort("workspace name failed") }
  let b = names.add(b"b"[:]) catch { _ => abort("workspace name failed") }
  let c = names.add(b"c"[:]) catch { _ => abort("workspace name failed") }
  let files : Array[@core.Entry] = [
    @core.Entry::file(parent=@core.NO_PARENT, name=a, size=10L, mtime=0L),
    @core.Entry::file(parent=@core.NO_PARENT, name=b, size=20L, mtime=0L),
    @core.Entry::file(parent=@core.NO_PARENT, name=c, size=30L, mtime=0L),
  ]
  @core.Store::new(names~, folders=[], files~, roots=[], built_at=0L)
}

///|
fn workspace_context(store : @core.Store) -> EvalContext {
  {
    store,
    universe: @ids.Ids::from_sorted([0, 1, 2]),
    total: 128,
    scratch: [],
  }
}

///|
fn workspace_size_term() -> ScanTerm {
  {
    kind: @query.KindFilter::AnyKind,
    visibility: @query.VisibilityFilter::AnyVisibility,
    body: ScanTest::Size(@query.Comparison::compare(@query.CmpOp::Greater, 15L)),
  }
}

///|
test "compact_filter overwrites only visited ids and truncates the tail" {
  let values : Array[Int32] = [0, 1, 2, 3, 4]
  compact_filter(values, fn(id) { id % 2 == 1 })
  assert_eq(values, [1, 3])
  compact_filter(values, fn(_) { false })
  assert_true(values.is_empty())
  compact_filter(values, fn(_) { true })
  assert_true(values.is_empty())
}

///|
test "scratch buffers are returned to the evaluation pool" {
  let context = workspace_context(workspace_store())
  let buffer = take_scratch(context)
  buffer.push(42)
  recycle_scratch(context, buffer)
  assert_eq(context.scratch.length(), 1)
  let reused = take_scratch(context)
  assert_eq(context.scratch.length(), 0)
  assert_true(reused.is_empty())
  reused.push(7)
  assert_eq(reused, [7])
}

///|
test "filter compacts an owned sorted buffer without taking a scratch buffer" {
  let context = workspace_context(workspace_store())
  let spare : Array[Int32] = [99]
  context.scratch.push(spare)
  let owned : Array[Int32] = [0, 1, 2]
  let source = owned_result(
    @ids.Ids::from_sorted_canonical(owned, total=context.total),
  )
  let result = filter_result(source, workspace_size_term(), context)
  assert_eq(result.ids.to_sorted_ids(), [1, 2])
  assert_eq(result.recyclable, Some([1, 2]))
  assert_eq(context.scratch.length(), 1)
  release_result(result, context)
  assert_eq(context.scratch.length(), 2)
}

///|
test "filter streams shared sorted and bitmap sources into a pooled buffer" {
  let context = workspace_context(workspace_store())
  let spare : Array[Int32] = [99]
  context.scratch.push(spare)
  let shared = filter_result(
    shared_result(@ids.Ids::from_sorted([0, 1, 2])),
    workspace_size_term(),
    context,
  )
  assert_eq(shared.ids.to_sorted_ids(), [1, 2])
  assert_eq(context.scratch.length(), 0)
  release_result(shared, context)
  assert_eq(context.scratch.length(), 1)

  let dense : Array[Int32] = []
  for index in 0..<5000 {
    dense.push(index)
  }
  let bitmap = filter_result(
    shared_result(@ids.Ids::from_sorted(dense)),
    workspace_size_term(),
    context,
  )
  assert_eq(bitmap.ids.to_sorted_ids(), [1, 2])
  assert_eq(context.scratch.length(), 0)
  release_result(bitmap, context)
  assert_eq(context.scratch.length(), 1)
}

///|
fn workspace_expr(text : String) -> Expr {
  let index = @index.Index::build(workspace_store())
  let query = @query.parse(text) catch {
    err => abort("workspace query failed: \{err.message()}")
  }
  compile_indexed(index, query, options=PlanOptions::new(optimize=false)) catch {
    err => abort("workspace compile failed: \{err.message()}")
  }
}

///|
test "empty branches preserve shared or owned result ownership" {
  let context = workspace_context(workspace_store())
  let no_match = workspace_expr("path:zzzz")
  let universe = workspace_expr("")
  let negated = evaluate_plan(Not(no_match), context)
  assert_eq(negated.ids.to_sorted_ids(), [0, 1, 2])
  assert_true(negated.recyclable is None)

  let left_empty = evaluate_plan(Or(no_match, universe), context)
  assert_eq(left_empty.ids.to_sorted_ids(), [0, 1, 2])
  assert_true(left_empty.recyclable is None)
  let right_empty = evaluate_plan(Or(universe, no_match), context)
  assert_eq(right_empty.ids.to_sorted_ids(), [0, 1, 2])
  assert_true(right_empty.recyclable is None)
  assert_eq(context.scratch.length(), 1)
}
