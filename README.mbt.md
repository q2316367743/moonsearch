# moonsearch

Fast file search over a persistent inverted index, written in MoonBit.

`moonsearch` is an independent implementation inspired by
[FSearch](https://github.com/cboxdoerfer/fsearch) and Everything. It keeps the
query semantics of a desktop file search tool but replaces the "pre-sorted
arrays + linear scan" execution model with a trigram inverted index, bitmap set
algebra, and range arrays. The design is documented in
[`MIGRATION_PLAN.md`](MIGRATION_PLAN.md).

> Status: **S03 — scanner and in-memory store**. `index` and `update` now walk
> real directory trees, apply exclusion rules, and build an in-memory `Store`
> with post-order statistics. The index is not persisted yet (S12), `search` and
> `count` still report that they are pending, and the query engine is S04–S11.

## Build and run

The project targets the native backend; Wasm has no general-purpose filesystem.

```bash
moon build --target native
moon run cmd/moonsearch -- --help
moon run cmd/moonsearch -- --version
moon run cmd/moonsearch -- index -r /tmp/some-tree
```

## Commands

```text
moonsearch <command> [options] [query...]
```

| Command | Purpose | Status |
| --- | --- | --- |
| `index` | Scan roots into an in-memory index and print a summary | works (in memory; persistence is S12) |
| `update` | Rescan the roots and rebuild the index | works (same as `index` until S12) |
| `search` | Query the index (default subcommand) | pending (S04–S11) |
| `count` | Print the number of matches | pending (S11) |
| `info` | Show index statistics | pending (S12) |

`search` is the default, so a bare query works without the subcommand:

```bash
moonsearch 'ext:pdf size:>1mb' --sort size --reverse -n 20
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
src/util/          byte helpers, natural path ordering, glob matching
src/core/          version, exit codes, name pool, entry/store model
src/platform/      ScanSource trait and the async/fs backend
src/index/         exclude rules, builder, recursive scanner, in-memory store
src/cli/           command specification, invocation, index command
src/               public facade
cmd/moonsearch/    executable entry point
tests/cli.md       end-to-end CLI golden tests
```

The original migration plan splits the work into S01–S14. This repository is at
S03; later steps add the query language, scan oracle, bitmap sets,
dictionaries, range indexes, trigram postings, execution plans, persistence, and
benchmarks.

## License

Apache-2.0. This is an independent implementation: no FSearch code, comments,
constant tables, or test text are copied. FSearch and Everything are credited as
behavioral references only.
