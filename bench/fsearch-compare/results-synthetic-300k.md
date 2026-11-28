# Same-condition query benchmark: synthetic-300k

Dataset: 30000 folders + 270000 files = 300000 entries.  FSearch worker threads: 1.  FSearch build: 3556.5 ms.  moonsearch load: 59.9 ms (bitmap).

`bitmap` is set production (count path).  `bitmap full` additionally walks canonical order and materializes every hit, matching the shape of a full search result.  FSearch numbers are its full search path.  Ratios are A/B; a value above 1 means A is slower than B.

| query | hits | FSearch 1T | scan | bitmap (count) | bitmap (full) | FSearch/full | FSearch/scan | scan/full |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `` | 300000 | 0.570 | 4.716 | 0.036 | 0.732 | 0.78x | 0.12x | 6.44x |
| `ext:jpg` | 269 | 11.243 | 12.376 | 0.037 | 2.729 | 4.12x | 0.91x | 4.54x |
| `ext:jpg size:>1mb` | 0 | 13.061 | 14.634 | 0.045 | 0.453 | 28.80x | 0.89x | 32.27x |
| `ext:jpg size:>1mb dm:lastweek` | 0 | 8.677 | 17.088 | 0.049 | 0.459 | 18.89x | 0.51x | 37.21x |
| `report` | 8972 | 19.713 | 13.618 | 0.684 | 1.402 | 14.06x | 1.45x | 9.71x |
| `report pdf` | 271 | 20.251 | 14.354 | 0.703 | 3.575 | 5.66x | 1.41x | 4.01x |
| `source map` | 614 | 21.489 | 14.298 | 2.774 | 6.441 | 3.34x | 1.50x | 2.22x |
| `*.pdf` | 271 | 13.114 | 20.497 | 22.061 | 25.021 | 0.52x | 0.64x | 0.82x |
| `a` | 119812 | 16.780 | 13.510 | 15.695 | 17.853 | 0.94x | 1.24x | 0.76x |
| `ab` | 0 | 19.912 | 14.297 | 16.723 | 16.584 | 1.20x | 1.39x | 0.86x |
| `the` | 8710 | 22.275 | 14.102 | 0.645 | 1.477 | 15.08x | 1.58x | 9.55x |
| `index` | 8710 | 20.571 | 13.566 | 0.707 | 1.606 | 12.81x | 1.52x | 8.45x |
| `node_modules` | 3750 | 19.313 | 12.381 | 0.239 | 4.300 | 4.49x | 1.56x | 2.88x |
| `package.json` | 0 | 19.688 | 12.538 | 0.039 | 0.452 | 43.58x | 1.57x | 27.75x |
| `size:>1kb` | 283530 | 10.174 | 6.684 | 15.553 | 16.270 | 0.63x | 1.52x | 0.41x |
| `size:>1mb` | 551 | 7.812 | 6.300 | 0.043 | 2.947 | 2.65x | 1.24x | 2.14x |
| `ext:jpg OR ext:png` ! | 13737 | 17.762 | 16.437 | 0.059 | 4.732 | 3.75x | 1.08x | 3.47x |
| `case:Report` | 0 | 14.297 | 14.034 | 0.611 | 1.072 | 13.33x | 1.02x | 13.09x |
| `exact:report` | 0 | 8.753 | 11.725 | 0.570 | 1.002 | 8.74x | 0.75x | 11.70x |
| `regex:^report.*\.pdf$` | 270 | 12.651 | 20.585 | 21.996 | 25.200 | 0.50x | 0.61x | 0.82x |
| `path:src` | 150760 | 104.947 | 124.300 | 125.151 | 127.855 | 0.82x | 0.84x | 0.97x |
| `folder:src` | 3751 | 6.956 | 11.356 | 0.216 | 4.180 | 1.66x | 0.61x | 2.72x |
| `depth:>5` | 227871 | 13.483 | 16.441 | 1.345 | 1.968 | 6.85x | 0.82x | 8.35x |
| `dm:lastweek` ! | 0 | 8.495 | 6.412 | 0.041 | 2.741 | 3.10x | 1.32x | 2.34x |
| `dm:thisyear` | 233916 | 11.080 | 7.046 | 9.939 | 11.148 | 0.99x | 1.57x | 0.63x |
| `dm:thismonth` | 268 | 12.716 | 6.375 | 0.041 | 2.836 | 4.48x | 1.99x | 2.25x |
| `size:>1000000` | 551 | 8.297 | 6.297 | 0.045 | 2.962 | 2.80x | 1.32x | 2.13x |
| `file:size:>1000` | 253530 | 10.901 | 6.734 | 15.634 | 16.462 | 0.66x | 1.62x | 0.41x |
| `ing` | 0 | 21.078 | 14.114 | 0.036 | 0.448 | 47.07x | 1.49x | 31.52x |
| `ion` | 1 | 20.331 | 14.082 | 0.037 | 0.616 | 32.98x | 1.44x | 22.85x |
| `ent` | 17419 | 18.114 | 14.895 | 1.134 | 2.121 | 8.54x | 1.22x | 7.02x |
| `com` | 8710 | 18.596 | 14.036 | 0.614 | 1.472 | 12.63x | 1.32x | 9.53x |
| `.js` | 54138 | 20.454 | 14.349 | 4.467 | 5.347 | 3.83x | 1.43x | 2.68x |
| `.ts` | 13458 | 23.855 | 14.143 | 1.423 | 6.650 | 3.59x | 1.69x | 2.13x |

