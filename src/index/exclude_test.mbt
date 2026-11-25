///|
test "an unprefixed exclude pattern is a glob" {
  let rule = @index.ExcludeRule::parse("*.tmp", scope=@index.Basename)
  assert_true(rule.matches(b"/r/drop.tmp", b"drop.tmp", false))
  assert_false(rule.matches(b"/r/keep.txt", b"keep.txt", false))
}

///|
test "exclude prefixes select the matcher" {
  let fixed = @index.ExcludeRule::parse("fixed:*.tmp", scope=@index.Basename)
  // A fixed pattern treats the wildcard as a literal character.
  assert_false(fixed.matches(b"/r/drop.tmp", b"drop.tmp", false))
  assert_true(fixed.matches(b"/r/*.tmp", b"*.tmp", false))
  let glob = @index.ExcludeRule::parse("glob:build*", scope=@index.Basename)
  assert_true(glob.matches(b"/r/build", b"build", true))
  assert_true(glob.matches(b"/r/build-cache", b"build-cache", true))
}

///|
test "regex exclude rules are reported as unsupported" {
  let err = try @index.ExcludeRule::parse("regex:^tmp") catch {
    err => err
  } noraise {
    _ => abort("expected an UnsupportedExclude error")
  }
  match err {
    @index.UnsupportedExclude(message) => assert_true(message.contains("regex"))
    _ => abort("expected an UnsupportedExclude error")
  }
}

///|
test "inactive rules never match" {
  let rule = @index.ExcludeRule::new(
    kind=@index.Fixed,
    pattern="build",
    active=false,
  )
  assert_false(rule.matches(b"/r/build", b"build", true))
}

///|
test "target restricts a rule to one entry kind" {
  let folders = @index.ExcludeRule::new(
    kind=@index.Fixed,
    pattern="/r/node_modules",
    scope=@index.FullPath,
    target=@index.Folders,
  )
  assert_true(folders.matches(b"/r/node_modules", b"node_modules", true))
  assert_false(folders.matches(b"/r/node_modules", b"node_modules", false))
  let files = @index.ExcludeRule::new(
    kind=@index.Glob,
    pattern="*.log",
    scope=@index.Basename,
    target=@index.Files,
  )
  assert_true(files.matches(b"/r/a.log", b"a.log", false))
  assert_false(files.matches(b"/r/a.log", b"a.log", true))
}

///|
test "the full-path scope matches the whole path only" {
  let rule = @index.ExcludeRule::new(
    kind=@index.Glob,
    pattern="*/cache/*",
    scope=@index.FullPath,
  )
  assert_true(rule.matches(b"/r/cache/x", b"x", false))
  assert_false(rule.matches(b"/r/notcache/x", b"x", false))
}

///|
test "rules expose their configuration" {
  let rule = @index.ExcludeRule::parse(
    "glob:*.tmp",
    scope=@index.Basename,
    target=@index.Files,
  )
  assert_eq(rule.pattern(), "*.tmp")
  assert_true(rule.kind() is @index.Glob)
  assert_true(rule.scope() is @index.Basename)
  assert_true(rule.target() is @index.Files)
  assert_true(rule.is_active())
}

///|
test "a fixed rule compares the whole subject exactly" {
  let rule = @index.ExcludeRule::new(
    kind=@index.Fixed,
    pattern="/r/exact",
    scope=@index.FullPath,
  )
  assert_true(rule.matches(b"/r/exact", b"exact", true))
  assert_false(rule.matches(b"/r/exact/child", b"child", false))
  assert_false(rule.matches(b"/r/exact2", b"exact2", true))
}

///|
test "a regex rule is inert until the regex engine arrives" {
  let rule = @index.ExcludeRule::new(
    kind=@index.Regex,
    pattern=".*",
    scope=@index.FullPath,
  )
  // The rule model accepts Regex, but matching deliberately ignores it; the
  // CLI rejects `regex:` specifications instead.
  assert_false(rule.matches(b"/r/anything", b"anything", false))
}

///|
test "rules match non-ASCII names byte for byte" {
  let fixed = @index.ExcludeRule::new(
    kind=@index.Fixed,
    pattern="发票.pdf",
    scope=@index.Basename,
  )
  assert_true(fixed.matches(b"/r/发票.pdf", b"发票.pdf", false))
  assert_false(fixed.matches(b"/r/发票.txt", b"发票.txt", false))
  let glob = @index.ExcludeRule::new(
    kind=@index.Glob,
    pattern="*.pdf",
    scope=@index.Basename,
  )
  assert_true(glob.matches(b"/r/发票.pdf", b"发票.pdf", false))
}

///|
test "only lowercase prefixes select a matcher" {
  // `FIXED:` is not a recognized prefix, so it stays a literal glob pattern.
  let rule = @index.ExcludeRule::parse("FIXED:name", scope=@index.Basename)
  assert_true(rule.kind() is @index.Glob)
  assert_eq(rule.pattern(), "FIXED:name")
  assert_false(rule.matches(b"/r/name", b"name", false))
}
