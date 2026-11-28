#!/usr/bin/env python3
"""Repeatable benchmarks for moonsearch.

The harness owns three measurements:

1. index build (wall time and peak RSS, using /usr/bin/time);
2. engine latency (in-process, microsecond resolution, via
   `moonsearch-bench` and moonbitlang/core/bench);
3. end-to-end CLI latency and query-time RSS, via the normal executable.

It writes a Markdown report and a JSON file with the raw numbers. Nothing in
this script reads the clock for correctness decisions; all benchmark seeds and
queries are fixed.

Example:

    python3 bench/run_bench.py \
        --label workspace-1m \
        --root /Users/me/workspace/app \
        --root /Users/me/workspace/plugin \
        --rebuild-index
"""

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Queries from MIGRATION_PLAN.md section 10.1, plus two cases that exercise the
# same shapes on trees that do not contain many media files.
SEARCH_QUERIES = [
    ("ext:jpg", 1.0, "pure dictionary bitmap"),
    ("ext:jpg size:>1mb", 5.0, "bitmap x range"),
    ("ext:jpg size:>1mb dm:lastweek", 8.0, "three sets"),
    ("report", 20.0, "one trigram group"),
    ("report pdf", 40.0, "two trigram groups"),
    ("*.pdf", 120.0, "glob, scan leaf"),
    ("source map", 40.0, "two common trigram groups"),
]
COUNT_QUERIES = [("ext:mp4", 1.0, "popcount")]
FIRST_QUERIES = [("", 20, 1.0, "empty query, first 20 in name order")]

DEFAULT_DATABASE = "bench/.work/bench.msdb"
DEFAULT_BIN = "_build/native/release/build/cmd/moonsearch/moonsearch.exe"
DEFAULT_BENCH_BIN = "_build/native/release/build/cmd/moonsearch-bench/moonsearch-bench.exe"


def run(cmd, *, cwd=None, check=True, timeout=None):
    result = subprocess.run(
        cmd,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
    )
    if check and result.returncode not in (0, 1):
        raise RuntimeError(
            "command failed (%d): %s\n%s" % (result.returncode, " ".join(cmd), result.stderr)
        )
    return result


def run_quiet(cmd, *, cwd=None, timeout=None):
    result = subprocess.run(
        cmd, cwd=cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout
    )
    if result.returncode not in (0, 1):
        raise RuntimeError("command failed (%d): %s" % (result.returncode, " ".join(cmd)))
    return result.returncode


def parse_time_output(stderr):
    """Parse GNU/BSD time output for wall seconds and peak RSS bytes."""
    wall = None
    rss = None
    for line in stderr.splitlines():
        match = re.search(r"([0-9.]+)\s+real", line)
        if match:
            wall = float(match.group(1))
        match = re.search(r"(\d+)\s+maximum resident set size", line)
        if match:
            rss = int(match.group(1))
        match = re.search(r"Elapsed \(wall clock\).*?:\s*([0-9:.]+)", line)
        if match:
            parts = match.group(1).split(":")
            seconds = 0.0
            for part in parts:
                seconds = seconds * 60 + float(part)
            wall = seconds
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", line)
        if match:
            rss = int(match.group(1)) * 1024
    return wall, rss


