#!/usr/bin/env python3
"""S11 end-to-end checks for large sparse files.

Sparse files let the suite cover sizes above 2 GiB and 1 TiB without writing
that much data: indexing only reads metadata, and both engines must agree on
size comparisons, ordering, and database round-trips for Int64 values.

The test skips when the filesystem does not keep the fixture sparse (allocated
blocks would fill the runner's disk) and on Windows, where the CLI's byte-path
and POSIX fixture assumptions do not hold.
"""

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
TIB = 1 << 40
GIB = 1 << 30
MIB = 1 << 20


@unittest.skipUnless(POSIX, "sparse-file fixture uses POSIX metadata")
class SparseFileTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="moonsearch-s11-sparse-"))
        self.root = self.temp / "root"
        self.root.mkdir()
        self.huge = self.root / "huge.iso"
        self.medium = self.root / "medium.bin"
        self.small = self.root / "small.txt"
        with open(self.huge, "wb") as handle:
            handle.truncate(TIB)
        with open(self.medium, "wb") as handle:
            handle.truncate(3 * GIB + 1)
        self.small.write_bytes(b"0123456789")
        allocated = sum(
            path.stat().st_blocks * 512 for path in (self.huge, self.medium)
        )
        if allocated > 256 * MIB:
            self.skipTest(
                f"filesystem does not keep the fixture sparse ({allocated} bytes allocated)"
            )
        # Pin mtimes so date filters and ordering are independent of the host
        # clock (2024-03-15T12:00:00Z).
        for path in (self.root, self.huge, self.medium, self.small):
            os.utime(path, (1710504000, 1710504000))
        self.database = self.temp / "index.msdb"
        self.total_bytes = TIB + 3 * GIB + 1 + 10

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def run_cli(self, *args):
        return subprocess.run(
            [str(BINARY), *args],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
            check=False,
        )

    def search(self, *args):
        return self.run_cli("search", "-D", str(self.database), *args)

    def test_index_size_filters_order_and_round_trip(self):
        indexed = self.run_cli("index", "-D", str(self.database), str(self.root))
        self.assertEqual(indexed.returncode, 0, indexed.stderr)
        self.assertEqual(
            indexed.stdout,
            f"roots: 1\nfolders: 1\nfiles: 3\nbytes: {self.total_bytes}\n".encode(),
        )

        def count(engine, query):
            result = self.run_cli(
                "count", "-D", str(self.database), "--engine", engine, query
            )
            self.assertIn(result.returncode, (0, 1), result.stderr)
            return int(result.stdout)

        # Size sums cover folders too: the root accumulates every child, so a
        # threshold below the total also matches the root folder itself.
        cases = {
            "size:>500gb": 2,
            "size:>=1tb": 2,
            "size:>=3gb": 3,
            "size:>3gb": 3,
            "size:>=3221225473": 3,
            "size:==1099511627776": 1,
            "size:<1kb": 1,
            "file:size:>500gb": 1,
            "folder:size:>=4gb": 1,
            "size:>=3gb dm:2024-03": 3,
            "size:>=3gb dm:2024-02": 0,
        }
        for query, expected in cases.items():
            for engine in ("scan", "bitmap"):
                self.assertEqual(
                    count(engine, query), expected, f"{engine} count for {query}"
                )

        sized = self.search(
            "--live",
            "--root",
            str(self.root),
            "--type",
            "file",
            "--sort",
            "size",
            "--format",
            "{size}|{name}",
        )
        self.assertEqual(sized.returncode, 0, sized.stderr)
        self.assertEqual(
            sized.stdout,
            (
                "10|small.txt\n"
                f"{3 * GIB + 1}|medium.bin\n"
                f"{TIB}|huge.iso\n"
            ).encode(),
        )

        # The database survives the source tree: the sparse file was never
        # read, only its metadata was stored.
        huge_path = str(Path(os.path.realpath(self.huge)))
        shutil.rmtree(self.root)
        after = self.search("ext:iso")
        self.assertEqual(after.returncode, 0, after.stderr)
        self.assertEqual(after.stdout, f"{huge_path}\n".encode())

        info = self.run_cli("info", "-D", str(self.database), "--verify")
        self.assertEqual(info.returncode, 0, info.stderr)
        self.assertIn(b"files: 3\n", info.stdout)
        self.assertIn(b"checksum: verified\n", info.stdout)


if __name__ == "__main__":
    unittest.main()
