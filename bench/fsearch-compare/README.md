# FSearch same-condition benchmark

This directory contains a headless driver for FSearch's own core library and a
small merge script.  It exists to answer one question with measurements instead
of architectural assertions:

> For the same directory tree and the same query, what does FSearch's
> single-pass, per-entry execution model cost, and what does moonsearch's
> indexed execution model cost?

FSearch is a GTK application, so timing the GUI would mix in window startup,
database loading, rendering and user interaction.  Instead, `bench_fsearch.c`
links `src/libfsearch_core` (the non-UI part of FSearch), scans the same tree
into FSearch's in-memory index, and calls
`fsearch_database_index_store_search()` directly.  That is the same call the
GUI makes after the user presses Enter.  The driver is not a reimplementation:
it uses FSearch's parser, query tree, matchers, database entries and thread
pool.

## What is measured

| Number | Tool | Meaning |
| --- | --- | --- |
| FSearch build | `bench_fsearch` | scan + FSearch in-memory index build, no persistence |
| FSearch query | `bench_fsearch` | one `index_store_search()`, including result-view insertion; worker pool set by `--threads` |
| moonsearch build | `moonsearch index --stats` | scan + Store/Dict/Ranges/trigram + atomic DB write |
| moonsearch load | `moonsearch-bench` | `Index::read_database()` |
| moonsearch count | `moonsearch-bench` | `exec_indexed()` set production only |
| moonsearch search | `moonsearch-bench --first N` | set production + canonical-order walk; `N` larger than the hit count means every hit is materialized |

`--threads 1` forces FSearch's `g_get_num_processors()` to return 1, so the
comparison is against a single-threaded moonsearch.  Omitting `--threads`
shows FSearch's default multi-core number as a product reference.  The build
renames the symbol at compile time; FSearch itself is not modified.

## Build

macOS (Homebrew ICU is keg-only, hence `PKG_CONFIG_PATH`):

```bash
brew install glib pango pcre2 icu4c
PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig" \
  bash bench/fsearch-compare/build.sh /path/to/fsearch /tmp/bench_fsearch
```

Linux:

```bash
sudo apt-get install build-essential pkg-config libglib2.0-dev \
  libpango1.0-dev libpcre2-dev libicu-dev
bash bench/fsearch-compare/build.sh /path/to/fsearch /tmp/bench_fsearch
```

The driver compiles the core source list from the upstream `src/meson.build`
(non-UI sources only) and provides a `config.h` plus two small Darwin
compatibility shims.  It does not patch the FSearch checkout.

FSearch is GPL-2.0.  The built harness links against the user-supplied FSearch
checkout; it is a local measurement tool, not part of the moonsearch library.
Do not redistribute the built binary without complying with FSearch's license.

## Run

FSearch, one thread, queries as command-line arguments:

```bash
TZ=Asia/Shanghai /tmp/bench_fsearch \
  --threads 1 --root /path/to/tree --runs 5 \
  '' 'ext:jpg' 'report' '*.pdf' 'a' 'size:>1kb'
```

moonsearch:

```bash
moon build --target native --release
_build/native/release/build/cmd/moonsearch/moonsearch.exe index \
  -D /tmp/tree.msdb -r /path/to/tree --stats

moonsearch-bench --database /tmp/tree.msdb --engine bitmap --runs 5 ...
moonsearch-bench --database /tmp/tree.msdb --engine scan   --runs 5 ...
moonsearch-bench --database /tmp/tree.msdb --engine bitmap --first 2000000 ...
```

Merge the TSV outputs from the repository root:

