# moonsearch benchmark results

Generated: `2026-11-18T04:48:26+00:00`

## Dataset

| Field | Value |
| --- | --- |
| Label | `workspace-2.36m` |
| Roots | `~/Documents/workspace` |
| Entries | 2,362,503 |
| Folders / files | 230,946 / 2,131,557 |
| Names (unique) | 241,462 |
| Database | 166.0 MiB |
| Format | `MSDB 2.0` |

## Environment

| Field | Value |
| --- | --- |
| cpu | Apple M4 Pro |
| memory | 48.0 GiB |
| os | 26.6.2 |
| platform | macOS-26.6.2-arm64-arm-64bit |
| machine | arm64 |
| moon | moon 0.1.20261104 (940aa18 2026-11-04) Feature flags enabled: rr_moon_mod,rr_moon_pkg |
| commit | f9ff66f-dirty |

## Index build

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Scan + build + write | 212.6 s (90 s at 1M) | 150.0 s | PASS |
| Build peak RSS (information) | n/a | 1.4 GiB | n/a |

Build statistics from `index --stats`:

- `scan_ms`: 147208
- `database_bytes`: 174065814
- `names`: 2362503
- `name_bytes`: 36269878
- `extensions`: 318
- `hidden`: 10201
- `ranges`: size=2362503 mtime=2362503
- `trigram`: 47871 keys, 31393971 postings, 14554 short names, 4 stop-grams, 125575884 B

## Database load

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Read MSDB into memory | 1890 ms (800 ms at 1M) | 2453 ms | MISS |
| Query-time peak RSS | 400 MiB at 1M | 679.3 MiB | PASS |

## Engine latency

Engine numbers come from `moonsearch-bench`: one database load, then `moonsearch/core/bench` samples the query path in-process with a monotonic clock. The median is shown; the raw JSON has min/max/mean.

| Query | Target | Bitmap median | Scan median | Matches | Status |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | 1 ms | 34.1 µs | 98.99 ms | 228 | PASS |
| `ext:jpg size:>1mb` | 5 ms | 728.3 µs | 103.81 ms | 2 | PASS |
| `ext:jpg size:>1mb dm:lastweek` | 8 ms | 4.98 ms | 115.80 ms | 0 | PASS |
| `report` | 20 ms | 116.9 µs | 144.19 ms | 1,389 | PASS |
| `report pdf` | 40 ms | 395.2 µs | 149.27 ms | 0 | PASS |
| `*.pdf` | 120 ms | 143.07 ms | 197.25 ms | 8 | MISS |
| `source map` | 40 ms | 31.98 ms | 154.10 ms | 4,899 | PASS |
| `count ext:mp4` | 1.0 ms | 34.6 µs | n/a | 9 | PASS |
| empty query, `-n 20` | 1.0 ms | 33.7 µs | 34.3 µs | 2,362,503 | PASS |

## CLI wall time

Each CLI invocation loads the database and formats results, so this column is the user-visible cost, not the engine cost above. Median of 3 runs after one warm-up.

| Command | Target (engine) | Median wall | Min wall | Status |
| --- | --- | --- | --- | --- |
| `search 'ext:jpg'` | 1.0 ms | 2636.6 ms | 2516.1 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 2522.0 ms | 2510.0 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 2516.1 ms | 2509.3 ms | n/a (includes load) |
| `search 'report'` | 20.0 ms | 2643.3 ms | 2559.3 ms | n/a (includes load) |
| `search 'report pdf'` | 40.0 ms | 2515.3 ms | 2482.5 ms | n/a (includes load) |
| `search '*.pdf'` | 120.0 ms | 2678.8 ms | 2662.0 ms | n/a (includes load) |
| `search 'source map'` | 40.0 ms | 2598.7 ms | 2583.4 ms | n/a (includes load) |
| `count 'ext:mp4'` | 1.0 ms | 2513.5 ms | 2501.6 ms | n/a (includes load) |
| `search -n 20 ''` | 1.0 ms | 2526.3 ms | 2513.8 ms | n/a (includes load) |

## Index size

| Section | Bytes |
| --- | --- |
| roots | 64 |
| names | 4,152,583 |
| folders | 7,852,164 |
| files | 55,420,482 |
| order | 9,450,012 |
| dict | 3,200,612 |
| ranges | 56,700,086 |
| postings | 37,289,559 |
| checksum | 8 |
| **total** | **174,065,814** |

Base (names + entry records): 64.3 MiB. Index extra: 101.7 MiB of the base (1.58×; plan budget 1.5×). Total / base: 2.58×.

## Notes

- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.
- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.
- `report pdf` has no matches in this tree; it still measures two independent trigram groups.
- `dm:lastweek` resolves against the local time zone at run time.
- Re-run with `--rebuild-index` to regenerate the database and the build row.
