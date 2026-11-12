///|
test "default flags describe as empty" {
  let flags = @query.Flags::new()
  assert_true(flags.is_default())
  assert_eq(flags.describe(), "")
  assert_eq(flags.kind.describe(), "any")
}

///|
test "flag descriptions list every non-default value in order" {
  let flags = @query.Flags::new(
    case_sensitive=true,
    exact=true,
    search_path=true,
    regex=true,
    kind=@query.FilesOnly,
  )
  assert_false(flags.is_default())
  assert_eq(flags.describe(), "case exact path regex kind=file")
}

///|
test "flag updates return a copy" {
  let base = @query.Flags::new()
  let updated = base.with_case_sensitive(true)
  assert_false(base.case_sensitive)
  assert_true(updated.case_sensitive)
  assert_eq(updated.with_kind(@query.FoldersOnly).kind.describe(), "folder")
}
