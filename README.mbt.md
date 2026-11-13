# moonsearch

Fast file search over a persistent inverted index, written in MoonBit.

`moonsearch` is an independent implementation inspired by
[FSearch](https://github.com/cboxdoerfer/fsearch) and Everything. It keeps the
query semantics of a desktop file search tool but replaces the "pre-sorted
arrays + linear scan" execution model with a trigram inverted index, bitmap set
algebra, and range arrays. The design is documented in
[`MIGRATION_PLAN.md`](MIGRATION_PLAN.md).

> Status: **S10 — indexed query compiler**. `index` and `update`
> walk real directory trees and build an in-memory `Store` with post-order
> statistics. `src/query` parses the full field/modifier macro syntax into a
> typed `Query` tree, and `src/exec` evaluates it two ways. The S05 linear scan
> is still the semantic oracle: `search --live --root <PATH>` and
> `count --live --root <PATH>` work end to end. The S10 compiler turns the same
> `Query` into an `Expr` over id sets: dictionary terms become constants, range
> terms become sorted-array slices, name substrings become trigram candidates,
> and globs/regexes/path terms become scan predicates that the optimizer pushes
> under indexed candidates. The indexed engine (`--engine bitmap`) is
> cross-checked against the scan engine on every field and boolean combination.
> All index structures — the S07 `Dict`, the S08 `Ranges`, and the S09
> `TrigramIndex` — are bundled in `@index.Index`; the index is still in memory
> only. Persistence (S12) and the remaining output formats (S11) come next.

## Build and run

The project targets the native backend; Wasm has no general-purpose filesystem.

```bash
moon build --target native
moon run cmd/moonsearch -- --help
moon run cmd/moonsearch -- --version
moon run cmd/moonsearch -- index -r /tmp/some-tree
moon run cmd/moonsearch -- search --live --root /tmp/some-tree 'ext:pdf size:>1mb'
```

## Commands

```text
moonsearch <command> [options] [query...]
```

| Command | Purpose | Status |
| --- | --- | --- |
| `index` | Scan roots into an in-memory index and print a summary | works (in memory; persistence is S12) |
| `update` | Rescan the roots and rebuild the index | works (same as `index` until S12) |
| `search` | Query the index (default subcommand) | works with `--live --root <PATH>` on either engine |
| `count` | Print the number of matches | works with `--live --root <PATH>` on either engine |
| `info` | Show index statistics | pending (S12) |

`search` is the default, so a bare query works without the subcommand:

```bash
moonsearch 'ext:pdf size:>1mb'
```

Until persistence lands in S12 a search needs an in-memory store, which
`--live --root <PATH>` builds from a directory scan:

```bash
moonsearch search --live --root /home/user 'ext:jpg;png size:>1mb' -n 20
moonsearch count --live --root /home/user 'dm:lastweek ext:mp4'
```

Global options are accepted before or after the subcommand:

| Option | Meaning |
| --- | --- |
| `-D, --database <PATH>` | Index database path (`MOONSEARCH_DATABASE`) |
| `--config <PATH>` | Configuration file path (`MOONSEARCH_CONFIG`) |
| `--no-config` | Do not read the configuration file |
| `-v, --verbose` / `-q, --quiet` | Verbosity control |
| `--stats` | Print timings and index sizes to stderr |
| `--explain` | Print the execution plan to stderr |
| `-h, --help` / `-V, --version` | Help and version |

Run `moonsearch <command> --help` for the full option list.

## Core model (S02)

The shared, byte-level data model lives in `src/core` and `src/util`:

- `NamePool` — a chunked byte arena for file names. Names are appended as raw
  bytes and read back as zero-copy `BytesView`s through
  `NameRef { offset, length }`. The pool allocates one buffer per chunk, not per
  name, and earlier references remain valid while the pool grows.
- `Entry` — one file or folder: parent folder id, name reference, flags, size,
  mtime, and direct child counts. Folder sizes accumulate with saturation at the
  `Int64` bounds.
- `cmp_paths` — natural path ordering. Digit runs compare numerically
  (`file2 < file10`), `/` sorts before every other byte (`a/b < a.b`), and
  leading-zero runs follow `strverscmp` semantics (`007 < 07 < 7`,
  `09 > 010`).
- `util` byte helpers — ASCII case folding, case-insensitive equality,
  prefix/suffix tests, and byte/needle search over `BytesView`.

## Scanner and in-memory store (S03)

`index` and `update` share one scan pipeline:

```text
roots (normalized with realpath)
  → platform scan source (async/fs)
  → recursive scan: hidden/exclude filters, pre-order entries, post-order stats
  → Builder: name pool + folder/file arrays
  → Store: immutable in-memory view
```

- **`platform`** isolates the file system behind a `ScanSource` trait
  (`list`, `stat`, `realpath`, `has_devices`). The production backend uses
  `moonbitlang/core/async/fs`. Tests implement the same trait in memory, so the
  scanner is exercised without touching disk.
- **Deterministic ids**: every directory listing is sorted by natural name
  order before entries are added, so `readdir` order never reaches the index.
- **Pre-order entries, post-order stats**: a folder gets its id before its
  children are scanned; sizes and direct child counts are filled in once the
  subtree returns. Folder sizes are subtree totals, `num_files`/`num_folders`
  are direct-child counts.
- **Symlinks are never followed.** They are indexed as file entries with the
  symlink flag and contribute zero bytes, so a link to a directory cannot create
  a cycle. Sockets, pipes, and device nodes get the special flag.
- **Exclusions**: `--exclude-hidden` first, then `-x/--exclude` rules
  (`fixed:`/`glob:`, default glob) with `--exclude-scope
  full_path|basename` and `--exclude-target both|files|folders`. `/proc`,
  `/sys`, `/dev`, and `/run` are skipped by default unless
  `--no-default-excludes` is given. `regex:` rules are rejected until the query
  regex engine exists.
- **Roots**: normalized with `realpath`, exact duplicates are dropped, and
  nested roots are rejected unless `--allow-nested-roots` is passed.
- **Recoverable failures** (an unreadable directory, an entry that vanished
  during the scan) are collected as `ScanIssue`s and reported with
  `-v/--verbose`; the scan continues.

`index` prints a stable summary to stdout:

```text
roots: 1
folders: 4
files: 3
bytes: 6
```

`skipped:` and `issues:` lines appear when non-zero. `--stats` adds timing,
name-pool sizes, and the dictionary shape (extension count, category count,
hidden entries) to stderr. Until S12 the store exists only for the duration of
the command; nothing is written to `--database` yet.

### Scanner backend limits

The pure MoonBit backend is the plan's "stage A": it uses path-based syscalls,
decodes names through `String` (so invalid UTF-8 names are mangled by the
runtime), and cannot read `st_dev`. As a consequence `--one-file-system` is a
no-op on this backend and prints a warning; the cross-device logic is already
implemented and tested through injected `ScanSource` implementations. The POSIX
FFI backend that fixes all three limitations is a later step and does not change
the scanner API.

## Query language and AST (S04)

`src/query` turns a query string into a typed `Query` tree. Execution is handled
by the scan engine in S05; this layer only fixes the language.

- **Lexer** (`lex`) — tracks UTF-16 offsets for error positions. `"..."` quotes
  text verbatim (so a regular expression keeps `\.`), `\` escapes the next
  character outside quotes, `name:` becomes a field token, and only uppercase
  whole words are operators (`AND` / `OR` / `NOT`, plus `&&` / `||` / `!`).
  Field names are ASCII case-insensitive.
- **Parser** (`parse`) — a precedence climber: `NOT` binds tighter than the
  implicit or explicit `AND`, which binds tighter than `OR`. It follows the
  upstream recovery rules: a binary operator with no operand is ignored,
  consecutive `NOT`s cancel in pairs, and `--compat` turns an unknown field, a
  malformed value, or a stray `)` into an empty set instead of an error.
- **AST** — `Query { MatchAll, MatchNone, Term, And, Or, Not }` over
  `TermBody { Name, Kind, Visibility, TypeCategory, Extensions, Size, Modified,
  Depth, ChildCount, ChildFileCount, ChildFolderCount, Parent, Empty,
  ContentType }`. `AND` and `OR` fold their neutral elements while the tree is
  built.
- **Modifiers** — `case:`/`nocase:`, `exact:`, `file:`/`files:`,
  `folder:`/`folders:`, `hidden:`, `nohidden:`/`visible:`, `path:`/`nopath:`,
  and `regex:`/`noregex:` are prefix modifiers scoped to one following term or
  group. `file:(a OR b)` applies to both sides; `file:a OR b` does not leak past
  `a`. A standalone `file:`, `folder:`, `hidden:`, or `nohidden:` becomes a
  `Kind`/`Visibility` term, which is also how the CLI's `--type` option filters
  an empty query.
- **Built-in categories** — `app:`, `archive:`, `audio:`, `doc:`, `pic:`, and
  `video:` parse to a `TypeCategory` term instead of expanding to an `ext:`
  list. The field dictionary materializes each category as one set, while the
  scan engine matches the same extension list directly.
- **Term heuristics** — a needle containing `/` searches the full path, and a
  needle containing a non-ASCII uppercase letter becomes case-sensitive, unless
  the matching modifier was written explicitly.
- **Values** — `size:` accepts decimal units (`1kb` = 1000 bytes), comparisons
  (`>1mb`), and half-open ranges (`1kb..2mb` = `[1000, 2000000)`); counting
  fields accept integers; `ext:` splits on `;` and folds ASCII case; `dm:`
  keeps its date text for the predicate layer, which owns the calendar and time
  zone.
- **Macros** (`Macros`, `Macro`) — named query fragments expanded on `name:`,
  looked up ASCII case-insensitively. Expansion uses an independent parser and
  reports direct and indirect cycles. A user macro overrides the built-in
  category of the same name. The built-in categories are not text macros: they
  stay as `TypeCategory` terms and are materialized by the dictionary.

`Query::describe()` renders a compact, stable tree, which the parser tests use
for assertions:

```text
(and (ext "pdf" kind=file) (size > 1000000))
```

## Scan engine and predicates (S05)

`src/exec` is the baseline execution engine and, from S06 on, the oracle the
bitmap engine is compared against. It walks the store once, per entry, and
applies a compiled predicate:

```text
Query AST
  → compile: flags → matchers, regex compiled once, dates resolved against now
  → ScanExpr { All, None, Test, And, Or, Not }
  → for entry in Store::entries_in_order():
        eval(expr, store, entry)   → keep, stop at --limit
