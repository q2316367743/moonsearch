# Same-condition query benchmark: synthetic-300k

Dataset: 30000 folders + 270000 files = 300000 entries.  FSearch worker threads: 1.  FSearch build: 3871.2 ms.  moonsearch load: 55.3 ms (bitmap).

`bitmap` is set production (count path).  `bitmap full` additionally walks canonical order and materializes every hit, matching the shape of a full search result.  FSearch numbers are its full search path.  Ratios are A/B; a value above 1 means A is slower than B.

| query | hits | FSearch 1T | scan | bitmap (count) | bitmap (full) | FSearch/full | FSearch/scan | scan/full |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `` | 300000 | 0.439 | 4.353 | 0.032 | 0.695 | 0.63x | 0.10x | 6.26x |
| `ext:jpg` | 269 | 5.663 | 11.987 | 0.034 | 2.627 | 2.16x | 0.47x | 4.56x |
| `ext:jpg size:>1mb` | 0 | 5.610 | 14.085 | 0.041 | 0.436 | 12.86x | 0.40x | 32.28x |
| `ext:jpg size:>1mb dm:lastweek` | 0 | 6.757 | 16.154 | 0.044 | 0.441 | 15.33x | 0.42x | 36.65x |
| `report` | 8972 | 7.148 | 12.705 | 0.660 | 1.347 | 5.31x | 0.56x | 9.43x |
| `report pdf` | 271 | 7.502 | 13.309 | 0.673 | 3.404 | 2.20x | 0.56x | 3.91x |
| `source map` | 614 | 10.556 | 13.354 | 2.439 | 5.849 | 1.80x | 0.79x | 2.28x |
| `*.pdf` | 271 | 6.608 | 19.323 | 21.343 | 24.043 | 0.27x | 0.34x | 0.80x |
| `a` | 119812 | 7.275 | 13.190 | 15.175 | 17.227 | 0.42x | 0.55x | 0.77x |
| `ab` | 0 | 8.331 | 13.784 | 15.398 | 15.956 | 0.52x | 0.60x | 0.86x |
| `the` | 8710 | 11.048 | 13.738 | 0.613 | 1.421 | 7.77x | 0.80x | 9.67x |
| `index` | 8710 | 7.591 | 13.191 | 0.658 | 1.458 | 5.21x | 0.58x | 9.05x |
| `node_modules` | 3750 | 10.214 | 11.997 | 0.231 | 4.022 | 2.54x | 0.85x | 2.98x |
| `package.json` | 0 | 7.593 | 12.076 | 0.035 | 0.430 | 17.66x | 0.63x | 28.08x |
| `size:>1kb` | 283530 | 4.578 | 6.644 | 15.082 | 15.741 | 0.29x | 0.69x | 0.42x |
| `size:>1mb` | 551 | 3.244 | 6.177 | 0.040 | 2.827 | 1.15x | 0.53x | 2.18x |
| `ext:jpg OR ext:png` ! | 13737 | 8.125 | 15.053 | 0.055 | 4.592 | 1.77x | 0.54x | 3.28x |
| `case:Report` | 0 | 5.902 | 12.435 | 0.571 | 0.960 | 6.15x | 0.47x | 12.95x |
| `exact:report` | 0 | 4.251 | 11.243 | 0.542 | 0.933 | 4.55x | 0.38x | 12.05x |
| `regex:^report.*\.pdf$` | 270 | 6.351 | 19.893 | 21.287 | 24.182 | 0.26x | 0.32x | 0.82x |
| `path:src` | 150760 | 66.992 | 104.297 | 105.228 | 105.936 | 0.63x | 0.64x | 0.98x |
| `folder:src` | 3751 | 3.007 | 10.885 | 0.206 | 3.959 | 0.76x | 0.28x | 2.75x |
| `depth:>5` | 227871 | 7.799 | 14.278 | 1.228 | 1.861 | 4.19x | 0.55x | 7.67x |
| `dm:lastweek` ! | 0 | 4.169 | 6.068 | 0.037 | 2.591 | 1.61x | 0.69x | 2.34x |
| `dm:thisyear` | 233916 | 5.099 | 6.758 | 9.456 | 10.064 | 0.51x | 0.75x | 0.67x |
| `dm:thismonth` | 268 | 3.805 | 6.098 | 0.037 | 2.588 | 1.47x | 0.62x | 2.36x |
| `size:>1000000` | 551 | 3.543 | 6.166 | 0.040 | 2.795 | 1.27x | 0.57x | 2.21x |
| `file:size:>1000` | 253530 | 4.858 | 6.776 | 14.882 | 15.666 | 0.31x | 0.72x | 0.43x |
| `ing` | 0 | 10.553 | 13.580 | 0.035 | 0.428 | 24.67x | 0.78x | 31.74x |
| `ion` | 0 | 8.765 | 13.692 | 0.035 | 0.427 | 20.54x | 0.64x | 32.08x |
| `ent` | 17419 | 9.172 | 13.523 | 1.095 | 1.989 | 4.61x | 0.68x | 6.80x |
| `com` | 8710 | 8.989 | 13.598 | 0.586 | 1.399 | 6.43x | 0.66x | 9.72x |
| `.js` | 54138 | 9.560 | 13.832 | 4.097 | 4.823 | 1.98x | 0.69x | 2.87x |
| `.ts` | 13458 | 10.965 | 13.601 | 1.303 | 6.104 | 1.80x | 0.81x | 2.23x |

