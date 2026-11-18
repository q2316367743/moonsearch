# moonsearch benchmark results

Generated: `2026-11-18T04:50:08+00:00`

## Dataset

| Field | Value |
| --- | --- |
| Label | `workspace-1m` |
| Roots | `~/Documents/workspace/app`<br>`~/Documents/workspace/dashou-plugin`<br>`~/Documents/workspace/plugin` |
| Entries | 1,219,537 |
| Folders / files | 113,665 / 1,105,872 |
| Names (unique) | 169,415 |
| Database | 86.7 MiB |
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
| Scan + build + write | 109.8 s (90 s at 1M) | 75.4 s | PASS |
| Build peak RSS (information) | n/a | 776.3 MiB | n/a |

Build statistics from `index --stats`:

- `scan_ms`: 73937
- `database_bytes`: 90950983
- `names`: 1219537
- `name_bytes`: 19157482
- `extensions`: 220
- `hidden`: 4813
- `ranges`: size=1219537 mtime=1219537
- `trigram`: 41567 keys, 16634757 postings, 7786 short names, 4 stop-grams, 66539028 B

## Database load

| Metric | Target | Measured | Status |
| --- | --- | --- | --- |
| Read MSDB into memory | 976 ms (800 ms at 1M) | 1136 ms | MISS |
| Query-time peak RSS | 400 MiB at 1M | 361.9 MiB | PASS |

## Engine latency

Engine numbers come from `moonsearch-bench`: one database load, then `moonsearch/core/bench` samples the query path in-process with a monotonic clock. The median is shown; the raw JSON has min/max/mean.

| Query | Target | Bitmap median | Scan median | Matches | Status |
| --- | --- | --- | --- | --- | --- |
| `ext:jpg` | 1 ms | 34.1 µs | 46.24 ms | 99 | PASS |
| `ext:jpg size:>1mb` | 5 ms | 309.2 µs | 48.88 ms | 2 | PASS |
| `ext:jpg size:>1mb dm:lastweek` | 8 ms | 4.41 ms | 54.11 ms | 0 | PASS |
| `report` | 20 ms | 76.6 µs | 65.13 ms | 726 | PASS |
| `report pdf` | 40 ms | 183.3 µs | 68.92 ms | 0 | PASS |
| `*.pdf` | 120 ms | 72.29 ms | 92.67 ms | 6 | PASS |
| `source map` | 40 ms | 16.24 ms | 70.93 ms | 2,941 | PASS |
| `count ext:mp4` | 1.0 ms | 34.0 µs | n/a | 5 | PASS |
| empty query, `-n 20` | 1.0 ms | 33.4 µs | 33.8 µs | 1,219,537 | PASS |

## CLI wall time

Each CLI invocation loads the database and formats results, so this column is the user-visible cost, not the engine cost above. Median of 3 runs after one warm-up.

| Command | Target (engine) | Median wall | Min wall | Status |
| --- | --- | --- | --- | --- |
| `search 'ext:jpg'` | 1.0 ms | 1162.4 ms | 1154.3 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb'` | 5.0 ms | 1157.2 ms | 1155.5 ms | n/a (includes load) |
| `search 'ext:jpg size:>1mb dm:lastweek'` | 8.0 ms | 1153.5 ms | 1150.8 ms | n/a (includes load) |
| `search 'report'` | 20.0 ms | 1199.8 ms | 1197.4 ms | n/a (includes load) |
| `search 'report pdf'` | 40.0 ms | 1112.5 ms | 1078.2 ms | n/a (includes load) |
| `search '*.pdf'` | 120.0 ms | 1162.1 ms | 1157.5 ms | n/a (includes load) |
| `search 'source map'` | 40.0 ms | 1124.2 ms | 1123.3 ms | n/a (includes load) |
| `count 'ext:mp4'` | 1.0 ms | 1096.1 ms | 1073.6 ms | n/a (includes load) |
| `search -n 20 ''` | 1.0 ms | 1085.8 ms | 1082.6 ms | n/a (includes load) |

## Index size

| Section | Bytes |
| --- | --- |
| roots | 209 |
| names | 2,592,055 |
| folders | 3,864,610 |
| files | 28,752,672 |
| order | 4,878,148 |
| dict | 1,730,103 |
| ranges | 29,268,902 |
| postings | 19,864,032 |
| checksum | 8 |
| **total** | **90,950,983** |

Base (names + entry records): 33.6 MiB. Index extra: 53.2 MiB of the base (1.58×; plan budget 1.5×). Total / base: 2.58×.

## Notes

- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.
- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.
- `report pdf` has no matches in this tree; it still measures two independent trigram groups.
- `dm:lastweek` resolves against the local time zone at run time.
- Re-run with `--rebuild-index` to regenerate the database and the build row.
