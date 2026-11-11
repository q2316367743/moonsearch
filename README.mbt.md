# moonsearch

Fast file search over a persistent inverted index, written in MoonBit.

`moonsearch` is an independent implementation inspired by
[FSearch](https://github.com/cboxdoerfer/fsearch) and Everything. It keeps the
query semantics of a desktop file search tool but replaces the "pre-sorted
arrays + linear scan" execution model with a trigram inverted index, bitmap set
algebra, and range arrays. The design is documented in
[`MIGRATION_PLAN.md`](MIGRATION_PLAN.md).

> Status: **S01 — project skeleton and CLI contract**. Every subcommand parses
> its arguments and documents its options, but the index, query engine, and
> output layers are not implemented yet; commands exit with code `2` and a
> pending message.

## Build and run

The project targets the native backend; Wasm has no general-purpose filesystem.

```bash
moon build --target native
moon run cmd/moonsearch -- --help
moon run cmd/moonsearch -- --version
```

## Commands

```text
moonsearch <command> [options] [query...]
```

| Command | Purpose | Status |
| --- | --- | --- |
| `index` | Scan configured roots and write the index | pending (S03, S12) |
| `update` | Rescan the roots and rebuild the index | pending (S03, S12) |
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
src/core/          version, exit codes, shared errors
src/cli/           command specification, invocation, result mapping
src/               public facade
cmd/moonsearch/    executable entry point
tests/cli.md       end-to-end CLI golden tests
```

The original migration plan splits the work into S01–S14. This repository is at
S01; later steps add the scanner, query language, scan oracle, bitmap sets,
dictionaries, range indexes, trigram postings, execution plans, persistence, and
benchmarks.

## License

Apache-2.0. This is an independent implementation: no FSearch code, comments,
constant tables, or test text are copied. FSearch and Everything are credited as
behavioral references only.
