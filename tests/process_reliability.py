#!/usr/bin/env python3
"""S10 process checks for broken pipes and SIGINT exit semantics."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parent.parent
BINARY = REPO / "_build/native/debug/build/cmd/moonsearch/moonsearch.exe"
POSIX = sys.platform != "win32"


@unittest.skipUnless(POSIX, "EPIPE and POSIX signals are required")
class ProcessReliabilityTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="moonsearch-s10-process-"))
        self.root = self.temp / "root"
        self.root.mkdir()
        for index in range(4000):
            (self.root / f"file-{index:05d}.txt").write_bytes(b"x")

    def tearDown(self):
        shutil.rmtree(self.temp, ignore_errors=True)

    def command(self, *extra):
        return [
            str(BINARY),
            "search",
            "--no-config",
            "--live",
            "--engine",
            "scan",
            "--root",
            str(self.root),
            *extra,
            "ext:txt",
        ]

    def test_streaming_order_and_stats_match_contract(self):
        (self.root / "a").mkdir()
        (self.root / "b").mkdir()
        (self.root / "a" / "z.txt").write_bytes(b"x")
        (self.root / "a0.txt").write_bytes(b"x")
        (self.root / "b" / "a.txt").write_bytes(b"x")
        common = ["search", "--no-config", "--live", "--root", str(self.root)]
        streamed = subprocess.run(
            [str(BINARY), *common, "--engine", "scan", "ext:txt"],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        indexed = subprocess.run(
            [str(BINARY), *common, "--engine", "bitmap", "ext:txt"],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        self.assertEqual(streamed.returncode, 0, streamed.stderr)
        self.assertEqual(
            sorted(streamed.stdout.splitlines()),
            sorted(indexed.stdout.splitlines()),
        )
        limited = subprocess.run(
            [str(BINARY), *common, "--engine", "scan", "--stats", "-n", "1", "ext:txt"],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        self.assertEqual(limited.returncode, 0, limited.stderr)
        self.assertEqual(len(limited.stdout.splitlines()), 1)
        self.assertIn(b"matches: 4003\n", limited.stderr)
        self.assertIn(b"output: 1\n", limited.stderr)

    def test_closed_pipe_is_quiet_success(self):
        child = subprocess.Popen(
            self.command(),
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        child.stdout.close()
        stderr = child.stderr.read()
        child.stderr.close()
        self.assertEqual(child.wait(timeout=20), 0, stderr)
        self.assertEqual(stderr, b"")

    def test_head_pipeline_is_quiet_success(self):
        script = '"$1" search --no-config --live --engine scan --root "$2" ext:txt | head -n 1 >/dev/null'
        result = subprocess.run(
            ["/bin/sh", "-c", "set -o pipefail; " + script, "sh", str(BINARY), str(self.root)],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")

    @unittest.skipUnless(Path("/dev/full").exists(), "/dev/full is unavailable")
    def test_other_stdout_errors_remain_failures(self):
        with open("/dev/full", "wb") as full:
            result = subprocess.run(
                self.command(),
                cwd=REPO,
                stdout=full,
                stderr=subprocess.PIPE,
                timeout=20,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertTrue(result.stderr.startswith(b"error: "), result.stderr)

    def test_sigint_uses_shell_status_130(self):
        for index in range(4000, 30000):
            (self.root / f"file-{index:05d}.txt").write_bytes(b"x")
        stdout_path = self.temp / "stdout"
        stderr_path = self.temp / "stderr"
        status_path = self.temp / "status"
        script = (
            '"$1" search --no-config --live --engine scan --root "$2" ext:txt '
            '>"$3" 2>"$4"; code=$?; echo "$code" >"$5"; exit "$code"'
        )
        child = subprocess.Popen(
            [
                "/bin/sh",
                "-c",
                script,
                "sh",
                str(BINARY),
                str(self.root),
                str(stdout_path),
                str(stderr_path),
                str(status_path),
            ],
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        deadline = time.monotonic() + 10
        scanned_pid = None
        while scanned_pid is None and time.monotonic() < deadline:
            rows = subprocess.check_output(
                ["/bin/ps", "-ax", "-o", "pid=,ppid="],
                text=True,
            ).splitlines()
            for row in rows:
                fields = row.split()
                if len(fields) == 2 and int(fields[1]) == child.pid:
                    scanned_pid = int(fields[0])
                    break
            if scanned_pid is None:
                time.sleep(0.0001)
        self.assertIsNotNone(scanned_pid, "helper shell did not start the scanner")
        while (
            not stdout_path.exists() or stdout_path.stat().st_size == 0
        ) and time.monotonic() < deadline:
            time.sleep(0.0001)
        self.assertGreater(stdout_path.stat().st_size, 0)
        os.kill(scanned_pid, signal.SIGINT)
        stderr = child.stderr.read()
        child.stdout.close()
        child.stderr.close()
        self.assertEqual(
            child.wait(timeout=20),
            130,
            f"status={status_path.read_text().strip()} scan_stderr={stderr_path.read_bytes()!r}",
        )
        self.assertEqual(
            status_path.read_text().strip(),
            "130",
            stderr_path.read_bytes(),
        )
        self.assertEqual(stderr_path.read_bytes(), b"")

    def test_waitpid_reports_sigint_signal(self):
        child = subprocess.Popen(
            self.command(),
            cwd=REPO,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        child.stdout.readline()
        child.send_signal(signal.SIGINT)
        stderr = child.stderr.read()
        child.stdout.close()
        child.stderr.close()
        self.assertEqual(child.wait(timeout=20), -signal.SIGINT, stderr)
        self.assertEqual(stderr, b"")


if __name__ == "__main__":
    if "--silent" in sys.argv:
        import contextlib

        sys.argv.remove("--silent")
        with open(os.devnull, "w") as devnull, contextlib.redirect_stdout(
            devnull
        ), contextlib.redirect_stderr(devnull):
            outcome = unittest.main(exit=False).result
        sys.exit(0 if outcome.wasSuccessful() else 1)
    unittest.main()