def timed_command(cmd, *, cwd=None):
    """Run one command under /usr/bin/time and return (returncode, stdout, stderr, wall_s, rss_bytes)."""
    time_bin = shutil.which("time") or "/usr/bin/time"
    time_flag = "-l" if sys.platform == "darwin" else "-v"
    result = subprocess.run(
        [time_bin, time_flag, *cmd],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    wall, rss = parse_time_output(result.stderr)
    return result.returncode, result.stdout, result.stderr, wall, rss


def parse_index_stats(text):
    stats = {}
    for line in text.splitlines():
        if line.startswith("scan: "):
            stats["scan_ms"] = int(line.split()[1])
        elif line.startswith("database: "):
            match = re.search(r"\((\d+) bytes\)", line)
            if match:
                stats["database_bytes"] = int(match.group(1))
        elif line.startswith("names: "):
            match = re.search(r"names: (\d+) names, (\d+) bytes", line)
            if match:
                stats["names"] = int(match.group(1))
                stats["name_bytes"] = int(match.group(2))
        elif line.startswith("dict: "):
            match = re.search(
                r"dict: (\d+) extensions, (\d+) categories, (\d+) hidden", line
            )
            if match:
                stats["extensions"] = int(match.group(1))
                stats["hidden"] = int(match.group(3))
        elif line.startswith("ranges: "):
            stats["ranges"] = line[len("ranges: "):]
        elif line.startswith("trigram: "):
            stats["trigram"] = line[len("trigram: "):]
    return stats


def parse_info(text):
    info = {}
    for line in text.splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            info[key] = value
    sections = {}
    if "sections" in info:
        for part in info["sections"].split():
            if "=" in part:
                name, size = part.split("=", 1)
                try:
                    sections[name] = int(size)
                except ValueError:
                    pass
    info["section_bytes"] = sections
    return info


def measure_wall(cmd, runs, warmup, cwd=None):
    samples = []
    for index in range(warmup + runs):
        started = time.perf_counter_ns()
        run_quiet(cmd, cwd=cwd)
        elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000.0
        if index >= warmup:
            samples.append(elapsed_ms)
    samples.sort()
    return {
        "samples_ms": samples,
        "min_ms": samples[0],
        "median_ms": samples[len(samples) // 2],
        "mean_ms": sum(samples) / len(samples),
    }


def bench_engine(bench_bin, database, engine, mode, queries, runs):
    args = [bench_bin, "--database", database, "--engine", engine, "--runs", str(runs)]
    if mode == "count":
        args.append("--count")
    elif mode == "first":
        args.extend(["--first", str(queries[0][1])])
        queries = [(queries[0][0],)]
    args.extend(query[0] for query in queries)
    result = run(args)
    load = None
    rows = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if parts[0] == "LOAD" and len(parts) == 3:
            load = {
                "entries": int(parts[1]),
                "load_us": float(parts[2]),
            }
        elif parts[0] == "BENCH" and len(parts) == 4:
            summary = json.loads(parts[3])[0]
            rows.append(
                {
                    "engine": parts[1],
                    "matches": int(parts[2]),
                    "query": summary.get("name", ""),
                    "median_us": summary["median"],
                    "mean_us": summary["mean"],
                    "min_us": summary["min"],
                    "max_us": summary["max"],
                    "batch_size": summary["batch_size"],
                    "runs": summary["runs"],
                }
            )
    return load, rows


def format_us(value):
    if value >= 1_000_000:
        return "%.2f s" % (value / 1_000_000.0)
    if value >= 1000:
        return "%.2f ms" % (value / 1000.0)
    return "%.1f µs" % value


def format_bytes(value):
    if value is None:
        return "n/a"
    value = float(value)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return "%.1f %s" % (value, unit)
        value /= 1024.0
    return "%.1f GiB" % value


def status_icon(measured, target, scale=1.0):
    if measured is None:
        return "n/a"
    return "PASS" if measured <= target * scale else "MISS"


def machine_info():
    info = {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "python": platform.python_version(),
    }
    if sys.platform == "darwin":
        for key, command in (
            ("cpu", ["sysctl", "-n", "machdep.cpu.brand_string"]),
            ("memory", ["sysctl", "-n", "hw.memsize"]),
            ("os", ["sw_vers", "-productVersion"]),
        ):
            try:
                info[key] = subprocess.check_output(command, text=True).strip()
            except (OSError, subprocess.CalledProcessError):
                pass
    else:
        info["cpu"] = platform.processor()
    try:
        version = subprocess.check_output(["moon", "version"], text=True).strip()
        info["moon"] = " ".join(version.split())
    except (OSError, subprocess.CalledProcessError):
        pass
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], stderr=subprocess.DEVNULL, text=True
        ).strip()
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain"], stderr=subprocess.DEVNULL, text=True
        ).strip()
        info["commit"] = commit + ("-dirty" if dirty else "")
    except (OSError, subprocess.CalledProcessError):
        pass
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", default="workspace", help="dataset label")
    parser.add_argument("--root", action="append", default=[], help="index root (repeatable)")
    parser.add_argument("--database", default=DEFAULT_DATABASE)
    parser.add_argument("--binary", default=DEFAULT_BIN)
    parser.add_argument("--bench-binary", default=DEFAULT_BENCH_BIN)
    parser.add_argument("--runs", type=int, default=5, help="engine samples per query")
    parser.add_argument("--cli-runs", type=int, default=3, help="CLI samples per query")
    parser.add_argument("--rebuild-index", action="store_true")
    parser.add_argument("--skip-index", action="store_true", help="require an existing database")
    parser.add_argument("--output", default="bench/results.md")
    parser.add_argument("--json-output", default="bench/results.json")
    parser.add_argument("--work-dir", default="bench/.work")
    args = parser.parse_args()

    if not os.path.exists(args.binary):
        raise SystemExit(
            "missing binary %s; run `moon build --target native --release` first" % args.binary
        )
    if not os.path.exists(args.bench_binary):
        raise SystemExit(
            "missing benchmark binary %s; run `moon build --target native --release` first"
            % args.bench_binary
        )
    if args.skip_index and args.rebuild_index:
        raise SystemExit("--skip-index and --rebuild-index cannot be combined")
    if args.skip_index and not os.path.exists(args.database):
        raise SystemExit("--skip-index requires an existing database")
    if not args.root and (args.rebuild_index or not os.path.exists(args.database)):
        raise SystemExit("--root is required to build the database")

    os.makedirs(args.work_dir, exist_ok=True)
    os.makedirs(os.path.dirname(args.database) or ".", exist_ok=True)
    stats_path = os.path.join(args.work_dir, "%s-index.json" % args.label)
    build = None
    if args.rebuild_index:
        for path in (args.database, args.database + ".lock"):
            if os.path.exists(path):
                os.unlink(path)
    if not os.path.exists(args.database):
        print("indexing %d root(s) into %s ..." % (len(args.root), args.database))
        cmd = [args.binary, "-D", args.database, "index", "--stats", *args.root]
        code, stdout, stderr, wall, rss = timed_command(cmd)
        if code not in (0, 1):
            raise SystemExit("index failed (%d):\n%s" % (code, stderr))
        build = {
            "wall_s": wall,
            "peak_rss_bytes": rss,
            "stdout": stdout,
            "stats": parse_index_stats(stderr),
        }
        with open(stats_path, "w") as handle:
            json.dump(build, handle, indent=2)
    else:
        try:
            with open(stats_path) as handle:
                build = json.load(handle)
        except FileNotFoundError:
            build = None

    if build is None:
        # A reused database still has a build time from its metadata; report
        # what we can and leave the build row as n/a.
        build = {"wall_s": None, "peak_rss_bytes": None, "stats": {}}

    db_size = os.path.getsize(args.database)
    info = parse_info(run([args.binary, "-D", args.database, "info"]).stdout)
    entries = int(info.get("folders", 0)) + int(info.get("files", 0))
    print("database: %d entries, %s" % (entries, format_bytes(db_size)))

    # Engine-level benchmarks. One load per engine; the query loops inside the
    # process so process startup and output formatting stay out of the numbers.
    engine_runs = {}
    load_ms = {}
    for engine in ("bitmap", "scan"):
        print("benchmarking %s engine ..." % engine)
        load, rows = bench_engine(
            args.bench_binary, args.database, engine, "search", SEARCH_QUERIES, args.runs
        )
        if load:
            load_ms[engine] = load["load_us"] / 1000.0
        engine_runs[engine] = rows

    count_load, count_rows = bench_engine(
        args.bench_binary, args.database, "bitmap", "count", COUNT_QUERIES, args.runs
    )
    first_load, first_rows = bench_engine(
        args.bench_binary, args.database, "bitmap", "first", FIRST_QUERIES, args.runs
    )
    scan_first_load, scan_first_rows = bench_engine(
        args.bench_binary, args.database, "scan", "first", FIRST_QUERIES, args.runs
    )

    # End-to-end CLI latency, including database load and formatting.
    print("benchmarking CLI ...")
    cli_cases = []
    for query, target, note in SEARCH_QUERIES:
        cli_cases.append(("search", query, target, note))
    cli_cases.append(("count", COUNT_QUERIES[0][0], COUNT_QUERIES[0][1], "count"))
    cli_cases.append(("first", "", FIRST_QUERIES[0][2], "empty query, -n 20"))
    cli_rows = []
    for kind, query, target, note in cli_cases:
        if kind == "count":
            cmd = [args.binary, "-D", args.database, "count", "--engine", "bitmap", query]
        elif kind == "first":
            cmd = [args.binary, "-D", args.database, "--engine", "bitmap", "-n", "20", query]
        else:
            cmd = [args.binary, "-D", args.database, "--engine", "bitmap", "-n", "0", query]
        timing = measure_wall(cmd, args.cli_runs, 1)
        timing.update({"kind": kind, "query": query, "target_ms": target, "note": note})
        cli_rows.append(timing)

    # Query-time RSS and load timing for the heaviest representative command.
    rss_cmd = [args.binary, "-D", args.database, "count", "--engine", "bitmap", "report"]
    code, stdout, stderr, wall, rss = timed_command(rss_cmd)
    query_rss = rss
    count_ok = stdout.strip()

    sections = info.get("section_bytes", {})
    base_bytes = (
        sections.get("names", 0) + sections.get("folders", 0) + sections.get("files", 0)
    )
    extra_ratio = (db_size - base_bytes) / base_bytes if base_bytes else None

    # Keep engine and CLI rows paired by query text.
    bitmap_by_query = {row["query"]: row for row in engine_runs["bitmap"]}
    scan_by_query = {row["query"]: row for row in engine_runs["scan"]}
    count_by_query = {row["query"]: row for row in count_rows}
    first_by_query = {row["query"]: row for row in first_rows}
    scan_first_by_query = {row["query"]: row for row in scan_first_rows}
    cli_by_query = {row["query"]: row for row in cli_rows}

    result = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "label": args.label,
        "roots": args.root,
        "database": args.database,
        "database_bytes": db_size,
        "entries": entries,
        "info": info,
        "build": build,
        "machine": machine_info(),
        "load_ms": load_ms,
        "engine_search": engine_runs,
        "engine_count": count_rows,
        "engine_first": first_rows,
        "engine_scan_first": scan_first_rows,
        "cli": cli_rows,
        "query_rss_bytes": query_rss,
        "query_count": count_ok,
        "extra_ratio": extra_ratio,
    }
    with open(args.json_output, "w") as handle:
        json.dump(result, handle, indent=2)

    lines = []
    lines.append("# moonsearch benchmark results")
    lines.append("")
    lines.append("Generated: `%s`" % result["generated_at"])
    lines.append("")
    lines.append("## Dataset")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("| --- | --- |")
    lines.append("| Label | `%s` |" % args.label)
    home = str(Path.home())
    displayed_roots = [root.replace(home, "~", 1) for root in args.root]
    lines.append("| Roots | %s |" % ("<br>".join("`%s`" % root for root in displayed_roots) or "reused database"))
    lines.append("| Entries | %s |" % f"{entries:,}")
    lines.append("| Folders / files | %s / %s |" % (f'{int(info.get("folders", 0)):,}', f'{int(info.get("files", 0)):,}'))
    lines.append("| Names (unique) | %s |" % f'{int(info.get("names", 0)):,}')
    lines.append("| Database | %s |" % format_bytes(db_size))
    lines.append("| Format | `%s` |" % info.get("format", "?"))
    lines.append("")
    lines.append("## Environment")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("| --- | --- |")
    for key in ("cpu", "memory", "os", "platform", "machine", "moon", "commit"):
        if key in result["machine"]:
            value = result["machine"][key]
            if key == "memory":
                value = format_bytes(int(value))
            lines.append("| %s | %s |" % (key, value))
    lines.append("")
    lines.append("## Index build")
    lines.append("")
    lines.append("| Metric | Target | Measured | Status |")
    lines.append("| --- | --- | --- | --- |")
    wall_s = build.get("wall_s")
    build_target = 90.0 * entries / 1_000_000.0
    lines.append(
        "| Scan + build + write | %.1f s (90 s at 1M) | %s | %s |"
        % (
            build_target,
            ("%.1f s" % wall_s) if wall_s is not None else "n/a (reused database)",
            status_icon(wall_s, 90.0, entries / 1_000_000.0),
        )
    )
    build_rss = build.get("peak_rss_bytes")
    lines.append(
        "| Build peak RSS (information) | n/a | %s | n/a |"
        % (format_bytes(build_rss) if build_rss else "n/a")
    )
    lines.append("")
    lines.append("Build statistics from `index --stats`:")
    lines.append("")
    stats = build.get("stats", {})
    for key in ("scan_ms", "database_bytes", "names", "name_bytes", "extensions", "hidden"):
        if key in stats:
            lines.append("- `%s`: %s" % (key, stats[key]))
    for key in ("ranges", "trigram"):
        if key in stats:
            lines.append("- `%s`: %s" % (key, stats[key]))
    lines.append("")
    lines.append("## Database load")
    lines.append("")
    lines.append("| Metric | Target | Measured | Status |")
    lines.append("| --- | --- | --- | --- |")
    target_load = 800.0 * entries / 1_000_000.0
    measured_load = load_ms.get("bitmap")
    lines.append(
        "| Read MSDB into memory | %.0f ms (800 ms at 1M) | %s | %s |"
        % (
            target_load,
            ("%.0f ms" % measured_load) if measured_load is not None else "n/a",
            status_icon(measured_load, 800.0, entries / 1_000_000.0),
        )
    )
    lines.append(
        "| Query-time peak RSS | 400 MiB at 1M | %s | %s |"
        % (
            format_bytes(query_rss),
            status_icon(query_rss, 400 * 1024 * 1024, entries / 1_000_000.0)
            if query_rss
            else "n/a",
        )
    )
    lines.append("")
    lines.append("## Engine latency")
    lines.append("")
    lines.append(
        "Engine numbers come from `moonsearch-bench`: one database load, then "
        "`moonsearch/core/bench` samples the query path in-process with a "
        "monotonic clock. The median is shown; the raw JSON has min/max/mean."
    )
    lines.append("")
    lines.append("| Query | Target | Bitmap median | Scan median | Matches | Status |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for query, target, note in SEARCH_QUERIES:
        bitmap = bitmap_by_query.get(query)
        scan = scan_by_query.get(query)
        measured = bitmap["median_us"] / 1000.0 if bitmap else None
        lines.append(
            "| `%s` | %s | %s | %s | %s | %s |"
            % (
                query,
                ("%.0f ms" % target) if target >= 1 else ("%.1f ms" % target),
                format_us(bitmap["median_us"]) if bitmap else "n/a",
                format_us(scan["median_us"]) if scan else "n/a",
                f'{bitmap["matches"]:,}' if bitmap else "n/a",
                status_icon(measured, target),
            )
        )
    for query, target, note in COUNT_QUERIES:
        bitmap = count_by_query.get(query)
        measured = bitmap["median_us"] / 1000.0 if bitmap else None
        lines.append(
            "| `count %s` | %.1f ms | %s | n/a | %s | %s |"
            % (
                query,
                target,
                format_us(bitmap["median_us"]) if bitmap else "n/a",
                f'{bitmap["matches"]:,}' if bitmap else "n/a",
                status_icon(measured, target),
            )
        )
    for query, limit, target, note in FIRST_QUERIES:
        bitmap = first_by_query.get(query)
        scan = scan_first_by_query.get(query)
        measured = bitmap["median_us"] / 1000.0 if bitmap else None
        lines.append(
            "| empty query, `-n %d` | %.1f ms | %s | %s | %s | %s |"
            % (
                limit,
                target,
                format_us(bitmap["median_us"]) if bitmap else "n/a",
                format_us(scan["median_us"]) if scan else "n/a",
                f'{bitmap["matches"]:,}' if bitmap else "n/a",
                status_icon(measured, target),
            )
        )
    lines.append("")
    lines.append("## CLI wall time")
    lines.append("")
    lines.append(
        "Each CLI invocation loads the database and formats results, so this "
        "column is the user-visible cost, not the engine cost above. "
        "Median of %d runs after one warm-up." % args.cli_runs
    )
    lines.append("")
    lines.append("| Command | Target (engine) | Median wall | Min wall | Status |")
    lines.append("| --- | --- | --- | --- | --- |")
    for row in cli_rows:
        if row["kind"] == "count":
            label = "count '" + row["query"] + "'"
        elif row["kind"] == "first":
            label = "search -n 20 ''"
        else:
            label = "search '" + row["query"] + "'"
        lines.append(
            "| `%s` | %.1f ms | %.1f ms | %.1f ms | n/a (includes load) |"
            % (
                label,
                row["target_ms"],
                row["median_ms"],
                row["min_ms"],
            )
        )
    lines.append("")
    lines.append("## Index size")
    lines.append("")
    lines.append("| Section | Bytes |")
    lines.append("| --- | --- |")
    for name in (
        "roots",
        "excludes",
        "names",
        "folders",
        "files",
        "order",
        "dict",
        "ranges",
        "parent-paths",
        "postings",
        "checksum",
    ):
        if name in sections:
            lines.append("| %s | %s |" % (name, f"{sections[name]:,}"))
    lines.append("| **total** | **%s** |" % f"{db_size:,}")
    lines.append("")
    range_counts = {
        name: int(count)
        for name, count in re.findall(r"([a-z]+)=(\d+)", stats.get("ranges", ""))
    }
    if range_counts:
        # RANGES stores a value column and an id column per field: 5 bytes of
        # field header plus 12 bytes per (value, id) pair.  The section header
        # is one u32 field count.
        lines.append(
            "RANGES breakdown (5 B field header + 12 B per `(value, id)` pair):"
        )
        lines.append("")
        lines.append("| Field | Entries | Bytes |")
        lines.append("| --- | ---: | ---: |")
        for name, count in range_counts.items():
            lines.append("| %s | %s | %s |" % (name, f"{count:,}", f"{5 + 12 * count:,}"))
        lines.append("| field count | — | 4 |")
        lines.append("")
    lines.append(
        "Base (names + entry records): %s. Index extra: %s of the base (%.2f×; "
        "plan budget 1.5×). Total / base: %.2f×."
        % (
            format_bytes(base_bytes),
            format_bytes(max(0, db_size - base_bytes)),
            extra_ratio if extra_ratio is not None else 0.0,
            (db_size / base_bytes) if base_bytes else 0.0,
        )
    )
    lines.append("")
    lines.append("## Notes")
    lines.append("")
    lines.append("- Targets are from MIGRATION_PLAN.md section 10.1 and are scaled by entry count for build/load/RSS rows.")
    lines.append("- Each engine sample calls `exec_indexed` / `exec_scan_with`, so query compilation is included just as it is in a CLI invocation.")
    lines.append("- `report pdf` has no matches in this tree; it still measures two independent trigram groups.")
    lines.append("- `dm:lastweek` resolves against the local time zone at run time.")
    lines.append("- Re-run with `--rebuild-index` to regenerate the database and the build row.")
    lines.append("")

    with open(args.output, "w") as handle:
        handle.write("\n".join(lines))
    print("wrote %s and %s" % (args.output, args.json_output))


if __name__ == "__main__":
    main()
