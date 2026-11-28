# moonsearch benchmark results

Generated: `2026-11-28T07:00:16+00:00`

## Dataset

| Field | Value |
| --- | --- |
| Label | `synthetic-1m` |
| Roots | `bench/.data/synthetic-1m` |
| Entries | 1,030,056 |
| Folders / files | 103,006 / 927,050 |
| Names (unique) | 145,930 |
| Database | 105.1 MiB |
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
| Scan + build + write | 92.7 s (90 s at 1M) | 28.0 s | PASS |
| Build peak RSS (information) | n/a | 681.4 MiB | n/a |

Build statistics from `index --stats`:

- `scan_ms`: 25717
- `database_bytes`: 110179928
- `names`: 1030056
- `name_bytes`: 13807267
- `extensions`: 11
- `hidden`: 916
- `ranges`: size=1030056 mtime=1030056 depth=1030056 childcount=103006 parent=1030055
- `trigram`: 872 keys, 11745410 postings, 0 short names, 2 stop-grams, 46981640 B

## Database load

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Read MSDB into memory | 824 ms (800 ms at 1M) | 176 ms | PASS |
| Query-time peak RSS | 400 MiB at 1M | 332.2 MiB | PASS |

## Engine latency

Engine numbers come from `moonsearch-bench`: one database load, then `moonsearch/core/bench` samples the query path in-process with a monotonic clock. The median is shown; the raw JSON has min/max/mean.

| Query | Target | Bitmap median | Scan median | Matches | Status |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | 1 ms | 39.4 µs | 41.80 ms | 927 | PASS |
| `ext:jpg size:>1mb` | 5 ms | 66.5 µs | 49.36 ms | 3 | PASS |
| `ext:jpg size:>1mb dm:lastweek` | 8 ms | 79.9 µs | 57.91 ms | 0 | PASS |
| `report` | 20 ms | 2.05 ms | 44.69 ms | 30,805 | PASS |
| `report pdf` | 40 ms | 2.18 ms | 47.62 ms | 930 | PASS |
| `*.pdf` | 120 ms | 75.66 ms | 69.45 ms | 930 | PASS |
| `source map` | 40 ms | 9.82 ms | 47.51 ms | 2,111 | PASS |
| `count ext:mp4` | 1.0 ms | 38.8 µs | n/a | 925 | PASS |
| empty query, `-n 20` | 1.0 ms | 37.1 µs | 36.7 µs | 1,030,056 | PASS |

## CLI wall time

Each CLI invocation loads the database and formats results, so this column is the user-visible cost, not the engine cost above. Median of 3 runs after one warm-up.

| Command | Target (engine) | Median wall | Min wall | Status |
| --- | --- | --- | --- | --- |
| `search 'ext:jpg'` | 1.0 ms | 209.9 ms | 206.0 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 199.5 ms | 195.6 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 185.1 ms | 184.1 ms | n/a (includes load) |
| `search 'report'` | 20.0 ms | 218.7 ms | 217.4 ms | n/a (includes load) |
| `search 'report pdf'` | 40.0 ms | 213.0 ms | 211.3 ms | n/a (includes load) |
| `search '*.pdf'` | 120.0 ms | 292.7 ms | 286.5 ms | n/a (includes load) |
| `search 'source map'` | 40.0 ms | 227.1 ms | 222.8 ms | n/a (includes load) |
| `count 'ext:mp4'` | 1.0 ms | 196.4 ms | 194.2 ms | n/a (includes load) |
| `search -n 20 ''` | 1.0 ms | 203.0 ms | 195.8 ms | n/a (includes load) |

## Index size

| Section | Bytes |
| --- | --- |
| roots | 111 |
| names | 949,203 |
| folders | 3,502,204 |
| files | 24,103,300 |
| order | 4,120,224 |
| dict | 1,495,802 |
| ranges | 50,678,777 |
| postings | 11,890,699 |
| checksum | 8 |
| **total** | **110,179,928** |

Base (names + entry records): 27.2 MiB. Index extra: 77.8 MiB of the base (2.86×; plan budget 1.5×). Total / base: 3.86×.

## Notes

- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.
- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.
- `report pdf` has no matches in this tree; it still measures two independent trigram groups.
- `dm:lastweek` resolves against the local time zone at run time.
- Re-run with `--rebuild-index` to regenerate the database and the build row.
