///|
/// Fixture with mixed folders, extensions, sizes, and timestamps:
///
/// ```text
/// /root           3650 B, t=100
///   docs/         1500 B, t=300
///     report.pdf  1000 B, t=600
///     notes.txt    500 B, t=400
///   media/        2000 B, t=200
///     photo.JPG   2000 B, t=500
///   archive/         0 B, t=700
///   readme.md      100 B, t=800
///   .hidden         50 B, t=900
///   zzz            300 B, t=1000
/// ```
fn order_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 100L)
  let docs = builder.add_folder(root, "docs", 300L)
  ignore(builder.add_file(docs, "report.pdf", 1000L, 600L))
  ignore(builder.add_file(docs, "notes.txt", 500L, 400L))
  builder.add_folder_size(docs, 1500L)
  let media = builder.add_folder(root, "media", 200L)
  ignore(builder.add_file(media, "photo.JPG", 2000L, 500L))
  builder.add_folder_size(media, 2000L)
  ignore(builder.add_folder(root, "archive", 700L))
  ignore(builder.add_file(root, "readme.md", 100L, 800L))
  ignore(
    builder.add_file(root, ".hidden", 50L, 900L, flags=@core.ENTRY_FLAG_HIDDEN),
  )
  ignore(builder.add_file(root, "zzz", 300L, 1000L))
  builder.add_folder_size(root, 3650L)
  builder.finish(built_at=0L)
}

///|
/// Two names whose canonical order differs from their path order:
/// `alpha` is the folder, `alpha.txt` the sibling file.
fn path_order_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 0L)
  let alpha = builder.add_folder(root, "alpha", 0L)
  ignore(builder.add_file(alpha, "zeta.txt", 10L, 0L))
  ignore(builder.add_file(root, "alpha.txt", 20L, 0L))
  builder.finish(built_at=0L)
}

///|
/// 200 files with sizes and timestamps that do not follow name order.
fn large_order_store() -> @core.Store raise @index.IndexError {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 0L)
  for index in 0..<200 {
    let size = (index * 73 % 200).to_int64()
    let mtime = (index * 31 % 200).to_int64()
    ignore(builder.add_file(root, "file\{index}.txt", size, mtime))
  }
  builder.finish(built_at=0L)
}

///|
/// Every entry in canonical order, which is what both engines produce.
fn all_order_hits(store : @core.Store) -> Array[@core.EntryRef] {
  let hits : Array[@core.EntryRef] = []
  for entry in store.entries_in_order() {
    hits.push(entry)
  }
  hits
}

///|
/// Paths of a hit array, for readable assertions.
fn order_paths(
  store : @core.Store,
  hits : Array[@core.EntryRef],
) -> Array[String] {
  hits.map(fn(entry) { @utf8.decode_lossy(store.entry_path(entry)) })
}

///|
/// Ordered paths for one sort option set.
fn sorted_paths(
  store : @core.Store,
  options : @exec.OrderOptions,
) -> Array[String] {
  order_paths(store, @exec.order_hits(store, all_order_hits(store), options))
}

///|
test "default order is the canonical name order" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new()), [
    "/root", "/root/.hidden", "/root/archive", "/root/docs", "/root/media", "/root/docs/notes.txt",
    "/root/media/photo.JPG", "/root/readme.md", "/root/docs/report.pdf", "/root/zzz",
  ])
}

///|
test "path order reorders siblings before nested entries" {
  let store = path_order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Path)), [
    "/root", "/root/alpha", "/root/alpha/zeta.txt", "/root/alpha.txt",
  ])
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Name)), [
    "/root", "/root/alpha", "/root/alpha.txt", "/root/alpha/zeta.txt",
  ])
}

///|
test "size order is ascending with canonical tie-breaks" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Size)), [
    "/root/archive", "/root/.hidden", "/root/readme.md", "/root/zzz", "/root/docs/notes.txt",
    "/root/docs/report.pdf", "/root/docs", "/root/media", "/root/media/photo.JPG",
    "/root",
  ])
}

