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

///|
test "every flag setter changes exactly one field" {
  let base = @query.Flags::new()
  let exact = base.with_exact(true)
  assert_true(exact.exact)
  assert_false(exact.case_sensitive)
  let path = base.with_search_path(true)
  assert_true(path.search_path)
  assert_false(path.exact)
  let regex = base.with_regex(true)
  assert_true(regex.regex)
  assert_false(regex.search_path)
  let kind = base.with_kind(@query.FilesOnly)
  assert_true(kind.kind is @query.FilesOnly)
  assert_false(kind.regex)
  // Updating one flag preserves the others.
  let all = base
    .with_case_sensitive(true)
    .with_exact(true)
    .with_search_path(true)
    .with_regex(true)
    .with_kind(@query.FoldersOnly)
  assert_eq(all.describe(), "case exact path regex kind=folder")
}

///|
/// Describe a single-word query; used to observe auto case detection.
fn described_word(word : String) -> String {
  @query.parse(word).describe() catch {
    err => abort(err.message())
  }
}

///|
test "non-ASCII uppercase detection covers the documented ranges" {
  // Latin-1 Supplement.
  assert_eq(described_word("À"), "(name \"À\" case)")
  assert_eq(described_word("Ö"), "(name \"Ö\" case)")
  assert_eq(described_word("Ø"), "(name \"Ø\" case)")
  assert_eq(described_word("Þ"), "(name \"Þ\" case)")
  assert_eq(described_word("ß"), "(name \"ß\")")
  assert_eq(described_word("÷"), "(name \"÷\")")
  // Latin Extended-A pairs switch direction part way through the block.
  assert_eq(described_word("Ā"), "(name \"Ā\" case)")
  assert_eq(described_word("ā"), "(name \"ā\")")
  assert_eq(described_word("Ĺ"), "(name \"Ĺ\" case)")
  assert_eq(described_word("ĺ"), "(name \"ĺ\")")
  assert_eq(described_word("Ł"), "(name \"Ł\" case)")
  assert_eq(described_word("ł"), "(name \"ł\")")
  assert_eq(described_word("Ń"), "(name \"Ń\" case)")
  assert_eq(described_word("ń"), "(name \"ń\")")
  assert_eq(described_word("Ź"), "(name \"Ź\" case)")
  assert_eq(described_word("ź"), "(name \"ź\")")
  assert_eq(described_word("Ż"), "(name \"Ż\" case)")
  assert_eq(described_word("ż"), "(name \"ż\")")
  assert_eq(described_word("Ž"), "(name \"Ž\" case)")
  assert_eq(described_word("ž"), "(name \"ž\")")
  assert_eq(described_word("ſ"), "(name \"ſ\")")
  // Greek.
  assert_eq(described_word("Ά"), "(name \"Ά\" case)")
  assert_eq(described_word("Έ"), "(name \"Έ\" case)")
  assert_eq(described_word("Ί"), "(name \"Ί\" case)")
  assert_eq(described_word("Ό"), "(name \"Ό\" case)")
  assert_eq(described_word("Ύ"), "(name \"Ύ\" case)")
  assert_eq(described_word("Ώ"), "(name \"Ώ\" case)")
  assert_eq(described_word("Α"), "(name \"Α\" case)")
  assert_eq(described_word("Ρ"), "(name \"Ρ\" case)")
  assert_eq(described_word("Σ"), "(name \"Σ\" case)")
  assert_eq(described_word("Ϋ"), "(name \"Ϋ\" case)")
  assert_eq(described_word("ά"), "(name \"ά\")")
  assert_eq(described_word("ψ"), "(name \"ψ\")")
  // Cyrillic.
  assert_eq(described_word("Ѐ"), "(name \"Ѐ\" case)")
  assert_eq(described_word("Я"), "(name \"Я\" case)")
  assert_eq(described_word("а"), "(name \"а\")")
  assert_eq(described_word("Ѡ"), "(name \"Ѡ\" case)")
  assert_eq(described_word("ѡ"), "(name \"ѡ\")")
  assert_eq(described_word("Ӏ"), "(name \"Ӏ\" case)")
  assert_eq(described_word("Ҋ"), "(name \"Ҋ\" case)")
  assert_eq(described_word("ҋ"), "(name \"ҋ\")")
  // Ӂ-ӎ pair in the reverse direction.
  assert_eq(described_word("Ӂ"), "(name \"Ӂ\" case)")
  assert_eq(described_word("ӂ"), "(name \"ӂ\")")
  assert_eq(described_word("Ӿ"), "(name \"Ӿ\" case)")
  assert_eq(described_word("ӿ"), "(name \"ӿ\")")
  assert_eq(described_word("Ԁ"), "(name \"Ԁ\" case)")
  assert_eq(described_word("ԁ"), "(name \"ԁ\")")
  // Fullwidth Latin capitals.
  assert_eq(described_word("Ａ"), "(name \"Ａ\" case)")
  assert_eq(described_word("Ｚ"), "(name \"Ｚ\" case)")
  assert_eq(described_word("ａ"), "(name \"ａ\")")
}

///|
test "explicit case modifiers override auto detection" {
  assert_eq(described_word("nocase:À"), "(name \"À\")")
  assert_eq(described_word("case:café"), "(name \"café\" case)")
  assert_eq(described_word("café"), "(name \"café\")")
}

///|
test "Latin Extended-A keeps every pairing direction" {
  // Even-run characters in the middle of the block.
  assert_eq(described_word("Ŋ"), "(name \"Ŋ\" case)")
  assert_eq(described_word("ŋ"), "(name \"ŋ\")")
  assert_eq(described_word("Ō"), "(name \"Ō\" case)")
  assert_eq(described_word("ō"), "(name \"ō\")")
  assert_eq(described_word("Ŷ"), "(name \"Ŷ\" case)")
  assert_eq(described_word("ŷ"), "(name \"ŷ\")")
  // Lowercase-only characters in the same block.
  assert_eq(described_word("ĸ"), "(name \"ĸ\")")
  assert_eq(described_word("ŉ"), "(name \"ŉ\")")
  assert_eq(described_word("Ÿ"), "(name \"Ÿ\" case)")
}
