///|
/// A tree with files, folders, an empty folder, a hidden file, mixed case, and
/// timestamps in several months:
///
/// ```text
/// /root
///   docs/            report.pdf (1000 B, 2024-03-15), notes.txt (500 B, 2024-02-01)
///   media/           photo.JPG (2000 B, 2024-01-10)
///   archive/         empty
///   readme.md        (100 B, 2024-03-01)
///   .hidden          (50 B, 2024-03-20)
/// ```
fn test_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 1672531200L)
  let docs = builder.add_folder(root, "docs", 1709251200L)
  ignore(builder.add_file(docs, "report.pdf", 1000L, 1710460800L))
  ignore(builder.add_file(docs, "notes.txt", 500L, 1706745600L))
  builder.set_child_counts(docs, 2U, 0U)
  builder.add_folder_size(docs, 1500L)
  let media = builder.add_folder(root, "media", 1704844800L)
  ignore(builder.add_file(media, "photo.JPG", 2000L, 1704844800L))
  builder.set_child_counts(media, 1U, 0U)
  builder.add_folder_size(media, 2000L)
  let archive = builder.add_folder(root, "archive", 1709510400L)
  builder.set_child_counts(archive, 0U, 0U)
  ignore(builder.add_file(root, "readme.md", 100L, 1709251200L))
  ignore(
    builder.add_file(
      root,
      ".hidden",
      50L,
      1710892800L,
      flags=@core.ENTRY_FLAG_HIDDEN,
    ),
  )
  builder.set_child_counts(root, 2U, 3U)
  builder.add_folder_size(root, 3650L)
  builder.set_root_stats(0, 4U, 3U, 3650L)
  builder.finish(built_at=0L)
}

///|
/// Fixed clock for date queries: 2024-03-20 00:00:00 UTC.
const TEST_NOW : Int64 = 1710892800L

///|
/// Parse a query or abort the test.
fn query_of(text : String) -> @query.Query {
  @query.parse(text) catch {
    err => abort("query '\{text}' failed: \{err.message()}")
  }
}

///|
/// Run one query against the fixture and return full paths in scan order.
fn matched(
  text : String,
  now~ : Int64 = TEST_NOW,
  limit~ : Int32 = 0,
) -> Array[String] {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let query = query_of(text)
  let options = @exec.ScanOptions::new(
    limit~,
    now=Some(now),
    zone=Some(@time.utc_zone),
  )
  let hits = @exec.exec_scan_with(store, query, options~) catch {
    err => abort("query '\{text}' failed at execution: \{err.message()}")
  }
  hits.map(fn(entry) { @utf8.decode_lossy(store.entry_path(entry)) })
}

///|
test "name matching is case-insensitive substring by default" {
  assert_eq(matched("report"), ["/root/docs/report.pdf"])
  assert_eq(matched("REPORT"), ["/root/docs/report.pdf"])
  assert_eq(matched("jpg"), ["/root/media/photo.JPG"])
  assert_eq(matched("root"), ["/root"])
  assert_eq(matched("nothing-here"), [])
}

///|
test "case: and exact: narrow name matching" {
  assert_eq(matched("case:REPORT"), [])
  assert_eq(matched("case:report"), ["/root/docs/report.pdf"])
  assert_eq(matched("exact:readme.md"), ["/root/readme.md"])
  assert_eq(matched("exact:readme"), [])
  assert_eq(matched("exact:README.MD"), ["/root/readme.md"])
  assert_eq(matched("case:exact:README.MD"), [])
}

///|
test "glob patterns replace substring matching" {
  assert_eq(matched("*.pdf"), ["/root/docs/report.pdf"])
  assert_eq(matched("*.PDF"), ["/root/docs/report.pdf"])
  assert_eq(matched("?hidden"), ["/root/.hidden"])
  assert_eq(matched("photo*"), ["/root/media/photo.JPG"])
  assert_eq(matched("*.md"), ["/root/readme.md"])
}