///|
test "mtime order is ascending" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.MTime)), [
    "/root", "/root/media", "/root/docs", "/root/docs/notes.txt", "/root/media/photo.JPG",
    "/root/docs/report.pdf", "/root/archive", "/root/readme.md", "/root/.hidden",
    "/root/zzz",
  ])
}

///|
test "extension order folds case and puts empty extensions first" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Ext)), [
    "/root", "/root/.hidden", "/root/archive", "/root/docs", "/root/media", "/root/zzz",
    "/root/media/photo.JPG", "/root/readme.md", "/root/docs/report.pdf", "/root/docs/notes.txt",
  ])
}

///|
test "type order groups folders, categories, then unknown files" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Type)), [
    "/root", "/root/archive", "/root/docs", "/root/media", "/root/readme.md", "/root/docs/report.pdf",
    "/root/docs/notes.txt", "/root/media/photo.JPG", "/root/.hidden", "/root/zzz",
  ])
}

///|
test "reverse reverses the whole order, including tie-breaks" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(reverse=true)), [
    "/root/zzz", "/root/docs/report.pdf", "/root/readme.md", "/root/media/photo.JPG",
    "/root/docs/notes.txt", "/root/media", "/root/docs", "/root/archive", "/root/.hidden",
    "/root",
  ])
  assert_eq(
    sorted_paths(store, @exec.OrderOptions::new(key=@exec.Size, reverse=true)),
    [
      "/root", "/root/media/photo.JPG", "/root/media", "/root/docs", "/root/docs/report.pdf",
      "/root/docs/notes.txt", "/root/zzz", "/root/readme.md", "/root/.hidden", "/root/archive",
    ],
  )
}

///|
test "folders-first groups without changing the order inside a group" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(folders_first=true)), [
    "/root", "/root/archive", "/root/docs", "/root/media", "/root/.hidden", "/root/docs/notes.txt",
    "/root/media/photo.JPG", "/root/readme.md", "/root/docs/report.pdf", "/root/zzz",
  ])
  assert_eq(
    sorted_paths(
      store,
      @exec.OrderOptions::new(key=@exec.Size, folders_first=true),
    ),
    [
      "/root/archive", "/root/docs", "/root/media", "/root", "/root/.hidden", "/root/readme.md",
      "/root/zzz", "/root/docs/notes.txt", "/root/docs/report.pdf", "/root/media/photo.JPG",
    ],
  )
}

///|
test "folders-first combines with reverse and limit inside each group" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(
    sorted_paths(store, @exec.OrderOptions::new(folders_first=true, limit=2)),
    ["/root", "/root/archive"],
  )
  assert_eq(
    sorted_paths(
      store,
      @exec.OrderOptions::new(reverse=true, folders_first=true, limit=2),
    ),
    ["/root/media", "/root/docs"],
  )
  assert_eq(
    sorted_paths(
      store,
      @exec.OrderOptions::new(reverse=true, folders_first=true, limit=6),
    ),
    [
      "/root/media", "/root/docs", "/root/archive", "/root", "/root/zzz", "/root/docs/report.pdf",
    ],
  )
}

///|
test "limit applies after ordering, not before" {
  let store = order_store() catch { err => abort(err.message()) }
  assert_eq(
    sorted_paths(store, @exec.OrderOptions::new(key=@exec.Size, limit=4)),
    ["/root/archive", "/root/.hidden", "/root/readme.md", "/root/zzz"],
  )
  // Plain name order is already canonical and only truncates.
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(limit=3)), [
    "/root", "/root/.hidden", "/root/archive",
  ])
  // A limit larger than the match set keeps everything.
  assert_eq(
    sorted_paths(store, @exec.OrderOptions::new(key=@exec.Size, limit=100)).length(),
    10,
  )
}

