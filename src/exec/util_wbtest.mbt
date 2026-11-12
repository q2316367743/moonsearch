///|
test "extension extraction handles multi-dot, hidden, and trailing dots" {
  assert_eq(@util.extension_of(b"a.txt"[:]), b"txt"[:])
  assert_eq(@util.extension_of(b"archive.tar.gz"[:]), b"gz"[:])
  assert_eq(@util.extension_of(b"UPPER.PDF"[:]), b"PDF"[:])
  // A hidden file has no extension even if it contains a dot.
  assert_eq(@util.extension_of(b".bashrc"[:]), b""[:])
  assert_eq(@util.extension_of(b".config.json"[:]), b""[:])
  // A trailing dot does not start an extension.
  assert_eq(@util.extension_of(b"trailing."[0:9]), b""[:])
  assert_eq(@util.extension_of(b"noext"[0:5]), b""[:])
  assert_eq(@util.extension_of(b""[0:0]), b""[:])
}

///|
test "content type table is lowercase and has a fallback" {
  assert_eq(mime_of_extension(b"pdf"[:]), "application/pdf")
  assert_eq(mime_of_extension(b"JPG"[:]), "image/jpeg")
  assert_eq(mime_of_extension(b"md"[:]), "text/plain")
  assert_eq(mime_of_extension(b"unknown"[:]), "application/octet-stream")
  assert_eq(mime_of_extension(b""[0:0]), "application/octet-stream")
}

///|
test "parent paths drop trailing slashes but keep the root" {
  assert_eq(normalize_parent("/a/b/"), b"/a/b")
  assert_eq(normalize_parent("/a/b///"), b"/a/b")
  assert_eq(normalize_parent("/"), b"/")
  assert_eq(normalize_parent("///"), b"/")
  assert_eq(normalize_parent("relative"), b"relative")
}
