#!/usr/bin/env python3
"""Merge FSearch and moonsearch benchmark output into one comparison table.

Inputs are the TSV streams produced by ``bench_fsearch`` and
``moonsearch-bench``.  Each input flag may be repeated; later files override
earlier entries for the same query (used for the "extra" runs).

Example:

    python3 bench/fsearch-compare/compare.py \
      --fsearch bench/fsearch-compare/results/fsearch-plugin-st.tsv \
      --fsearch bench/fsearch-compare/results/fsearch-plugin-extra.tsv \
      --fsearch bench/fsearch-compare/results/fsearch-common.tsv \
      --fsearch bench/fsearch-compare/results/fsearch-stopgram.tsv \
      --scan bench/fsearch-compare/results/scan.tsv \
      --scan bench/fsearch-compare/results/scan-extra.tsv \
      --scan bench/fsearch-compare/results/scan-common.tsv \
      --scan bench/fsearch-compare/results/scan-stopgram.tsv \
      --bitmap bench/fsearch-compare/results/bitmap.tsv \
      --bitmap bench/fsearch-compare/results/bitmap-extra.tsv \
      --bitmap bench/fsearch-compare/results/bitmap-common.tsv \
      --bitmap bench/fsearch-compare/results/bitmap-stopgram.tsv \
      --bitmap-full bench/fsearch-compare/results/bitmap-fullwalk-all.tsv \
      --no-trigram bench/fsearch-compare/results/bitmap-notrigram.tsv \
      --label plugin-297k \
      --markdown bench/fsearch-compare/results-plugin.md \
      --json bench/fsearch-compare/results-plugin.json
"""

import argparse
import json
import statistics
import sys


def parse_tsv(paths):
    """Parse one or more TSV files.

    Returns (meta, rows) where rows maps query -> {ms, matches}.  medians from
    FSearch are already computed by the driver; moonsearch rows carry a JSON
    array in the last column.
    """
    meta = {}
    rows = {}
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                kind = parts[0]
                if kind == "META" and not meta:
                    meta = {
                        "backend": parts[1],
                        "folders": int(parts[2]),
                        "files": int(parts[3]),
                        "build_ms": float(parts[4]),
                        "roots": int(parts[5]),
                    }
                    if len(parts) > 6:
                        meta["threads"] = int(parts[6])
                elif kind == "QUERY":
                    rows[parts[2]] = {"ms": float(parts[4]), "matches": int(parts[7])}
                elif kind == "LOAD":
                    if "load_ms" not in meta:
                        meta["entries"] = int(parts[1])
                        meta["load_ms"] = float(parts[2]) / 1000.0
                elif kind == "BENCH":
                    summary = json.loads(parts[3])[0]
                    rows[summary["name"]] = {
                        "ms": summary["median"] / 1000.0,
                        "matches": int(parts[2]),
                    }
    return meta, rows


def fmt(value, digits=3):
    return ("%%.%df" % digits) % value


