#!/usr/bin/env python3
"""Generate the deterministic dataset used by the moonsearch benchmarks.

The published benchmark numbers use this synthetic tree instead of a private
home directory, so a clean clone can recreate the same entry count and the same
query shapes. The generator is deterministic for a given ``--reference-time``:
names, extensions, sizes, and relative mtimes are derived from the file index,
not from the random module.

Usage:

    # Primary dataset (~1.03M entries, the size used by bench/results.md)
    python3 bench/gen_dataset.py --dir bench/.data/synthetic-1m \\
        --entries 1030056 --manifest-json bench/.data/synthetic-1m.manifest.json

    # Smaller tree for the FSearch comparison
    python3 bench/gen_dataset.py --dir bench/.data/synthetic-300k --entries 300000

    # Hash an existing tree without generating anything
    python3 bench/gen_dataset.py --manifest-only --dir ~/Documents/workspace/app

The manifest is a metadata manifest: it hashes sorted records of
``relative_path, type, size, mtime(seconds)``. It does not read file contents
(the files are empty or sparse), so two generations agree when they use the
same ``--reference-time``.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone

# Weighted extension cycle for ordinary files. 200 slots keep the distribution
# deterministic while giving every benchmark query a stable hit count.
EXT_CYCLE = (
    ["jpg"] * 1
    + ["mp4"] * 1
    + ["js"] * 150
    + ["map"] * 50
    + ["md"] * 100
    + ["png"] * 50
    + ["json"] * 50
    + ["ts"] * 50
    + ["txt"] * 548
)

# Name tokens. `report`, `source`, `map`, and `index` are present so the
# benchmark queries exercise substrings and trigram groups.
TOKENS = (
    "app index report source map plugin build assets docs test config "
    "service client server module package component layout router store "
    "theme style script image media audio video archive backup cache data"
).split()

PREFIX_DIRS = ("src", "lib", "dist", "docs", "assets", "test", "node_modules")

ONE_MIB = 1024 * 1024


def parse_reference(value):
    if value is None:
        return int(time.time())
    try:
        return int(value)
    except ValueError:
        pass
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())


def folder_count_for(entries, ratio):
    folders = int(round(entries * ratio))
    if folders < 1:
        folders = 1
    if folders >= entries:
        folders = entries - 1
    return folders


def build_directory_plan(count, branch=8):
    """Breadth-first directory plan: each folder gets up to `branch` children.

    `count` includes the root itself. Returns (paths, depths) in creation
    order; the root is the first entry.
    """
    paths = [""]
    depths = [0]
    queue = [""]
    cursor = 0
    while len(paths) < count:
        if cursor >= len(queue):
            break
        parent = queue[cursor]
        cursor += 1
        depth = parent.count("/") + 1 if parent else 0
        for child in range(branch):
            if len(paths) >= count:
                break
            name = "%s%02d" % (PREFIX_DIRS[(depth + child) % len(PREFIX_DIRS)], child)
            path = name if not parent else parent + "/" + name
            paths.append(path)
            depths.append(depth + 1)
            queue.append(path)
    return paths, depths


def extension_for(index):
    return EXT_CYCLE[index % len(EXT_CYCLE)]


def size_for(index, extension):
    if extension in ("jpg", "jpeg"):
        # Large photos are rare, matching a workspace that mostly holds source.
        return 2 * ONE_MIB if index % 300000 == 0 else 200 * 1024
    if extension == "mp4":
        return 5 * ONE_MIB if index % 2 == 0 else 100 * 1024
    if extension == "pdf":
        return (index * 4099) % (200 * 1024)
    # Ordinary source files average a few KB, matching the private workspace.
    return (index * 37) % (16 * 1024)


def mtime_for(index, reference):
    # Only a small slice is newer than a week, as in the private workspace.
    if index % 1009 == 0:
        days = index % 5
    else:
        days = 30 + (index % 400)
    return reference - days * 86400


def file_name(index, local, extension, directory_index, directory_count):
    token = TOKENS[(index * 7919) % len(TOKENS)]
    # Reuse names across directories the way a real tree does, but keep enough
    # of them distinct that the name pool and trigram postings stay realistic.
    bucket = directory_index % 73
    if index % 997 == 0:
        # `report pdf` / `*.pdf` / `report` all match these.
        base = "report-%d-%s" % (local, token)
        extension = "pdf"
    elif index % 1499 == 0:
        # `source map` matches both trigrams in one name.
        base = "source-map-%d-%s" % (local, token)
        extension = "js"
    else:
        base = "%s_%d_%d" % (token, bucket, local)
    if index % 1013 == 0:
        base = "." + base
    return "%s.%s" % (base, extension)


def generate(root, entries, folder_ratio, reference, branch):
    folders = folder_count_for(entries, folder_ratio)
    files = entries - folders
    paths, depths = build_directory_plan(folders, branch=branch)
    if len(paths) != folders:
        raise SystemExit(
            "directory plan produced %d folders, expected %d" % (len(paths), folders)
        )
    if os.path.exists(root):
        shutil.rmtree(root)
    os.makedirs(root)
    absolute = [root]
    for path in paths[1:]:
        target = os.path.join(root, path)
        os.mkdir(target)
        absolute.append(target)
    started = time.time()
    created = 0
    for index in range(files):
        directory_index = index % len(absolute)
        directory = absolute[directory_index]
        local = index // len(absolute)
        extension = extension_for(index)
        name = file_name(
            index, local, extension, directory_index, len(absolute)
        )
        path = os.path.join(directory, name)
        size = size_for(index, extension)
        fd = os.open(path, os.O_CREAT | os.O_WRONLY, 0o644)
        if size:
            os.ftruncate(fd, size)
        os.close(fd)
        stamp = mtime_for(index, reference)
        os.utime(path, (stamp, stamp))
        created += 1
        if created % 100000 == 0:
            elapsed = time.time() - started
            print("  created %d/%d files (%.1fs)" % (created, files, elapsed))
    # Give directories a stable mtime too, so the manifest does not depend on
    # the order in which children were written.
    for depth, path in reversed(list(enumerate(paths))):
        target = os.path.join(root, path) if path else root
        stamp = reference - (30 + (depth % 12)) * 86400
        os.utime(target, (stamp, stamp))
    return folders, files


def manifest(root, manifest_json, extra):
    records = []
    total_bytes = 0
    # The indexed root itself is one folder entry. Count it so `entries` matches
    # `moonsearch index --stats` for `--root <dir>`.
    folders = 1
    files = 0
    stack = [("", root)]
    while stack:
        prefix, directory = stack.pop()
        with os.scandir(directory) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name)
        for entry in entries:
            relative = entry.name if not prefix else prefix + "/" + entry.name
            info = entry.stat(follow_symlinks=False)
            if entry.is_dir(follow_symlinks=False):
                kind = "d"
                folders += 1
                stack.append((relative, entry.path))
            else:
                kind = "f"
                files += 1
                total_bytes += info.st_size
            records.append(
                "%s\t%s\t%d\t%d" % (relative, kind, info.st_size, int(info.st_mtime))
            )
    records.sort()
    digest = hashlib.sha256()
    for record in records:
        digest.update(record.encode("utf-8", "surrogateescape"))
        digest.update(b"\n")
    summary = {
        "kind": "moonsearch-bench-dataset-manifest",
        "root": os.path.abspath(root),
        "folders": folders,
        "files": files,
        "entries": folders + files,
        "total_file_bytes": total_bytes,
        "manifest_sha256": digest.hexdigest(),
        "manifest_fields": "relative_path, type, size, mtime_seconds",
        "manifest_record_count": len(records),
    }
    summary.update(extra)
    if manifest_json:
        os.makedirs(os.path.dirname(os.path.abspath(manifest_json)) or ".", exist_ok=True)
        with open(manifest_json, "w") as handle:
            json.dump(summary, handle, indent=2, sort_keys=True)
            handle.write("\n")
    print(json.dumps(summary, indent=2, sort_keys=True))
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True, help="dataset root to create or hash")
    parser.add_argument(
        "--entries",
        type=int,
        default=1030056,
        help="target entry count (folders + files); default 1,030,056",
    )
    parser.add_argument(
        "--folder-ratio",
        type=float,
        default=0.10,
        help="fraction of entries that are folders (default 0.10)",
    )
    parser.add_argument(
        "--branch",
        type=int,
        default=8,
        help="maximum child directories per folder (default 8)",
    )
    parser.add_argument(
        "--reference-time",
        default=None,
        help="Unix seconds or ISO-8601 timestamp used as 'now' for mtimes",
    )
    parser.add_argument(
        "--manifest-json",
        default=None,
        help="write the manifest summary JSON here",
    )
    parser.add_argument(
        "--manifest-only",
        action="store_true",
        help="do not generate; only hash the existing tree at --dir",
    )
    args = parser.parse_args()

    reference = parse_reference(args.reference_time)
    extra = {
        "generator": "bench/gen_dataset.py",
        "target_entries": args.entries,
        "folder_ratio": args.folder_ratio,
        "branch": args.branch,
        "reference_time": reference,
        "reference_time_iso": datetime.fromtimestamp(
            reference, tz=timezone.utc
        ).isoformat(),
        "command": " ".join(sys.argv),
    }
    if not args.manifest_only:
        print(
            "generating %d entries under %s (reference time %s)"
            % (args.entries, args.dir, extra["reference_time_iso"])
        )
        folders, files = generate(
            args.dir,
            args.entries,
            args.folder_ratio,
            reference,
            args.branch,
        )
        extra.update({"planned_folders": folders, "planned_files": files})
    summary = manifest(args.dir, args.manifest_json, extra)
    if summary["entries"] != args.entries:
        print(
            "note: measured %d entries, target was %d"
            % (summary["entries"], args.entries),
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