///|
test "regular expressions match the name" {
  assert_eq(matched("regex:\"^photo\""), ["/root/media/photo.JPG"])
  assert_eq(matched("regex:\"\\.pdf$\""), ["/root/docs/report.pdf"])
  assert_eq(matched("regex:\"^REPORT\""), ["/root/docs/report.pdf"])
  assert_eq(matched("regex:\"^report\""), ["/root/docs/report.pdf"])
  assert_eq(matched("case:regex:\"^REPORT\""), [])
  // `path:` makes the regex run against the full path.
  assert_eq(matched("path:regex:\"docs/.*\\.pdf$\""), ["/root/docs/report.pdf"])
}

///|
test "ext: matches files by extension" {
  assert_eq(matched("ext:pdf"), ["/root/docs/report.pdf"])
  assert_eq(matched("ext:JPG"), ["/root/media/photo.JPG"])
  assert_eq(matched("ext:txt;md"), ["/root/docs/notes.txt", "/root/readme.md"])
  // An empty extension selects files without one.
  assert_eq(matched("ext:"), ["/root/.hidden"])
  // Folders never match ext:.
  assert_eq(matched("folder:ext:pdf"), [])
}

///|
test "size: compares bytes over files and folders" {
  assert_eq(matched("size:>1500"), [
    "/root", "/root/media", "/root/media/photo.JPG",
  ])
  assert_eq(matched("size:..100"), ["/root/.hidden", "/root/archive"])
  assert_eq(matched("size:1kb..2kb"), ["/root/docs", "/root/docs/report.pdf"])
  assert_eq(matched("file:size:2000"), ["/root/media/photo.JPG"])
}

///|
test "depth: counts folder hops from the root" {
  assert_eq(matched("depth:0"), ["/root"])
  assert_eq(matched("depth:1"), [
    "/root/.hidden", "/root/archive", "/root/docs", "/root/media", "/root/readme.md",
  ])
  assert_eq(matched("depth:2"), [
    "/root/docs/notes.txt", "/root/media/photo.JPG", "/root/docs/report.pdf",
  ])
  assert_eq(matched("depth:>2"), [])
}

///|
test "child counts and empty: apply to folders only" {
  assert_eq(matched("childcount:0"), ["/root/archive"])
  assert_eq(matched("childcount:>0"), ["/root", "/root/docs", "/root/media"])
  assert_eq(matched("empty:"), ["/root/archive"])
  assert_eq(matched("childfilecount:2"), ["/root", "/root/docs"])
  assert_eq(matched("childfoldercount:3"), ["/root"])
}

///|
test "parent: matches the exact parent path" {
  assert_eq(matched("parent:/root/docs"), [
    "/root/docs/notes.txt", "/root/docs/report.pdf",
  ])
  assert_eq(matched("parent:/root/"), [
    "/root/.hidden", "/root/archive", "/root/docs", "/root/media", "/root/readme.md",
  ])
  assert_eq(matched("parent:/"), [])
}

///|
test "contenttype: maps extensions to MIME types" {
  assert_eq(matched("contenttype:pdf"), ["/root/docs/report.pdf"])
  assert_eq(matched("contenttype:image"), ["/root/media/photo.JPG"])
  assert_eq(matched("contenttype:text"), [
    "/root/docs/notes.txt", "/root/readme.md",
  ])
  assert_eq(matched("contenttype:application/pdf"), ["/root/docs/report.pdf"])
}

///|
test "dm: compares modification time against calendar units" {
  assert_eq(matched("dm:2024-03"), [
    "/root/.hidden", "/root/archive", "/root/docs", "/root/readme.md", "/root/docs/report.pdf",
  ])
  assert_eq(matched("dm:2024-02"), ["/root/docs/notes.txt"])
  assert_eq(matched("dm:2024").length(), 8)
  assert_eq(matched("dm:2025"), [])
  assert_eq(matched("dm:>=2024-03-01"), [
    "/root/.hidden", "/root/archive", "/root/docs", "/root/readme.md", "/root/docs/report.pdf",
  ])
  assert_eq(matched("dm:<2024-02-01"), [
    "/root", "/root/media", "/root/media/photo.JPG",
  ])
}

