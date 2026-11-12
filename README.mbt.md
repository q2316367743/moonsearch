# moonsearch

Fast file search over a persistent inverted index, written in MoonBit.

`moonsearch` is an independent implementation inspired by
[FSearch](https://github.com/cboxdoerfer/fsearch) and Everything. It keeps the
query semantics of a desktop file search tool but replaces the "pre-sorted
arrays + linear scan" execution model with a trigram inverted index, bitmap set
algebra, and range arrays. The design is documented in
[`MIGRATION_PLAN.md`](MIGRATION_PLAN.md).

> Status: **S05 — scan engine and predicates**. `index` and `update` walk real
> directory trees and build an in-memory `Store` with post-order statistics.
> `src/query` parses the full field/modifier macro syntax into a typed `Query`
> tree, and `src/exec` evaluates it against a store with a streaming linear scan:
> `search --live --root <PATH>` and `count --live --root <PATH>` work end to end.
> This scan engine is the semantic oracle every later index structure is checked
> against. The index is not persisted yet and the bitmap engine arrives with S06;
> `info` remains pending.

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
| `search` | Query the index (default subcommand) | works with `--live --root <PATH>` (scan engine) |
| `count` | Print the number of matches | works with `--live --root <PATH>` |
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

`skipped:` and `issues:` lines appear when non-zero. `--stats` adds timing and
name-pool sizes to stderr. Until S12 the store exists only for the duration of
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
  `TermBody { Name, Kind, Extensions, Size, Modified, Depth, ChildCount,
  ChildFileCount, ChildFolderCount, Parent, Empty, ContentType }`. `AND` and
  `OR` fold their neutral elements while the tree is built.
- **Modifiers** — `case:`/`nocase:`, `exact:`, `file:`/`files:`,
  `folder:`/`folders:`, `path:`/`nopath:`, and `regex:`/`noregex:` are prefix
  modifiers scoped to one following term or group. `file:(a OR b)` applies to
  both sides; `file:a OR b` does not leak past `a`. A standalone `file:` or
  `folder:` becomes a `Kind` term, which is also how the CLI's `--type` option
  filters an empty query.
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
  reports direct and indirect cycles. The built-in category macros are
  materialized with the dictionary in S07.

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

The scan engine is the only engine until S06, so `--engine` defaults to `scan`
and `--engine bitmap` reports that it is not implemented yet. Search output is
the default full-path-per-line format plus `-n/--limit`; `--sort` (other than
`name`), `--reverse`, `--folders-first`, `--null`, `--json`, `--format`,
`--relative-to`, and `--basename` belong to S11 and are rejected explicitly
rather than silently ignored. `--explain` prints the parsed query and compiled
plan to stderr; `--stats` adds entry, match, and timing lines.

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
src/util/          byte helpers, natural path ordering, glob/date parsing
src/core/          version, exit codes, name pool, entry/store model, canonical order
src/platform/      ScanSource trait and the async/fs backend
src/index/         exclude rules, builder, recursive scanner, in-memory store
src/query/         lexer, parser, query AST, flags, values, macros
src/exec/          scan engine: compiled predicates, exec_scan, exec_count
src/cli/           command specification, invocation, index/search commands
src/               public facade
cmd/moonsearch/    executable entry point
tests/cli.md       end-to-end CLI golden tests
```

The original migration plan splits the work into S01–S14. This repository is at
S05; later steps add bitmap sets, dictionaries, range indexes, trigram postings,
execution plans, persistence, and benchmarks.

## License

Apache-2.0. This is an independent implementation: no FSearch code, comments,
constant tables, or test text are copied. FSearch and Everything are credited as
behavioral references only. The pinned runtime dependencies are
`moonbitlang/core` and `moonbitlang/x` (Apache-2.0).
