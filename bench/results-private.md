# moonsearch benchmark results

Generated: `2026-11-28T07:02:18+00:00`

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
| commit | 9c58969-dirty |

## Index build

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Scan + build + write | 92.7 s (90 s at 1M) | 31.9 s | PASS |
| Build peak RSS (information) | n/a | 720.2 MiB | n/a |

Build statistics from `index --stats`:

- `scan_ms`: 30073
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
| Read MSDB into memory | 824 ms (800 ms at 1M) | 203 ms | PASS |
| Query-time peak RSS | 400 MiB at 1M | 372.0 MiB | PASS |

## Engine latency

Engine numbers come from `moonsearch-bench`: one database load, then `moonsearch/core/bench` samples the query path in-process with a monotonic clock. The median is shown; the raw JSON has min/max/mean.

| Query | Target | Bitmap median | Scan median | Matches | Status |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | 1 ms | 37.8 µs | 43.79 ms | 73 | PASS |
| `ext:jpg size:>1mb` | 5 ms | 335.5 µs | 53.80 ms | 2 | PASS |
| `ext:jpg size:>1mb dm:lastweek` | 8 ms | 3.93 ms | 62.74 ms | 0 | PASS |
| `report` | 20 ms | 78.5 µs | 49.06 ms | 419 | PASS |
| `report pdf` | 40 ms | 272.6 µs | 51.92 ms | 0 | PASS |
| `*.pdf` | 120 ms | 86.73 ms | 79.39 ms | 4 | PASS |
| `source map` | 40 ms | 13.19 ms | 51.09 ms | 2,445 | PASS |
| `count ext:mp4` | 1.0 ms | 39.1 µs | n/a | 25 | PASS |
| empty query, `-n 20` | 1.0 ms | 36.0 µs | 36.7 µs | 1,030,277 | PASS |

## CLI wall time

Each CLI invocation loads the database and formats results, so this column is the user-visible cost, not the engine cost above. Median of 3 runs after one warm-up.

| Command | Target (engine) | Median wall | Min wall | Status |
| --- | --- | --- | --- | --- |
| `search 'ext:jpg'` | 1.0 ms | 242.0 ms | 235.8 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 242.6 ms | 235.0 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 215.4 ms | 213.1 ms | n/a (includes load) |
| `search 'report'` | 20.0 ms | 241.3 ms | 237.3 ms | n/a (includes load) |
| `search 'report pdf'` | 40.0 ms | 212.1 ms | 209.1 ms | n/a (includes load) |
| `search '*.pdf'` | 120.0 ms | 317.1 ms | 315.5 ms | n/a (includes load) |
| `search 'source map'` | 40.0 ms | 256.5 ms | 254.6 ms | n/a (includes load) |
| `count 'ext:mp4'` | 1.0 ms | 250.1 ms | 239.2 ms | n/a (includes load) |
| `search -n 20 ''` | 1.0 ms | 236.4 ms | 228.5 ms | n/a (includes load) |

## Index size

| Section | Bytes |
| --- | --- |
| roots | 209 |
| names | 2,704,661 |
| folders | 3,185,426 |
| files | 24,351,288 |
| order | 4,121,108 |
| dict | 1,646,568 |
| ranges | 50,577,557 |
| postings | 15,895,877 |
| checksum | 8 |
| **total** | **115,005,406** |

Base (names + entry records): 28.8 MiB. Index extra: 80.8 MiB of the base (2.80×; plan budget 1.5×). Total / base: 3.80×.

## Notes

- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.
- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.
- `report pdf` has no matches in this tree; it still measures two independent trigram groups.
- `dm:lastweek` resolves against the local time zone at run time.
- Re-run with `--rebuild-index` to regenerate the database and the build row.
