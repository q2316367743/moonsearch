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