```

- **Canonical order** — the store builds one immutable order at construction:
  folders and files merged by name, then full path, both in `cmp_paths` natural
  order. `search` therefore prints name order with no per-query sort, and
  `--limit` stops the walk early instead of collecting every hit first.
- **Predicates** — name substring, exact match, glob (`*` / `?` / `\`; `?`
  matches one byte in this version), and regex (MoonBit's `@string.Regex`,
  case-insensitive via `(?i:...)`); `ext:`, `size:`, `dm:`, `depth:`,
  `childcount:`, `childfilecount:`, `childfoldercount:`, `parent:`, `empty:`,
  and `contenttype:`. `ext:` and `contenttype:` apply to files only; child
  counts and `empty:` apply to folders only.
- **Boolean algebra** — `AND` short-circuits at the first false branch, `OR` at
  the first true one, and `NOT` complements over every entry (the plan's `Both`
  domain). Kind filters from `file:` / `folder:` narrow any term, including a
  parenthesized group.
- **Paths** — name matching uses raw name bytes; `path:` (or a needle containing
  `/`) uses the full path built from the parent chain. `parent:` compares the
  parent folder path byte for byte, with trailing slashes normalized.
- **Content types** — v1 maps common extensions to MIME types; a value without
  `/` matches either the main type (`text` → every `text/*`) or the subtype
  (`pdf` → `application/pdf`). A magic-based lookup is a later step.
- **Unicode** — only ASCII case is folded. Invalid UTF-8 names still match byte
  patterns, but are treated as non-matches by the regex predicate because they
  cannot be decoded into a `String`.

### Dates

`dm:` is resolved by `src/util/time.mbt` in local time, with testable injection
of the clock and zone:

- `today`, `yesterday`, weekday names (`mon` / `monday`), and month names
  (`jan` / `january`, the most recent occurrence);
- `last` / `inthelast` / `prev` / `previous` + unit, optionally with a count as
  digits or words (`lastfiveweeks`, `last3days`) — rolling windows ending now;
- `this` + unit — the current calendar unit (week starts on Monday);
- explicit `YYYY[-MM[-DD[THH[:MM[:SS]]]]]`, with two-digit years.

A bare date names a whole unit, so `dm:2024-03` is the whole month; `>`, `>=`,
`<`, and `<=` apply to that unit's half-open interval. Ranges stay half-open, so
`dm:2020..2021` covers 2020 but not 2021. Calendar arithmetic follows daylight
saving transitions, and tests pin the zone to UTC for determinism.

### Current CLI surface

The scan engine is the default (`--engine scan`); `--engine bitmap` now runs the
S10 compiler over a live index. Search output is the default full-path-per-line
format plus `-n/--limit`; `--sort` (other than `name`), `--reverse`,
`--folders-first`, `--null`, `--json`, `--format`, `--relative-to`, and
`--basename` belong to S11 and are rejected explicitly rather than silently
ignored. `--explain` prints the parsed query and the engine-specific plan to
stderr: the `ScanExpr` predicate tree for the scan engine, or the estimated
`Expr` tree with trigram key counts and scan degradation reasons for the bitmap
engine. `--stats` adds entry, match, and timing lines.

## Id sets and compressed bitmaps (S06)

`src/ids` is the set layer the indexed executor will evaluate on. It depends
only on the core buffer package, so its algebra can be tested with plain arrays
and checked against an independent membership-mask implementation. See
[`docs/modules/ids.md`](docs/modules/ids.md) for the full design.

- **`Ids`** — either `Sorted`, a strictly ascending duplicate-free `Int32`
  array, or `Bitmap`, a compressed bitmap with an O(1) cached cardinality.
  Sparse results stay arrays; dense results become bitmaps.
- **Shape thresholds** — a set becomes a bitmap when its cardinality exceeds
  4096 or, once the index size is known, when `cardinality * 32 > total`.
  Exactly 4096 ids and exactly 1/32 density stay sorted; `normalize(total)`
  re-applies the density rule after a range query.
- **`Bitmap` / `Container`** — ids are split into 65536-id blocks. A block is an
  ascending `UInt16` array while it holds at most 4096 ids and a 1024-word
  `UInt64` bitmap above that; both forms occupy 8 KiB at the threshold. Inserts
  and removes flip the container, and emptied blocks are trimmed.
- **Set algebra** — bitmap×bitmap uses word-parallel operations, sorted×sorted
  merges, and mixed pairs probe the bitmap with the smaller sorted side. A
  sorted side larger than 4096 is converted first. `Ids::filter` narrows a
  candidate set and re-normalizes the result.
- **Serialization** — the plan's `IdsRef` layout: bitmap block streams with
  explicit container tags, or delta-LEB128 sorted ids. Decoding validates tags,
  block order, container contents, cardinality, and trailing bytes, and returns
  `IdsError` instead of panicking on corrupted input.

The bitmap engine is wired into the CLI: `--engine bitmap` evaluates the S10
`Expr` plan over the S07–S09 candidate sources. The S05 scan engine remains the
default and the oracle the indexed engine is checked against. S11 adds the
remaining output orders and formats, and S12 persists the index.

## Field dictionary (S07)

`src/index/dict.mbt` builds the low-cardinality field dictionary after the scan.
It is the first real consumer of `Ids` and the source of candidate sets the
indexed executor consumes.

- **One id space** — `Store::global_id` numbers folders `0 .. folder_count - 1`
  and files from `folder_count` upward. Every dictionary set uses it, so
  `files_all ∪ folders_all` and `ext:pdf OR folder:docs` are ordinary set
  algebra. `Store::entry_at` is the validating reverse mapping.
- **`Dict`** — built once from an immutable store:
  - `extensions` — one bucket per ASCII-folded extension, sorted by bytes; the
    empty extension is a real bucket for `ext:` with no extension;
  - `files_all`, `folders_all`, `all`, `hidden`, `visible`;
  - `roots` — one subtree set per configured root, in `Store::roots()` order;
  - `categories` — one materialized set per built-in category, so `pic:` costs
    an array index rather than a per-query union.
- **Shared rules** — `util.extension_of` is the only extension extractor;
  `util.TypeCategory::extensions` is the only category data. The scan predicate
  and the dictionary therefore cannot disagree about which file is a `pdf` or a
  `pic`.
- **Cross-check** — `exec/dict_compat_test.mbt` expands each dictionary set back
  to paths and compares it with the S05 scan engine for `file:`, `folder:`,
  `hidden:`, `nohidden:`, `file:hidden:`, `folder:hidden:`, `ext:`, the empty
  extension, and all six built-in macros.
- **CLI** — `index` and `update` materialize the dictionary as part of the
  build. `--stats` also prints its shape:
  `dict: <extensions> extensions, 6 categories, <hidden> hidden`.

The dictionary is not persisted yet; S12 writes it as the `DICT` section. The
S10 compiler turns these sets into `Const` leaves of an indexed plan.

## Range indexes (S08)

`src/index/range.mbt` adds the second kind of candidate source: five sorted
`(value, id)` arrays, one per range field.

- **Fields** — `size` (files and folders; a folder value is its subtree total),
  `mtime` (Unix seconds), `depth` (roots 0, files take their parent's depth + 1),
  `childcount` (folders only), and `parent` (a folder id; roots excluded).
- **`RangeIndex`** — two parallel arrays sorted by value, then id. `lower_bound`
  and `upper_bound` are the only search primitives; equality is the run between
  them, and ranges are half-open `[lo, hi)`. An empty or inverted interval
  returns the empty set without touching the arrays. Slices are canonicalized
  back into `Ids`, so a narrow range stays `Sorted` while a broad one becomes a
  `Bitmap` by the S06 density rule.
- **Parent by counting sort** — parent values are folder ids, so the index is
  built in O(N + F) with a counting pass, prefix sums, and one append per entry
  in id order. `parent:<path>` resolves through `ParentPaths`, a byte-sorted
  table of folder paths searched by binary search.
- **Lazy fields and `--fast-fields`** — `Ranges::build` builds only the selected
  fields; the rest materialize on first access and stay cached. The CLI default
  is `size,mtime`; `index --fast-fields size,depth,parent` changes the eager set.
  `--stats` reports only loaded fields (`ranges: size=... mtime=...`), so
  printing statistics never forces a lazy build.
- **Cross-check** — `exec/range_compat_test.mbt` compares every field set against
  the scan engine: the six comparison forms plus inverted ranges for `size`,
  month and comparison dates for `dm`, multi-level `depth`, `childcount` with
  `empty:`, and `parent:` paths that exist or do not.

The range arrays are not persisted yet; S12 writes them as the `RANGES` section.

## Trigram inverted index (S09)

`src/index/trigram.mbt` adds the candidate source for ordinary substring terms:
one posting per distinct ASCII-folded 3-byte window of every entry name.

- **Extraction** — names are folded with `util.ascii_lower` (ASCII only), each
  3-byte window is packed into a 24-bit `UInt32`, and repeated windows inside one
  name are removed before its id is appended. Names shorter than three bytes
  carry no trigram and are only counted; a longer needle cannot match them.
- **Storage** — an ascending `keys : Array[UInt32]` plus parallel
  `TrigramPosting` arrays, so a lookup is a binary search and the build-time hash
  map is released. Ids arrive in store-wide order, which makes every posting
  ascending without a final sort.
- **Lookup** — a needle shorter than three bytes returns a full scan; a missing
  trigram returns the empty candidate set; postings above 20% of the index are
  stop-grams and are skipped; the three shortest remaining postings are
  intersected. The result is a superset that still needs byte verification.
- **Intersection** — a merge when the lists are comparable in length, and
  galloping (exponential probe, then binary search) when one list is at least
  32× shorter. Both branches keep the result ascending and duplicate-free.
- **CLI** — `index`/`update` build the postings unless `--no-trigram` is passed.
  `--stats` reports
  `trigram: <keys> keys, <postings> postings, <short> short names, <stop> stop-grams, <bytes> B`,
  or `trigram: disabled`.
- **Cross-check** — `exec/trigram_compat_test.mbt` enumerates every substring of
  every fixture name and asserts that the scan-engine results for the default,
  `case:`, and `exact:` queries are all contained in the trigram candidates. It
  also pins the fallbacks: short needles, missing trigrams, short names,
  stop-grams, and the fact that name-only postings do not cover `path:` terms.

The postings are not persisted yet; S12 writes them as the `POSTINGS` section.

## Indexed query compiler and plans (S10)

`src/exec/plan.mbt` compiles a `Query` into an `Expr` over id sets and evaluates
it with set algebra. The scan engine and the indexed engine share the parser,
the field rules, and the per-entry predicates; they differ only in how the
candidate set is produced.

```text
Query
  → compile: domain pruning + leaf selection (Const / Trigram / Scan / Filter)
  → optimize: constant folding, cardinality reordering, predicate pushdown
  → evaluate: Ids intersection, union, and difference
```

- **Leaves** — `Const` is a set already materialized by `Dict` or `Ranges`;
  `Trigram` is a posting candidate set that still needs byte verification;
  `Scan` is a predicate with no index support; `Filter` is a pushed-down scan
  predicate over another node. Every leaf keeps the term text so `--explain`
  stays readable.
- **Compilation** — `file:`, `folder:`, `hidden:`, `ext:`, built-in categories,
  `size:`, `dm:`, `depth:`, `childcount:`, `parent:`, and `empty:` become
  constants or range slices. A plain substring or `exact:` term with a needle of
  at least three bytes becomes a trigram leaf. Glob, regex, `path:`, short
  needles, all-stop-gram needles, and disabled postings become scan leaves with
  the reasons `glob`, `regex`, `path`, `short-needle`, `stop-grams`, and
  `no-trigram`. `childfilecount:`, `childfoldercount:`, and `contenttype:` are
  scan leaves until a range index exists for them.
- **Type domains** — every subtree is classified `FilesOnly`, `FoldersOnly`,
  `Both`, or `Never`. `file:` combined with `folder:`, or `ext:` under a folder
  modifier, is `Never` and compiles to the empty set without touching the index.
  A negation is always complemented over every entry, matching the scan engine.
- **Optimizer** — adjacent constants merge; `And(empty, x)` is empty;
  `Or(universe, x)` is the universe; `Not(Const)` becomes a constant; double
  negation collapses. `And` sides are ordered by estimated cardinality, and a
  scan predicate is pushed below the indexed side (`And(Scan(p), x)` becomes
  `Filter(p, x)`) so globs and regexes only visit candidates.
- **Evaluation** — `And` short-circuits on an empty left side, and `Not` uses
  `Dict::all()` as the universe. `exec_indexed` returns an `Ids` set;
  `exec_indexed_count` returns its cardinality. `search --engine bitmap` walks
  the canonical order and checks membership, which preserves `name` order and
  early-stops at `--limit` (the other sort keys are S11).
- **`--explain`** — a single deterministic line per node, for example
  `(filter#4 (glob "*.pdf" nocase) (const#4 (size > 1000)))` or
  `(scan#9 reason=short-needle (substring "re" nocase))`. `node#N` is the
  estimated cardinality, `keys=` the number of intersected postings, and
  `reason=` the degradation behind a scan leaf.
- **Cross-check** — `exec/plan_test.mbt` asserts the compiled shape of every
  field, compares optimized and unoptimized plans against `exec_scan` over the
  full query corpus (including `--no-trigram` and an empty store), and pins the
  explain goldens.

`@index.Index` bundles the store and the three candidate sources, so the
compiler, the CLI, and the upcoming persistence layer pass one object instead of
four.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, help, or version |
| `1` | No match |
| `2` | Argument, query, IO, or database error |
| `130` | Interrupted by SIGINT |

## Development

```bash
moon check --target native --deny-warn
moon test --target native
moon fmt
moon info
moon testcli test tests/cli.md --target native
```

Layout:

```text
src/util/          byte helpers, extension/category rules, path/glob/date parsing
src/core/          version, exit codes, name pool, entry/store model, global ids
src/platform/      ScanSource trait and the async/fs backend
src/index/         excludes, builder, scanner, dictionary, ranges, trigram postings
src/query/         lexer, parser, query AST, flags, values, macros, categories
src/exec/          scan engine, query compiler, optimizer, indexed executor
src/ids/           Ids set algebra, compressed bitmap containers, serialization
src/cli/           command specification, invocation, index/search commands
src/               public facade
cmd/moonsearch/    executable entry point
tests/cli.md       end-to-end CLI golden tests
```

The original migration plan splits the work into S01–S14. This repository is at
S10; later steps add the remaining result orders and formats (S11), persistence
(S12), the full cross-check/property/fuzz suite (S13), and benchmarks (S14).
Module notes live in `docs/modules/`.

## License

Apache-2.0. This is an independent implementation: no FSearch code, comments,
constant tables, or test text are copied. FSearch and Everything are credited as
behavioral references only. The pinned runtime dependencies are
`moonbitlang/core` and `moonbitlang/x` (Apache-2.0).
