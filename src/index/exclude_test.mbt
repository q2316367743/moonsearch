///|
test "an unprefixed exclude pattern is a glob" {
  let rule = @index.ExcludeRule::parse("*.tmp", scope=@index.Basename)
  assert_true(rule.matches("/r/drop.tmp", "drop.tmp", false))
  assert_false(rule.matches("/r/keep.txt", "keep.txt", false))
}

///|
test "exclude prefixes select the matcher" {
  let fixed = @index.ExcludeRule::parse("fixed:*.tmp", scope=@index.Basename)
  // A fixed pattern treats the wildcard as a literal character.
  assert_false(fixed.matches("/r/drop.tmp", "drop.tmp", false))
  assert_true(fixed.matches("/r/*.tmp", "*.tmp", false))
  let glob = @index.ExcludeRule::parse("glob:build*", scope=@index.Basename)
  assert_true(glob.matches("/r/build", "build", true))
  assert_true(glob.matches("/r/build-cache", "build-cache", true))
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
  assert_false(rule.matches("/r/build", "build", true))
}

///|
test "target restricts a rule to one entry kind" {
  let folders = @index.ExcludeRule::new(
    kind=@index.Fixed,
    pattern="/r/node_modules",
    scope=@index.FullPath,
    target=@index.Folders,
  )
  assert_true(folders.matches("/r/node_modules", "node_modules", true))
  assert_false(folders.matches("/r/node_modules", "node_modules", false))
  let files = @index.ExcludeRule::new(
    kind=@index.Glob,
    pattern="*.log",
    scope=@index.Basename,
    target=@index.Files,
  )
  assert_true(files.matches("/r/a.log", "a.log", false))
  assert_false(files.matches("/r/a.log", "a.log", true))
}

///|
test "the full-path scope matches the whole path only" {
  let rule = @index.ExcludeRule::new(
    kind=@index.Glob,
    pattern="*/cache/*",
    scope=@index.FullPath,
  )
  assert_true(rule.matches("/r/cache/x", "x", false))
  assert_false(rule.matches("/r/notcache/x", "x", false))
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
  assert_true(rule.matches("/r/exact", "exact", true))
  assert_false(rule.matches("/r/exact/child", "child", false))
  assert_false(rule.matches("/r/exact2", "exact2", true))
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
  assert_false(rule.matches("/r/anything", "anything", false))
}

///|
test "rules match non-ASCII names byte for byte" {
  let fixed = @index.ExcludeRule::new(
    kind=@index.Fixed,
    pattern="发票.pdf",
    scope=@index.Basename,
  )
  assert_true(fixed.matches("/r/发票.pdf", "发票.pdf", false))
  assert_false(fixed.matches("/r/发票.txt", "发票.txt", false))
  let glob = @index.ExcludeRule::new(
    kind=@index.Glob,
    pattern="*.pdf",
    scope=@index.Basename,
  )
  assert_true(glob.matches("/r/发票.pdf", "发票.pdf", false))
}

///|
test "only lowercase prefixes select a matcher" {
  // `FIXED:` is not a recognized prefix, so it stays a literal glob pattern.
  let rule = @index.ExcludeRule::parse("FIXED:name", scope=@index.Basename)
  assert_true(rule.kind() is @index.Glob)
  assert_eq(rule.pattern(), "FIXED:name")
  assert_false(rule.matches("/r/name", "name", false))
}
