#!/usr/bin/env python3
"""S11 minimal differential corpus against the real executable.

The in-process differential tests in `src/cli/differential_test.mbt` compare
`@cli.run`, which is fast but never exercises argument parsing, real stdout
buffers, or process exit codes. This script indexes one fixture tree and runs a
hand-written corpus through the built binary with both engines, comparing
stdout bytes, stderr, and exit codes. It also covers the persisted no-trigram
build, `--live`, output options, invalid queries, and `--compat`.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
BINARY = REPO / "_build/native/debug/build/cmd/moonsearch/moonsearch.exe"
POSIX = sys.platform != "win32"

# Hand-written semantic corpus: names, globs, regex, fields, ranges, absolute
# dates, structure predicates, booleans, and Unicode. Empty results and
# non-empty results are both expected, so the comparison never depends on the
# query being selective.
QUERIES = [
    "",
    "report",
    "REPORT",
    "case:REPORT",
    "nocase:REPORT",
    "exact:report",
    "*.pdf",
    "?.md",
    "index\\*",
    'regex:"^report"',
    "path:docs",
    "ext:pdf",
    "ext:pdf;txt",
    "doc:",
    "file:",
    "folder:",
    "hidden:",
    "size:>10",
    "size:0",
    "size:1kb..2kb",
    "dm:2024-03",
    "dm:2024-02",
    "dm:>=2024-03-01",
    "depth:1",
    "childcount:0",
    "childfilecount:>1",
    "empty:",
    "contenttype:pdf",
    "pdf OR txt",
    "pdf AND txt",
    "!pdf",
    "!(pdf OR txt)",
    "(report OR notes) (pdf OR txt)",
    "file:(report OR notes)",
    "发票",
    "case:发票",
    "a",
    "ab",
    'file:regex:"\\.[a-z]+$"',
    "size: = = 12",
]

# Invalid queries must fail identically, and `--compat` must turn them into an
# empty result on both engines.
INVALID_QUERIES = [
    'file:regex:"["',
    "file:dm:nonsense",
    "unknown:value",
    "size:1kb..2kb..3kb",
]

# Name queries that exercise the trigram candidate source, short-needle and
# stop-gram degradation, and case folding.
TRIGRAM_QUERIES = ["report", "notes", "*.pdf", "a", "发票", ""]

# Output options are compared on a smaller set because each combination runs
# two processes.
OUTPUT_OPTIONS = [
    ["--type", "file", "--sort", "size"],
    ["--type", "file", "--sort", "ext"],
    ["--type", "file", "--sort", "name", "--reverse"],
    ["--type", "file", "--null"],
    ["--type", "file", "--json"],
    ["--type", "file", "--format", "{name}|{size}|{ext}|{type}"],
    ["--type", "file", "-n", "3"],
    ["--folders-first"],
    ["--sort", "mtime", "--reverse", "-n", "2"],
]


@unittest.skipUnless(POSIX, "the fixture uses POSIX paths and metadata")
class ExecutableDifferentialTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="moonsearch-s11-exec-diff-"))
        self.root = self.temp / "root"
        (self.root / "sub").mkdir(parents=True)
        (self.root / "empty").mkdir()
        (self.root / "Unicode").mkdir()
        (self.root / "deep" / "one" / "two").mkdir(parents=True)
        files = {
            "a.pdf": b"012345678901",
            "Report Final.md": b"hello world this is a report",
            "notes.txt": b"",
            "draft.md": b"draft",
            ".hidden": b"hh",
            "sub/report.pdf": b"x",
            "sub/data.zip": b"0123456789",
            "sub/photo.JPG": b"01234567890123456789",
            "Unicode/发票.txt": b"abcdefg",
            "Unicode/报告 2024.pdf": b"0123456789012",
            "deep/one/two/leaf.md": b"abc",
        }
        for relative, contents in files.items():
            (self.root / relative).write_bytes(contents)
        # 2024-03-15T12:00:00Z for most entries; a few older ones make the dm
        # range queries selective. Directory mtimes are pinned as well.
        for path in [self.root, *(self.root.rglob("*"))]:
            os.utime(path, (1710504000, 1710504000))
        os.utime(self.root / "Report Final.md", (1706745600, 1706745600))
        os.utime(self.root / "notes.txt", (1709251200, 1709251200))
        os.utime(self.root / "sub", (1709251200, 1709251200))
        self.database = self.temp / "index.msdb"
        self.plain_database = self.temp / "no-trigram.msdb"
        self.canonical_root = Path(os.path.realpath(self.root))
        indexed = self.run_cli("index", "-D", str(self.database), str(self.root))
        self.assertEqual(indexed.returncode, 0, indexed.stderr)
        plain = self.run_cli(
            "index", "-D", str(self.plain_database), "--no-trigram", str(self.root)
        )
        self.assertEqual(plain.returncode, 0, plain.stderr)

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run(
            [str(BINARY), "--no-config", *args],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )

    def assert_engines_agree(self, label, arguments, sort_stdout=False):
        scan = self.run_cli(*arguments, "--engine", "scan")
        bitmap = self.run_cli(*arguments, "--engine", "bitmap")
        detail = (
            f"{label}: scan code={scan.returncode} bitmap code={bitmap.returncode}\n"
            f"scan stdout={scan.stdout!r}\nbitmap stdout={bitmap.stdout!r}\n"
            f"scan stderr={scan.stderr!r}\nbitmap stderr={bitmap.stderr!r}"
        )
        self.assertEqual(scan.returncode, bitmap.returncode, detail)
        if sort_stdout:
            self.assertEqual(
                sorted(scan.stdout.splitlines()), sorted(bitmap.stdout.splitlines()), detail
            )
        else:
            self.assertEqual(scan.stdout, bitmap.stdout, detail)
        self.assertEqual(scan.stderr, bitmap.stderr, detail)
        return scan

    def test_fixture_is_sane(self):
        count = self.run_cli("count", "-D", str(self.database), "ext:pdf")
        self.assertEqual(count.returncode, 0, count.stderr)
        self.assertEqual(count.stdout, b"3\n")

    def test_search_and_count_agree_on_the_corpus(self):
        for query in QUERIES:
            with self.subTest(query=query):
                self.assert_engines_agree(
                    f"search {query!r}", ["search", "-D", str(self.database), query]
                )
                self.assert_engines_agree(
                    f"count {query!r}", ["count", "-D", str(self.database), query]
                )
        # Paths are absolute and fixture-specific; build them at run time.
        for query in [
            f"parent:{self.canonical_root}/sub",
            f"path:{self.canonical_root}/sub",
            f"nopath:{self.canonical_root}/sub",
        ]:
            with self.subTest(query=query):
                self.assert_engines_agree(
                    f"search {query!r}", ["search", "-D", str(self.database), query]
                )

    def test_invalid_queries_fail_identically_and_compat_empties(self):
        for query in INVALID_QUERIES:
            with self.subTest(query=query):
                failed = self.assert_engines_agree(
                    f"invalid {query!r}", ["search", "-D", str(self.database), query]
                )
                self.assertEqual(failed.returncode, 2, failed.stderr)
                self.assertEqual(failed.stdout, b"", failed.stderr)
                self.assertTrue(failed.stderr.startswith(b"error: "), failed.stderr)
                for command in ("search", "count"):
                    compatible = self.run_cli(
                        command,
                        "-D",
                        str(self.database),
                        "--compat",
                        "--engine",
                        "scan",
                        query,
                    )
                    self.assertEqual(compatible.returncode, 1, compatible.stderr)
                    expected_stdout = b"0\n" if command == "count" else b""
                    self.assertEqual(
                        compatible.stdout, expected_stdout, compatible.stderr
                    )
                    self.assertEqual(compatible.stderr, b"", compatible.stderr)

    def test_persisted_no_trigram_build_agrees(self):
        for query in TRIGRAM_QUERIES:
            with self.subTest(query=query):
                self.assert_engines_agree(
                    f"no-trigram {query!r}",
                    ["search", "-D", str(self.plain_database), query],
                )

    def test_live_engines_agree_as_sets(self):
        for query in TRIGRAM_QUERIES:
            with self.subTest(query=query):
                self.assert_engines_agree(
                    f"live {query!r}",
                    ["search", "--live", "--root", str(self.root), query],
                    sort_stdout=True,
                )

    def test_output_options_agree_byte_for_byte(self):
        for options in OUTPUT_OPTIONS:
            with self.subTest(options=options):
                result = self.assert_engines_agree(
                    f"options {options}",
                    ["search", "-D", str(self.database), *options],
                )
                self.assertEqual(result.returncode, 0, result.stderr)
        # JSON must stay valid and carry the pinned mtimes (two files are
        # deliberately older so the dm ranges are selective).
        rendered = self.run_cli(
            "search", "-D", str(self.database), "--type", "file", "--json"
        )
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        rows = [json.loads(line) for line in rendered.stdout.decode("utf-8").splitlines()]
        self.assertTrue(rows)
        self.assertEqual(
            {row["mtime"] for row in rows},
            {1710504000, 1709251200, 1706745600},
            rows,
        )


if __name__ == "__main__":
    unittest.main()