///|
test "boolean operators combine sets" {
  assert_eq(matched("pdf OR txt"), [
    "/root/docs/notes.txt", "/root/docs/report.pdf",
  ])
  assert_eq(matched("ext:pdf ext:txt"), [])
  assert_eq(matched("!pdf"), [
    "/root", "/root/.hidden", "/root/archive", "/root/docs", "/root/media", "/root/docs/notes.txt",
    "/root/media/photo.JPG", "/root/readme.md",
  ])
  assert_eq(matched("(pdf OR txt) !draft"), [
    "/root/docs/notes.txt", "/root/docs/report.pdf",
  ])
}

///|
test "path: searches the full path" {
  assert_eq(matched("path:docs"), [
    "/root/docs", "/root/docs/notes.txt", "/root/docs/report.pdf",
  ])
  // A needle containing `/` switches to path search automatically.
  assert_eq(matched("/root/media"), ["/root/media", "/root/media/photo.JPG"])
  assert_eq(matched("media"), ["/root/media"])
}

///|
test "kind filters restrict the result kind" {
  assert_eq(matched("folder:"), [
    "/root", "/root/archive", "/root/docs", "/root/media",
  ])
  assert_eq(matched("file:"), [
    "/root/.hidden", "/root/docs/notes.txt", "/root/media/photo.JPG", "/root/readme.md",
    "/root/docs/report.pdf",
  ])
  assert_eq(matched("folder:docs"), ["/root/docs"])
  assert_eq(matched("folder:report"), [])
}

///|
test "the empty query matches every entry and limits are streaming" {
  assert_eq(matched("").length(), 9)
  assert_eq(matched("", limit=2), ["/root", "/root/.hidden"])
  assert_eq(matched("", limit=1), ["/root"])
}

///|
test "exec_count agrees with the number of hits" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let options = @exec.ScanOptions::new(
    now=Some(TEST_NOW),
    zone=Some(@time.utc_zone),
  )
  for text in ["", "ext:pdf", "!pdf", "size:>1500", "dm:2024-02"] {
    let query = query_of(text)
    let count = @exec.exec_count_with(store, query, options~) catch {
      err => abort("count '\{text}' failed: \{err.message()}")
    }
    assert_eq(count, matched(text).length())
  }
}

///|
test "explain renders the compiled plan" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  ignore(store)
  let query = query_of("ext:pdf size:>1kb")
  let plan = @exec.explain_query(
    query,
    options=@exec.ScanOptions::new(
      now=Some(TEST_NOW),
      zone=Some(@time.utc_zone),
    ),
  ) catch {
    err => abort("explain failed: \{err.message()}")
  }
  assert_eq(plan, "(and (ext \"pdf\") (size > 1000))")
}

///|
test "invalid regex and date values raise query errors" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let bad_regex = query_of("regex:\"[\"")
  let regex_error = Ok(@exec.exec_scan(store, bad_regex)) catch {
    err => Err(err)
  }
  match regex_error {
    Err(err) =>
      assert_true(err.message().contains("invalid regular expression"))
    Ok(_) => abort("expected the regex to be rejected")
  }
  let bad_date = query_of("dm:nonsense")
  let date_error = Ok(@exec.exec_scan(store, bad_date)) catch {
    err => Err(err)
  }
  match date_error {
    Err(err) => assert_true(err.message().contains("expected a date"))
    Ok(_) => abort("expected the date to be rejected")
  }
}

///|
test "compat error recovery compiles to an empty set" {
  let store = test_store() catch {
    err => abort("fixture failed: \{err.message()}")
  }
  let query = @query.parse("unknown:x", compat=true) catch {
    err => abort("compat parse failed: \{err.message()}")
  }
  let count = @exec.exec_count(store, query) catch {
    err => abort("count failed: \{err.message()}")
  }
  assert_eq(count, 0)
}
