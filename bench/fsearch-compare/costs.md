# Build, update and memory costs

## Reproducible synthetic 300k (2026-11-28)

Dataset: `bench/.data/synthetic-300k`, 30,000 folders + 270,000 files,
manifest SHA-256 `4cc38f9684090e853b1583a03e9e503cf701a97e76ddf3ae3bd1da53d3db18cf`.
Apple M4 Pro, macOS 26.6.2, MoonBit 0.1.20261126, release build.

| Item | moonsearch + trigram | moonsearch `--no-trigram` | FSearch core, 1 thread |
| --- | ---: | ---: | ---: |
| Build (scan + index) | 7.42 s | 4.25 s | 3.56 s |
| Build peak RSS | 204.1 MiB | 155.6 MiB | not measured |
| Database on disk | 31.0 MB | 27.7 MB | not measured |
| Load (`Index::read_database`) | 59.9 ms | not measured | not measured |
| Query-time RSS | not measured | — | not measured |
| Trigram keys / postings | 872 / 3,424,744 | — | — |

FSearch's number is an in-memory index build from the same tree.  It does not
build trigram postings and does not write a database, so it is **not** a
like-for-like build comparison: it establishes the cost of the scan plus
FSearch's own sort structures, not the cost of moonsearch's extra indexes.

Trigram overhead on this tree: +3.17 s build, +3.5 MB database, +48.5 MiB peak
build RSS.

### Trigram ablation (same tree, bitmap count path)

| Query | hits | trigram | no trigram | speedup |
| --- | ---: | ---: | ---: | ---: |
| `ext:jpg` | 269 | 0.037 ms | 0.037 ms | 1.0x |
| `report` | 8,972 | 0.684 ms | 15.412 ms | 22.5x |
| `source map` | 614 | 2.774 ms | 18.280 ms | 6.6x |
| `index` | 8,710 | 0.707 ms | 15.458 ms | 21.9x |
| `node_modules` | 3,750 | 0.239 ms | 14.321 ms | 60.0x |
| `package.json` | 0 | 0.039 ms | 14.381 ms | 369.4x |
| `the` | 8,710 | 0.645 ms | 16.290 ms | 25.2x |
| `*.pdf` | 271 | 22.061 ms | 22.234 ms | 1.0x |

Trigram postings pay off on name substrings; they do nothing for globs,
regexes, `path:` or short needles.  Full table:
`results-synthetic-300k.md`.

## Historical private snapshot (297,595 entries, 2026-11-18)

Dataset: `~/Documents/workspace/plugin`, 25,424 folders + 272,171 files,
3,175,768,390 bytes.  Apple M4 Pro, macOS 26.6.2, MoonBit 0.1.20261104,
release build, 2026-11-18.  This tree is not reproducible from a clean clone;
it is kept as a supplementary data point only.

| Item | moonsearch + trigram | moonsearch `--no-trigram` | FSearch core, 1 thread |
| --- | ---: | ---: | ---: |
| Build (scan + index) | 20.9 s | 18.0 s | 4.8–7.6 s |
| Build peak RSS | 172 MiB | 160 MiB | 49 MiB |
| Database on disk | 22.5 MB | 17.5 MB | not measured |
| Load (`Index::read_database`) | ~0.26 s | ~0.24 s | not measured |
| Query-time RSS | 96 MiB | — | 49 MiB (build + query) |
| `update` | 21.2 s, full rebuild | — | — |
| Trigram keys / postings | 21,635 / 4,132,582 | — | — |

### Trigram ablation (historical tree)

| Query | hits | trigram | no trigram | speedup |
| --- | ---: | ---: | ---: | ---: |
| `ext:jpg` | 9 | 0.037 ms | 0.035 ms | 0.9x |
| `report` | 192 | 0.049 ms | 12.970 ms | 263x |
| `source map` | 450 | 3.741 ms | 15.666 ms | 4.2x |
| `index` | 18,139 | 1.071 ms | 13.519 ms | 12.6x |
| `node_modules` | 2,450 | 0.099 ms | 9.770 ms | 99x |
| `package.json` | 2,528 | 0.131 ms | 9.515 ms | 73x |
| `the` | 701 | 0.061 ms | 13.977 ms | 228x |
| `*.pdf` | 0 | 14.415 ms | 14.494 ms | 1.0x |

### Small-tree crossover (2,272 entries)

| Item | moonsearch | FSearch 1T |
| --- | ---: | ---: |
| Build | 0.17 s | 0.024 s |
| Database / index | 271 KB | in-memory |
| Load | 1.5–1.9 ms | — |
| Query (`ext:mbt`, 402 hits) | 0.039 ms | 0.055 ms |
| Query (`*.md`, 43 hits) | 0.128 ms | 0.088 ms |
| Query (`size:>1kb`, 1,719 hits) | 0.081 ms | 0.042 ms |
| Query (empty) | 0.034 ms | 0.002 ms |

At this size the index has no consistent advantage: FSearch's single pass is
already tens of microseconds, and the 1.5–1.9 ms load is larger than most
queries.  The indexed engine is a large-tree tool, not a universal replacement.
