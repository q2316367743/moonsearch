# moonsearch benchmark results

Generated: `2026-11-28T07:19:30+00:00`

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
| commit | fb47a98 |

## Index build

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Scan + build + write | 92.7 s (90 s at 1M) | 28.4 s | PASS |
| Build peak RSS (information) | n/a | 681.3 MiB | n/a |

Build statistics from `index --stats`:

- `scan_ms`: 26340
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
| Read MSDB into memory | 824 ms (800 ms at 1M) | 183 ms | PASS |
| Query-time peak RSS | 400 MiB at 1M | 332.4 MiB | PASS |

## Engine latency

Engine numbers come from `moonsearch-bench`: one database load, then `moonsearch/core/bench` samples the query path in-process with a monotonic clock. The median is shown; the raw JSON has min/max/mean.

| Query | Target | Bitmap median | Scan median | Matches | Status |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | 1 ms | 36.2 µs | 41.45 ms | 927 | PASS |
| `ext:jpg size:>1mb` | 5 ms | 66.4 µs | 48.56 ms | 3 | PASS |
| `ext:jpg size:>1mb dm:lastweek` | 8 ms | 76.8 µs | 55.66 ms | 0 | PASS |
| `report` | 20 ms | 1.96 ms | 43.88 ms | 30,805 | PASS |
| `report pdf` | 40 ms | 2.02 ms | 46.41 ms | 930 | PASS |
| `*.pdf` | 120 ms | 72.71 ms | 67.79 ms | 930 | PASS |
| `source map` | 40 ms | 9.11 ms | 46.21 ms | 2,111 | PASS |
| `count ext:mp4` | 1.0 ms | 36.6 µs | n/a | 925 | PASS |
| empty query, `-n 20` | 1.0 ms | 36.4 µs | 35.8 µs | 1,030,056 | PASS |

## CLI wall time

Each CLI invocation loads the database and formats results, so this column is the user-visible cost, not the engine cost above. Median of 3 runs after one warm-up.

| Command | Target (engine) | Median wall | Min wall | Status |
| --- | --- | --- | --- | --- |
| `search 'ext:jpg'` | 1.0 ms | 201.9 ms | 201.4 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 192.2 ms | 190.8 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 175.3 ms | 174.6 ms | n/a (includes load) |
| `search 'report'` | 20.0 ms | 210.6 ms | 208.7 ms | n/a (includes load) |
| `search 'report pdf'` | 40.0 ms | 207.6 ms | 203.1 ms | n/a (includes load) |
| `search '*.pdf'` | 120.0 ms | 270.9 ms | 270.4 ms | n/a (includes load) |
| `search 'source map'` | 40.0 ms | 219.2 ms | 212.0 ms | n/a (includes load) |
| `count 'ext:mp4'` | 1.0 ms | 191.2 ms | 187.5 ms | n/a (includes load) |
| `search -n 20 ''` | 1.0 ms | 189.0 ms | 187.5 ms | n/a (includes load) |

## Index size

| Section | Bytes |
| --- | --- |
| roots | 111 |
| excludes | 4 |
| names | 949,203 |
| folders | 3,502,204 |
| files | 24,103,300 |
| order | 4,120,224 |
| dict | 1,495,802 |
| ranges | 50,678,777 |
| parent-paths | 13,439,312 |
| postings | 11,890,699 |
| checksum | 8 |
| **total** | **110,179,928** |

RANGES breakdown (5 B field header + 12 B per `(value, id)` pair):

| Field | Entries | Bytes |
| --- | ---: | ---: |
| size | 1,030,056 | 12,360,677 |
| mtime | 1,030,056 | 12,360,677 |
| depth | 1,030,056 | 12,360,677 |
| childcount | 103,006 | 1,236,077 |
| parent | 1,030,055 | 12,360,665 |
| field count | — | 4 |

Base (names + entry records): 27.2 MiB. Index extra: 77.8 MiB of the base (2.86×; plan budget 1.5×). Total / base: 3.86×.

## Notes

- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.
- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.
- `report pdf` has no matches in this tree; it still measures two independent trigram groups.
- `dm:lastweek` resolves against the local time zone at run time.
- Re-run with `--rebuild-index` to regenerate the database and the build row.
