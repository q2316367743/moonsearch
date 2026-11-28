#!/usr/bin/env python3
"""Record ``bench/demo.sh`` as an asciicast v2 file.

The script runs the demo in a pseudo-terminal, timestamps every chunk of
output, and writes the standard asciicast v2 JSON-lines format.  It is a small
replacement for ``asciinema rec`` so the recording can be regenerated on a
machine without asciinema installed:

    python3 bench/record_demo.py bench/demo.cast

Replay with ``asciinema play bench/demo.cast`` or any asciicast v2 player.
The recorded demo itself is deterministic; only the wall-clock timestamps and
the temporary directory name vary.
"""

import argparse
import fcntl
import json
import os
import pty
import select
import shlex
import struct
import subprocess
import sys
import termios
import time


def record(command, output, width, height):
    master, slave = pty.openpty()
    fcntl.ioctl(
        slave,
        termios.TIOCSWINSZ,
        struct.pack("HHHH", height, width, 0, 0),
    )
    env = os.environ.copy()
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = str(width)
    env["LINES"] = str(height)
    started = time.monotonic()
    process = subprocess.Popen(
        shlex.split(command),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)
    events = []
    while True:
        try:
            readable, _, _ = select.select([master], [], [], 0.1)
        except InterruptedError:
            continue
        if readable:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            events.append(
                [
                    round(time.monotonic() - started, 6),
                    "o",
                    data.decode("utf-8", "replace"),
                ]
            )
        elif process.poll() is not None:
            # One short grace period lets the final chunk arrive before exit.
            try:
                readable, _, _ = select.select([master], [], [], 0.05)
            except InterruptedError:
                readable = []
            if not readable:
                break
    os.close(master)
    code = process.wait()
    header = {
        "version": 2,
        "width": width,
        "height": height,
        "timestamp": int(time.time()),
        "env": {"SHELL": env.get("SHELL", "/bin/bash"), "TERM": env["TERM"]},
    }
    with open(output, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(header, ensure_ascii=False) + "\n")
        for event in events:
            handle.write(json.dumps(event, ensure_ascii=False) + "\n")
    return code, len(events)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", default="bench/demo.cast")
    parser.add_argument("--width", type=int, default=120)
    parser.add_argument("--height", type=int, default=40)
    parser.add_argument(
        "--command",
        default="bash bench/demo.sh",
        help="shell command to record (default: bash bench/demo.sh)",
    )
    args = parser.parse_args()
    code, events = record(args.command, args.output, args.width, args.height)
    print("recorded %d output events to %s (exit %d)" % (events, args.output, code))
    return code


if __name__ == "__main__":
    sys.exit(main())
