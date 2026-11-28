# Same-condition query benchmark: plugin-297k

Dataset: 25424 folders + 272171 files = 297595 entries.  FSearch worker threads: 1.  FSearch build: 6850.0 ms.  moonsearch load: 263.4 ms (bitmap).

`bitmap` is set production (count path).  `bitmap full` additionally walks canonical order and materializes every hit, matching the shape of a full search result.  FSearch numbers are its full search path.  Ratios are A/B; a value above 1 means A is slower than B.

| query | hits | FSearch 1T | scan | bitmap (count) | bitmap (full) | FSearch/full | FSearch/scan | scan/full |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `` | 297595 | 0.136 | 1.011 | 0.036 | 0.726 | 0.19x | 0.13x | 1.39x |
| `ext:jpg` | 9 | 8.581 | 7.060 | 0.037 | 1.030 | 8.33x | 1.22x | 6.85x |
| `ext:jpg size:>1mb` | 2 | 8.085 | 7.488 | 0.058 | 0.627 | 12.90x | 1.08x | 11.95x |
| `ext:jpg size:>1mb dm:lastweek` | 0 | 9.362 | 8.272 | 0.061 | 0.378 | 24.75x | 1.13x | 21.87x |
| `report` | 192 | 14.403 | 10.343 | 0.049 | 2.730 | 5.28x | 1.39x | 3.79x |
| `report pdf` | 0 | 16.327 | 11.433 | 0.054 | 0.371 | 44.02x | 1.43x | 30.83x |
| `source map` | 450 | 15.995 | 11.051 | 3.741 | 6.874 | 2.33x | 1.45x | 1.61x |
| `*.pdf` | 0 | 13.866 | 17.558 | 14.415 | 14.757 | 0.94x | 0.79x | 1.19x |
| `a` | 172894 | 10.110 | 9.709 | 10.942 | 11.841 | 0.85x | 1.04x | 0.82x |
| `ab` | 6088 | 13.090 | 12.112 | 14.883 | 20.245 | 0.65x | 1.08x | 0.60x |
| `the` | 701 | 15.173 | 11.609 | 0.061 | 4.082 | 3.72x | 1.31x | 2.84x |
| `index` | 18139 | 13.904 | 11.829 | 1.071 | 5.062 | 2.75x | 1.18x | 2.34x |
| `node_modules` | 2450 | 12.404 | 8.700 | 0.099 | 3.965 | 3.13x | 1.43x | 2.19x |
| `package.json` | 2528 | 12.756 | 8.648 | 0.131 | 4.984 | 2.56x | 1.47x | 1.74x |
| `size:>1kb` ! | 201582 | 6.729 | 5.699 | 10.454 | 11.470 | 0.59x | 1.18x | 0.50x |
| `size:>1mb` | 1552 | 6.875 | 4.516 | 0.056 | 4.480 | 1.53x | 1.52x | 1.01x |
| `ext:jpg OR ext:png` | 169 | 10.529 | 11.715 | 0.040 | 2.481 | 4.24x | 0.90x | 4.72x |
| `case:Report` | 6 | 12.871 | 8.662 | 0.046 | 0.805 | 15.98x | 1.49x | 10.76x |
| `exact:report` | 0 | 5.062 | 7.571 | 0.045 | 0.357 | 14.19x | 0.67x | 21.22x |
| `regex:^report.*\.pdf$` | 0 | 9.934 | 19.496 | 18.547 | 18.900 | 0.53x | 0.51x | 1.03x |
| `path:src` | 14367 | 80.982 | 140.808 | 123.016 | 127.574 | 0.63x | 0.58x | 1.10x |
| `folder:src` | 480 | 5.528 | 1.646 | 0.051 | 2.436 | 2.27x | 3.36x | 0.68x |
| `depth:>5` | 270916 | 9.989 | 10.638 | 5.221 | 5.974 | 1.67x | 0.94x | 1.78x |
| `dm:lastweek` | 0 | 5.487 | 5.630 | 0.038 | 0.349 | 15.70x | 0.97x | 16.11x |
| `dm:thisyear` | 297536 | 7.334 | 5.692 | 7.760 | 8.497 | 0.86x | 1.29x | 0.67x |
| `dm:thismonth` | 16659 | 6.440 | 5.717 | 0.480 | 3.246 | 1.98x | 1.13x | 1.76x |
| `size:>1000000` | 1552 | 7.254 | 5.225 | 0.053 | 4.488 | 1.62x | 1.39x | 1.16x |
| `file:size:>1000` | 179570 | 7.389 | 5.674 | 10.451 | 11.552 | 0.64x | 1.30x | 0.49x |
| `ing` | 8151 | 13.606 | 11.594 | 0.603 | — | — | 1.17x | — |
| `ion` | 12530 | 14.139 | 11.848 | 0.999 | — | — | 1.19x | — |
| `ent` | 10463 | 14.081 | 12.280 | 0.792 | — | — | 1.15x | — |
| `com` | 5780 | 14.632 | 11.267 | 0.359 | — | — | 1.30x | — |
| `.js` | 142693 | 13.361 | 11.812 | 12.379 | — | — | 1.13x | — |
| `.ts` | 76182 | 14.989 | 11.824 | 12.465 | — | — | 1.27x | — |

`!` marks a hit-count mismatch between FSearch and moonsearch.  FSearch adds symlink `st_size` to folder subtree sums, while moonsearch indexes symlinks as 0-byte files; `file:`-qualified size queries match exactly.

## Trigram ablation

| query | trigram | no trigram | speedup |
|---|---:|---:|---:|
| `ext:jpg` | 0.037 | 0.035 | 0.9x |
| `report` | 0.049 | 12.970 | 263.2x |
| `source map` | 3.741 | 15.666 | 4.2x |
| `*.pdf` | 14.415 | 14.494 | 1.0x |
| `the` | 0.061 | 13.977 | 227.9x |
| `index` | 1.071 | 13.519 | 12.6x |
| `node_modules` | 0.099 | 9.770 | 98.6x |
| `package.json` | 0.131 | 9.515 | 72.5x |