def ratio(a, b):
    return a / b if b else float("inf")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fsearch", action="append", default=[])
    parser.add_argument("--scan", action="append", default=[])
    parser.add_argument("--bitmap", action="append", default=[])
    parser.add_argument("--bitmap-full", action="append", default=[])
    parser.add_argument("--no-trigram", action="append", default=[])
    parser.add_argument("--label", default="benchmark")
    parser.add_argument(
        "--mismatch-note",
        default=(
            "Causes of hit-count differences are dataset-specific and are "
            "documented next to the published table."
        ),
        help="text explaining the '!' hit-count mismatches",
    )
    parser.add_argument("--markdown")
    parser.add_argument("--json")
    args = parser.parse_args()

    fsearch_meta, fsearch = parse_tsv(args.fsearch)
    scan_meta, scan = parse_tsv(args.scan)
    bitmap_meta, bitmap = parse_tsv(args.bitmap)
    full_meta, full = parse_tsv(args.bitmap_full)
    notrig_meta, notrig = parse_tsv(args.no_trigram)

    queries = list(fsearch.keys())
    for query in bitmap.keys():
        if query not in queries:
            queries.append(query)

    rows = []
    for query in queries:
        if query not in fsearch or query not in scan or query not in bitmap:
            continue
        f = fsearch[query]
        s = scan[query]
        b = bitmap[query]
        fw = full.get(query)
        rows.append({
            "query": query,
            "matches": f["matches"],
            "matches_consistent": f["matches"] == s["matches"] == b["matches"],
            "fsearch_ms": f["ms"],
            "scan_ms": s["ms"],
            "bitmap_ms": b["ms"],
            "bitmap_full_ms": fw["ms"] if fw else None,
            "no_trigram_ms": notrig[query]["ms"] if query in notrig else None,
        })

    lines = []
    lines.append("# Same-condition query benchmark: %s" % args.label)
    lines.append("")
    lines.append("Dataset: %d folders + %d files = %d entries.  "
                 "FSearch worker threads: %s.  FSearch build: %.1f ms.  "
                 "moonsearch load: %.1f ms (bitmap)." % (
                     fsearch_meta.get("folders", 0),
                     fsearch_meta.get("files", 0),
                     fsearch_meta.get("folders", 0) + fsearch_meta.get("files", 0),
                     fsearch_meta.get("threads", "?"),
                     fsearch_meta.get("build_ms", 0.0),
                     bitmap_meta.get("load_ms", 0.0),
                 ))
    lines.append("")
    lines.append("`bitmap` is set production (count path).  `bitmap full` additionally walks "
                 "canonical order and materializes every hit, matching the shape of a full "
                 "search result.  FSearch numbers are its full search path.  Ratios are "
                 "A/B; a value above 1 means A is slower than B.")
    lines.append("")
    lines.append("| query | hits | FSearch 1T | scan | bitmap (count) | bitmap (full) | "
                 "FSearch/full | FSearch/scan | scan/full |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for row in rows:
        mark = "" if row["matches_consistent"] else " !"
        full_ms = row["bitmap_full_ms"]
        full_cell = fmt(full_ms) if full_ms is not None else "—"
        ratio_cell = "%.2fx" % ratio(row["fsearch_ms"], full_ms) if full_ms else "—"
        lines.append("| `%s`%s | %d | %s | %s | %s | %s | %s | %.2fx | %s |" % (
            row["query"], mark, row["matches"], fmt(row["fsearch_ms"]),
            fmt(row["scan_ms"]), fmt(row["bitmap_ms"]), full_cell,
            ratio_cell,
            ratio(row["fsearch_ms"], row["scan_ms"]),
            "%.2fx" % ratio(row["scan_ms"], full_ms) if full_ms else "—",
        ))
    lines.append("")
    lines.append("`!` marks a hit-count mismatch between FSearch and moonsearch.  "
                 + args.mismatch_note)
    lines.append("")

    if any(row["no_trigram_ms"] for row in rows):
        lines.append("## Trigram ablation")
        lines.append("")
        lines.append("| query | trigram | no trigram | speedup |")
        lines.append("|---|---:|---:|---:|")
        for row in rows:
            if row["no_trigram_ms"]:
                lines.append("| `%s` | %s | %s | %.1fx |" % (
                    row["query"], fmt(row["bitmap_ms"]),
                    fmt(row["no_trigram_ms"]),
                    ratio(row["no_trigram_ms"], row["bitmap_ms"]),
                ))
        lines.append("")

    markdown = "\n".join(lines) + "\n"
    if args.markdown:
        with open(args.markdown, "w", encoding="utf-8") as handle:
            handle.write(markdown)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump({
                "label": args.label,
                "fsearch_meta": fsearch_meta,
                "scan_meta": scan_meta,
                "bitmap_meta": bitmap_meta,
                "full_meta": full_meta,
                "no_trigram_meta": notrig_meta,
                "rows": rows,
            }, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
    sys.stdout.write(markdown)


if __name__ == "__main__":
    main()
