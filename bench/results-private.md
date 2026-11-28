# moonsearch benchmark results

Generated: `2026-11-28T07:22:38+00:00`

## Dataset

| Field | Value |
| --- | --- |
| Label | `private-workspace-1m` |
| Roots | `~/Documents/workspace/app`<br>`~/Documents/workspace/dashou-plugin`<br>`~/Documents/workspace/plugin` |
| Entries | 1,030,277 |
| Folders / files | 93,689 / 936,588 |
| Names (unique) | 171,485 |
| Database | 109.7 MiB |
| Format | `MSDB 3.2` |

## Environment

| Field | Value |
| --- | --- |
| cpu | Apple M4 Pro |
| memory | 48.0 GiB |
| os | 26.6.2 |
| platform | macOS-26.6.2-arm64-arm-64bit |
| machine | arm64 |
| moon | moon 0.1.20261126 (ccd306a 2026-11-26) |
| commit | 1f1c092 |

## Index build

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Scan + build + write | 92.7 s (90 s at 1M) | 27.4 s | PASS |
| Build peak RSS (information) | n/a | 720.3 MiB | n/a |

Build statistics from `index --stats`:

- `scan_ms`: 25772
- `database_bytes`: 115005406
- `names`: 1030277
- `name_bytes`: 16522271
- `extensions`: 265
- `hidden`: 4494
- `ranges`: size=1030277 mtime=1030277 depth=1030277 childcount=93689 parent=1030274
- `trigram`: 44019 keys, 14393331 postings, 9045 short names, 3 stop-grams, 57573324 B

## Database load

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Read MSDB into memory | 824 ms (800 ms at 1M) | 192 ms | PASS |
| Query-time peak RSS | 400 MiB at 1M | 371.8 MiB | PASS |

## Engine latency

Engine numbers come from `moonsearch-bench`: one database load, then `moonsearch/core/bench` samples the query path in-process with a monotonic clock. The median is shown; the raw JSON has min/max/mean.

| Query | Target | Bitmap median | Scan median | Matches | Status |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | 1 ms | 33.7 µs | 42.26 ms | 73 | PASS |
| `ext:jpg size:>1mb` | 5 ms | 301.1 µs | 51.67 ms | 2 | PASS |
| `ext:jpg size:>1mb dm:lastweek` | 8 ms | 3.42 ms | 59.53 ms | 0 | PASS |
| `report` | 20 ms | 73.0 µs | 47.48 ms | 419 | PASS |
| `report pdf` | 40 ms | 252.8 µs | 49.91 ms | 0 | PASS |
| `*.pdf` | 120 ms | 83.49 ms | 76.36 ms | 4 | PASS |
| `source map` | 40 ms | 12.20 ms | 49.19 ms | 2,445 | PASS |
| `count ext:mp4` | 1.0 ms | 34.0 µs | n/a | 25 | PASS |
| empty query, `-n 20` | 1.0 ms | 33.5 µs | 33.9 µs | 1,030,277 | PASS |

## CLI wall time

Each CLI invocation loads the database and formats results, so this column is the user-visible cost, not the engine cost above. Median of 3 runs after one warm-up.

| Command | Target (engine) | Median wall | Min wall | Status |
| --- | --- | --- | --- | --- |
| `search 'ext:jpg'` | 1.0 ms | 221.2 ms | 220.6 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 222.5 ms | 218.6 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 203.9 ms | 202.6 ms | n/a (includes load) |
| `search 'report'` | 20.0 ms | 223.1 ms | 223.0 ms | n/a (includes load) |
| `search 'report pdf'` | 40.0 ms | 198.4 ms | 195.4 ms | n/a (includes load) |
| `search '*.pdf'` | 120.0 ms | 305.0 ms | 304.7 ms | n/a (includes load) |
| `search 'source map'` | 40.0 ms | 242.0 ms | 238.3 ms | n/a (includes load) |
| `count 'ext:mp4'` | 1.0 ms | 214.9 ms | 213.8 ms | n/a (includes load) |
| `search -n 20 ''` | 1.0 ms | 220.1 ms | 215.3 ms | n/a (includes load) |

## Index size

| Section | Bytes |
| --- | --- |
| roots | 209 |
| excludes | 4 |
| names | 2,704,661 |
| folders | 3,185,426 |
| files | 24,351,288 |
| order | 4,121,108 |
| dict | 1,646,568 |
| ranges | 50,577,557 |
| parent-paths | 12,522,416 |
| postings | 15,895,877 |
| checksum | 8 |
| **total** | **115,005,406** |

RANGES breakdown (5 B field header + 12 B per `(value, id)` pair):

| Field | Entries | Bytes |
| --- | ---: | ---: |
| size | 1,030,277 | 12,363,329 |
| mtime | 1,030,277 | 12,363,329 |
| depth | 1,030,277 | 12,363,329 |
| childcount | 93,689 | 1,124,273 |
| parent | 1,030,274 | 12,363,293 |
| field count | — | 4 |

Base (names + entry records): 28.8 MiB. Index extra: 80.8 MiB of the base (2.80×; plan budget 1.5×). Total / base: 3.80×.

## Notes

- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.
- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.
- `report pdf` has no matches in this tree; it still measures two independent trigram groups.
- `dm:lastweek` resolves against the local time zone at run time.
- Re-run with `--rebuild-index` to regenerate the database and the build row.