///|
test "top-K selection matches a full sort for every key" {
  let store = large_order_store() catch { err => abort(err.message()) }
  let hits = all_order_hits(store)
  for key in [@exec.Name, @exec.Size, @exec.MTime, @exec.Ext, @exec.Type] {
    for reverse in [false, true] {
      for limit in [1, 17, 199] {
        let full = order_paths(
          store,
          @exec.order_hits(
            store,
            hits,
            @exec.OrderOptions::new(key~, reverse~, limit=0),
          ),
        )
        let limited = order_paths(
          store,
          @exec.order_hits(
            store,
            hits,
            @exec.OrderOptions::new(key~, reverse~, limit~),
          ),
        )
        assert_eq(limited.length(), limit)
        let mut index = 0
        while index < limit {
          assert_eq(limited[index], full[index])
          index = index + 1
        }
      }
    }
  }
}

///|
test "sorting is independent of the input order" {
  let store = large_order_store() catch { err => abort(err.message()) }
  let canonical = all_order_hits(store)
  let shuffled : Array[@core.EntryRef] = []
  let mut index = canonical.length() - 1
  while index >= 0 {
    shuffled.push(canonical[index])
    index = index - 1
  }
  for key in [@exec.Path, @exec.Size, @exec.MTime, @exec.Ext, @exec.Type] {
    let from_canonical = order_paths(
      store,
      @exec.order_hits(store, canonical, @exec.OrderOptions::new(key~)),
    )
    let from_shuffled = order_paths(
      store,
      @exec.order_hits(store, shuffled, @exec.OrderOptions::new(key~)),
    )
    assert_eq(from_canonical, from_shuffled)
  }
}

///|
test "equal names fall back to path order" {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 0L)
  let a = builder.add_folder(root, "a", 0L)
  let b = builder.add_folder(root, "b", 0L)
  ignore(builder.add_file(b, "x.txt", 1L, 0L))
  ignore(builder.add_file(a, "x.txt", 1L, 0L))
  let store = builder.finish(built_at=0L)
  assert_eq(sorted_paths(store, @exec.OrderOptions::new()), [
    "/root", "/root/a", "/root/b", "/root/a/x.txt", "/root/b/x.txt",
  ])
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Path)), [
    "/root", "/root/a", "/root/a/x.txt", "/root/b", "/root/b/x.txt",
  ])
}

///|
test "extension order is lexicographic and case-folded" {
  let builder = @index.Builder::new()
  let root = builder.add_root("/root", false, 0L)
  ignore(builder.add_file(root, "one.a", 1L, 0L))
  ignore(builder.add_file(root, "two.ab", 1L, 0L))
  ignore(builder.add_file(root, "three.B", 1L, 0L))
  let store = builder.finish(built_at=0L)
  assert_eq(sorted_paths(store, @exec.OrderOptions::new(key=@exec.Ext)), [
    "/root", "/root/one.a", "/root/two.ab", "/root/three.B",
  ])
}

///|
test "sort keys parse case-insensitively" {
  assert_true(@exec.SortKey::from_name("name") is Some(@exec.Name))
  assert_true(@exec.SortKey::from_name("SIZE") is Some(@exec.Size))
  assert_true(@exec.SortKey::from_name("MTime") is Some(@exec.MTime))
  assert_true(@exec.SortKey::from_name("ext") is Some(@exec.Ext))
  assert_true(@exec.SortKey::from_name("bogus") is None)
}

///|
test "name order streams forward and backward, grouping needs collection" {
  assert_true(@exec.OrderOptions::new().streams_name_order())
  assert_true(@exec.OrderOptions::new(reverse=true).streams_name_order())
  assert_false(@exec.OrderOptions::new(folders_first=true).streams_name_order())
  assert_false(@exec.OrderOptions::new(key=@exec.Size).streams_name_order())
  assert_false(@exec.OrderOptions::new(key=@exec.Path).streams_name_order())
}
