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
test "regex exclude rules compile and match their explicit scope" {
  let basename = @index.ExcludeRule::parse(
    "regex:^drop\\.tmp$",
    scope=@index.Basename,
  )
  assert_eq(basename.pattern(), "^drop\\.tmp$")
  assert_true(basename.kind() is @index.Regex)
  assert_true(basename.matches(b"/r/drop.tmp", b"drop.tmp", false))
  assert_false(basename.matches(b"/r/keep.tmp", b"keep.tmp", false))
  let full_path = @index.ExcludeRule::parse("regex:^/r/cache")
  assert_true(full_path.matches(b"/r/cache/item", b"item", false))
  assert_false(full_path.matches(b"/other/cache/item", b"item", false))
}

///|
test "invalid regex excludes use the query error model" {
  let err = try @index.ExcludeRule::parse("regex:[") catch {
    err => err
  } noraise {
    _ => abort("expected an invalid regex error")
  }
  match err {
    @query.BadRegex(pattern) => assert_eq(pattern, "[")
    _ => abort("expected BadRegex")
  }
  assert_true(err.message().contains("invalid regular expression '['"))
}

///|
test "regex excludes are case-sensitive and unanchored" {
  let sensitive = @index.ExcludeRule::parse("regex:drop", scope=@index.Basename)
  assert_true(sensitive.matches(b"/r/drop.tmp", b"drop.tmp", false))
  assert_false(sensitive.matches(b"/r/DROP.tmp", b"DROP.tmp", false))
  let folded = @index.ExcludeRule::parse(
    "regex:(?i:drop)",
    scope=@index.Basename,
  )
  assert_true(folded.matches(b"/r/DROP.tmp", b"DROP.tmp", false))
}

///|
test "regex excludes do not match invalid UTF-8 subjects" {
  let rule = @index.ExcludeRule::parse("regex:.*", scope=@index.Basename)
  assert_true(rule.matches(b"/r/valid", b"valid", false))
  assert_false(rule.matches(b"/r/bad-\xff", b"bad-\xff", false))
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
test "inactive regex rules never match but are still validated" {
  let rule = @index.ExcludeRule::new(
    kind=@index.Regex,
    pattern=".*",
    scope=@index.FullPath,
    active=false,
  )
  assert_false(rule.matches(b"/r/anything", b"anything", false))
  let err = try
    @index.ExcludeRule::new(kind=@index.Regex, pattern="[", active=false)
  catch {
    err => err
  } noraise {
    _ => abort("expected an invalid regex error")
  }
  assert_true(err.message().contains("invalid regular expression"))
}

///|
test "every exclude kind scope and target combination is enforced" {
  for kind in [@index.Fixed, @index.Glob, @index.Regex] {
    for scope in [@index.FullPath, @index.Basename] {
      for target in [@index.Both, @index.Files, @index.Folders] {
        let pattern = match (kind, scope) {
          (@index.Fixed, @index.FullPath) => "/r/drop.tmp"
          (@index.Fixed, @index.Basename) => "drop.tmp"
          (@index.Glob, @index.FullPath) => "/r/*.tmp"
          (@index.Glob, @index.Basename) => "*.tmp"
          (@index.Regex, @index.FullPath) => "^/r/.*\\.tmp$"
          (@index.Regex, @index.Basename) => "^drop\\.tmp$"
        }
        let rule = @index.ExcludeRule::new(kind~, pattern~, scope~, target~)
        assert_eq(
          rule.matches(b"/r/drop.tmp", b"drop.tmp", false),
          target is @index.Both || target is @index.Files,
        )
        assert_eq(
          rule.matches(b"/r/drop.tmp", b"drop.tmp", true),
          target is @index.Both || target is @index.Folders,
        )
        assert_false(rule.matches(b"/r/keep.txt", b"keep.txt", false))
        assert_false(rule.matches(b"/r/keep.txt", b"keep.txt", true))
      }
    }
  }
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
