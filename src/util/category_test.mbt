///|
/// Uppercase ASCII letters, leaving everything else alone.
fn ascii_upper_string(text : String) -> String {
  let chars : Array[Char] = []
  for char in text.iter() {
    chars.push(char.to_ascii_uppercase())
  }
  String::from_array(chars)
}

///|
/// Assert that a name resolves to the expected category.
fn assert_parsed_category(
  parsed : @util.TypeCategory?,
  expected : @util.TypeCategory,
) -> Unit raise {
  match parsed {
    Some(category) => assert_eq(category.index(), expected.index())
    None => abort("'{expected.name()}' did not resolve to a category")
  }
}

///|
test "category names round-trip and parse case-insensitively" {
  let names : Array[String] = []
  for category in @util.TypeCategory::all() {
    let name = category.name()
    names.push(name)
    assert_parsed_category(@util.TypeCategory::from_name(name), category)
    assert_parsed_category(
      @util.TypeCategory::from_name(ascii_upper_string(name)),
      category,
    )
  }
  names.sort()
  for index in 1..<names.length() {
    assert_true(names[index - 1] != names[index])
  }
  match @util.TypeCategory::from_name("nope") {
    None => ()
    Some(_) => abort("'nope' must not resolve")
  }
  match @util.TypeCategory::from_name("") {
    None => ()
    Some(_) => abort("an empty name must not resolve")
  }
}

///|
test "category indices cover a dense range in macro order" {
  let categories = @util.TypeCategory::all()
  assert_eq(categories.length(), 6)
  for index in 0..<categories.length() {
    assert_eq(categories[index].index(), index)
  }
  assert_eq(@util.TypeCategory::from_name("app").unwrap().index(), 0)
  assert_eq(@util.TypeCategory::from_name("video").unwrap().index(), 5)
}

///|
test "category extension lists are lowercase, dot-free, and unique" {
  for category in @util.TypeCategory::all() {
    let extensions = category.extensions()
    assert_true(extensions.length() > 0)
    let seen : Map[String, Bool] = Map([])
    for extension in extensions {
      assert_true(extension.length() > 0)
      assert_false(extension.contains_char('.'))
      for char in extension.iter() {
        assert_eq(char.to_ascii_lowercase(), char)
      }
      match seen.get(extension) {
        Some(_) => abort("category \{category.name()} repeats '\{extension}'")
        None => seen.set(extension, true)
      }
    }
  }
}

///|
test "the common formats land in the expected categories" {
  let pic = @util.TypeCategory::Pic.extensions()
  let archive = @util.TypeCategory::Archive.extensions()
  let doc = @util.TypeCategory::Doc.extensions()
  assert_true(pic.contains("jpg"))
  assert_true(pic.contains("png"))
  assert_true(archive.contains("zip"))
  assert_true(archive.contains("tar"))
  assert_true(doc.contains("pdf"))
  assert_true(doc.contains("mbt"))
  assert_false(pic.contains("pdf"))
}