`!` marks a hit-count mismatch between FSearch and moonsearch.  `ext:jpg OR ext:png`: moonsearch treats a leading dot as making a name extensionless (`.x.png` has an empty `ext:`), while FSearch reports `png`; that accounts for the 14 hidden `.png` files in this tree.  `dm:lastweek`: FSearch resolves `last` as the previous calendar week, moonsearch as the trailing seven days; the 268 files created 0–4 days before the reference time fall inside the latter only.

## Trigram ablation

| query | trigram | no trigram | speedup |
|---|---:|---:|---:|
| `` | 0.036 | 0.039 | 1.1x |
| `ext:jpg` | 0.037 | 0.037 | 1.0x |
| `ext:jpg size:>1mb` | 0.045 | 0.045 | 1.0x |
| `ext:jpg size:>1mb dm:lastweek` | 0.049 | 0.050 | 1.0x |
| `report` | 0.684 | 15.412 | 22.5x |
| `report pdf` | 0.703 | 16.021 | 22.8x |
| `source map` | 2.774 | 18.280 | 6.6x |
| `*.pdf` | 22.061 | 22.234 | 1.0x |
| `a` | 15.695 | 16.919 | 1.1x |
| `ab` | 16.723 | 16.339 | 1.0x |
| `the` | 0.645 | 16.290 | 25.2x |
| `index` | 0.707 | 15.458 | 21.9x |
| `node_modules` | 0.239 | 14.321 | 60.0x |
| `package.json` | 0.039 | 14.381 | 369.4x |
| `size:>1kb` | 15.553 | 15.857 | 1.0x |
| `size:>1mb` | 0.043 | 0.044 | 1.0x |
| `ext:jpg OR ext:png` | 0.059 | 0.059 | 1.0x |
| `case:Report` | 0.611 | 14.791 | 24.2x |
| `exact:report` | 0.570 | 13.489 | 23.7x |
| `regex:^report.*\.pdf$` | 21.996 | 22.244 | 1.0x |
| `path:src` | 125.151 | 136.255 | 1.1x |
| `folder:src` | 0.216 | 13.280 | 61.5x |
| `depth:>5` | 1.345 | 1.284 | 1.0x |
| `dm:lastweek` | 0.041 | 0.041 | 1.0x |
| `dm:thisyear` | 9.939 | 10.073 | 1.0x |
| `dm:thismonth` | 0.041 | 0.042 | 1.0x |
| `size:>1000000` | 0.045 | 0.046 | 1.0x |
| `file:size:>1000` | 15.634 | 15.950 | 1.0x |
| `ing` | 0.036 | 15.955 | 441.5x |
| `ion` | 0.037 | 15.991 | 434.2x |
| `ent` | 1.134 | 16.020 | 14.1x |
| `com` | 0.614 | 16.080 | 26.2x |
| `.js` | 4.467 | 18.271 | 4.1x |
| `.ts` | 1.423 | 16.455 | 11.6x |