```bash
python3 bench/fsearch-compare/compare.py \
  --fsearch bench/fsearch-compare/results/fsearch-plugin-st.tsv \
  --fsearch bench/fsearch-compare/results/fsearch-plugin-extra.tsv \
  --fsearch bench/fsearch-compare/results/fsearch-common.tsv \
  --fsearch bench/fsearch-compare/results/fsearch-stopgram.tsv \
  --scan bench/fsearch-compare/results/scan.tsv \
  --scan bench/fsearch-compare/results/scan-extra.tsv \
  --scan bench/fsearch-compare/results/scan-common.tsv \
  --scan bench/fsearch-compare/results/scan-stopgram.tsv \
  --bitmap bench/fsearch-compare/results/bitmap.tsv \
  --bitmap bench/fsearch-compare/results/bitmap-extra.tsv \
  --bitmap bench/fsearch-compare/results/bitmap-common.tsv \
  --bitmap bench/fsearch-compare/results/bitmap-stopgram.tsv \
  --bitmap-full bench/fsearch-compare/results/bitmap-fullwalk-all.tsv \
  --no-trigram bench/fsearch-compare/results/bitmap-notrigram.tsv \
  --label plugin-297k \
  --markdown bench/fsearch-compare/results-plugin.md \
  --json bench/fsearch-compare/results-plugin.json
```

The published `results-synthetic-300k.md` is produced by:

```bash
python3 bench/fsearch-compare/compare.py \
  --fsearch bench/fsearch-compare/results/synthetic-fsearch.tsv \
  --scan bench/fsearch-compare/results/synthetic-scan.tsv \
  --bitmap bench/fsearch-compare/results/synthetic-bitmap.tsv \
  --bitmap-full bench/fsearch-compare/results/synthetic-bitmap-full.tsv \
  --no-trigram bench/fsearch-compare/results/synthetic-bitmap-notrigram.tsv \
  --label synthetic-300k \
  --markdown bench/fsearch-compare/results-synthetic-300k.md \
  --json bench/fsearch-compare/results-synthetic-300k.json
```

`results-plugin.md` was produced by the multi-file command in the historical
snapshot section of `docs/benchmarks.md`.  Dropping the `extra`, `common` or
`stopgram` inputs silently removes rows from that report.  The exact query set
is the union of the `QUERY` and `BENCH` names in
`bench/fsearch-compare/results/*.tsv`; those files are the source of truth for
the published tables.

## Dataset and snapshots

`results-synthetic-300k.md` / `.json` are the reproducible comparison.  They use
a deterministic 300,000-entry tree (30,000 folders, 270,000 files) generated by
`bench/gen_dataset.py`, manifest SHA-256
`4cc38f9684090e853b1583a03e9e503cf701a97e76ddf3ae3bd1da53d3db18cf`.
The same generator builds the 1,030,056-entry dataset used by
`bench/results.md`, so the tree can be recreated from a clean clone:

```bash
python3 bench/gen_dataset.py --dir bench/.data/synthetic-300k --entries 300000 \
  --reference-time 2026-11-28T00:00:00Z
moon build --target native --release
moonsearch.exe -D bench/.work/synthetic-300k.msdb index -r bench/.data/synthetic-300k --stats
```

FSearch's numbers come from FSearch 0.3-dev commit `1208a34`; build the harness
against that checkout with the command above.  FSearch and moonsearch agree on
hit counts except the two queries documented under the table; those differences
are parser semantics, not missing entries.

`results-plugin.md` / `.json` and `costs.md` are a historical private snapshot
measured on 2026-11-18 from `~/Documents/workspace/plugin` (297,595 entries).
That tree is not reproducible from a clean clone and is kept only as a
supplementary data point; it must not be used as the primary comparison.
`results-small.md` / `.json` use 2,272 entries from the moonsearch repository
itself, as a small-tree crossover check.  The raw TSV files are kept under
`results/` so every table can be regenerated without re-running the scan.

## Caveats

- FSearch's build number is an in-memory index build; it does not include
  FSearch's own on-disk database load/save.  moonsearch's build number includes
  trigram postings and the atomic MSDB write, so the two build numbers are not
  an apples-to-apples comparison of scan speed.
- FSearch and moonsearch differ on two documented edges: moonsearch indexes
  symlinks as 0-byte files, and moonsearch does not round human-readable size
  units the way FSearch's parser does.  `file:`-qualified size queries avoid
  the folder-size difference.
- The query strings are chosen to be valid in both parsers.  FSearch and
  moonsearch use different date rollover rules at month/year boundaries, so
  date results are only comparable when the run is close in time.
