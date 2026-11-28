# Same-condition query benchmark: small-2272

Dataset: 593 folders + 1679 files = 2272 entries.  FSearch worker threads: 1.  FSearch build: 23.9 ms.  moonsearch load: 1.9 ms (bitmap).

`bitmap` is set production (count path).  `bitmap full` additionally walks canonical order and materializes every hit, matching the shape of a full search result.  FSearch numbers are its full search path.  Ratios are A/B; a value above 1 means A is slower than B.

| query | hits | FSearch 1T | scan | bitmap (count) | bitmap (full) | FSearch/full | FSearch/scan | scan/full |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `` | 2272 | 0.002 | 0.044 | 0.034 | — | — | 0.05x | — |
| `ext:mbt` | 402 | 0.055 | 0.081 | 0.039 | — | — | 0.68x | — |
| `ext:json` | 40 | 0.055 | 0.076 | 0.038 | — | — | 0.72x | — |
| `report` | 0 | 0.084 | 0.090 | 0.035 | — | — | 0.93x | — |
| `*.md` | 43 | 0.088 | 0.119 | 0.128 | — | — | 0.74x | — |
| `a` | 1307 | 0.064 | 0.077 | 0.089 | — | — | 0.83x | — |
| `size:>1kb` | 1719 | 0.042 | 0.067 | 0.081 | — | — | 0.62x | — |
| `dm:thisyear` | 2272 | 0.040 | 0.066 | 0.096 | — | — | 0.61x | — |

`!` marks a hit-count mismatch between FSearch and moonsearch.  FSearch adds symlink `st_size` to folder subtree sums, while moonsearch indexes symlinks as 0-byte files; `file:`-qualified size queries match exactly.

