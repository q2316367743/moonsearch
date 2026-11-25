#!/usr/bin/env python3
"""Process-level S02 checks for Unix names that are not valid UTF-8."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest


REPO = Path(__file__).resolve().parent.parent
BINARY = REPO / "_build/native/debug/build/cmd/moonsearch/moonsearch.exe"
ROOT = REPO / "_build/s02-raw-bytes"
DATABASE = REPO / "_build/s02-raw-bytes.msdb"


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux permits invalid UTF-8 names")
class RawByteCliTest(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(ROOT, ignore_errors=True)
        ROOT.mkdir(parents=True)
        (ROOT / os.fsdecode(b"bad-\xff")).write_bytes(b"x")
        (ROOT / os.fsdecode(b"bad-\xfe")).write_bytes(b"yy")

    def tearDown(self):
        shutil.rmtree(ROOT, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run(
            [str(BINARY), *args],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_scan_database_match_and_raw_output(self):
        indexed = self.run_cli("index", "-D", str(DATABASE), str(ROOT))
        self.assertEqual(indexed.returncode, 0, indexed.stderr)
        self.assertEqual(indexed.stdout, b"roots: 1\nfolders: 1\nfiles: 2\nbytes: 3\n")

        common = (
            "search",
            "-D",
            str(DATABASE),
            "--type",
            "file",
            "--relative-to",
            str(ROOT),
        )
        raw = self.run_cli(*common)
        self.assertEqual(raw.returncode, 0, raw.stderr)
        self.assertEqual(raw.stdout, b"bad-\xfe\nbad-\xff\n")

        nul = self.run_cli(*common, "--null")
        self.assertEqual(nul.returncode, 0, nul.stderr)
        self.assertEqual(nul.stdout, b"bad-\xfe\x00bad-\xff\x00")

        rendered = self.run_cli(*common, "--json")
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        text = rendered.stdout.decode("utf-8")
        rows = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(len(rows), 2)
        self.assertEqual([row["name"] for row in rows], ["bad-\ufffd", "bad-\ufffd"])
        self.assertEqual(
            rendered.stderr,
            b"warning: replaced invalid UTF-8 in 2 JSON record(s) with U+FFFD\n",
        )


if __name__ == "__main__":
    unittest.main()