`!` marks a hit-count mismatch between FSearch and moonsearch.  `ext:jpg OR ext:png`: moonsearch treats a leading dot as making a name extensionless (`.x.png` has an empty `ext:`), while FSearch reports `png`; that accounts for the 14 hidden `.png` files in this tree.  `dm:lastweek`: FSearch resolves `last` as the previous calendar week, moonsearch as the trailing seven days; the 268 files created 0–4 days before the reference time fall inside the latter only.

## Trigram ablation

| query | trigram | no trigram | speedup |
|---|---:|---:|---:|
| `` | 0.032 | 0.033 | 1.0x |
| `ext:jpg` | 0.034 | 0.034 | 1.0x |
| `ext:jpg size:>1mb` | 0.041 | 0.041 | 1.0x |
| `ext:jpg size:>1mb dm:lastweek` | 0.044 | 0.045 | 1.0x |
| `report` | 0.660 | 14.674 | 22.2x |
| `report pdf` | 0.673 | 15.454 | 23.0x |
| `source map` | 2.439 | 17.170 | 7.0x |
| `*.pdf` | 21.343 | 21.339 | 1.0x |
| `a` | 15.175 | 15.404 | 1.0x |
| `ab` | 15.398 | 15.741 | 1.0x |
| `the` | 0.613 | 15.629 | 25.5x |
| `index` | 0.658 | 14.960 | 22.7x |
| `node_modules` | 0.231 | 13.880 | 60.0x |
| `package.json` | 0.035 | 13.751 | 392.8x |
| `size:>1kb` | 15.082 | 15.273 | 1.0x |
| `size:>1mb` | 0.040 | 0.040 | 1.0x |
| `ext:jpg OR ext:png` | 0.055 | 0.054 | 1.0x |
| `case:Report` | 0.571 | 13.987 | 24.5x |
| `exact:report` | 0.542 | 12.756 | 23.5x |
| `regex:^report.*\.pdf$` | 21.287 | 21.302 | 1.0x |
| `path:src` | 105.228 | 104.117 | 1.0x |
| `folder:src` | 0.206 | 12.582 | 61.2x |
| `depth:>5` | 1.228 | 1.205 | 1.0x |
| `dm:lastweek` | 0.037 | 0.037 | 1.0x |
| `dm:thisyear` | 9.456 | 9.492 | 1.0x |
| `dm:thismonth` | 0.037 | 0.038 | 1.0x |
| `size:>1000000` | 0.040 | 0.040 | 1.0x |
| `file:size:>1000` | 14.882 | 15.314 | 1.0x |
| `ing` | 0.035 | 15.216 | 439.2x |
| `ion` | 0.035 | 15.222 | 436.3x |
| `ent` | 1.095 | 15.254 | 13.9x |
| `com` | 0.586 | 15.294 | 26.1x |
| `.js` | 4.097 | 16.031 | 3.9x |
| `.ts` | 1.303 | 15.619 | 12.0x |

