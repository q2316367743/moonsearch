#!/usr/bin/env bash
# Scripted demo for moonsearch. Every command is deterministic and runs in a
# temporary directory, so the script is safe to record with:
#
#   asciinema rec bench/demo.cast -c "bash bench/demo.sh"
#
# or to replay as a normal walkthrough.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BIN="$ROOT/_build/native/release/build/cmd/moonsearch/moonsearch.exe"
DEMO="${TMPDIR:-/tmp}"; DEMO="${DEMO%/}/moonsearch-demo"
DB="$DEMO/demo.msdb"

step() {
  printf '\n\033[1;36m== %s ==\033[0m\n' "$1"
}

run() {
  printf '\n\033[1;33m$ %s\033[0m\n' "$*"
  "$@"
}

step "build"
run moon build --target native --release

step "create a small demo tree"
rm -rf "$DEMO"
mkdir -p "$DEMO/docs/2024" "$DEMO/docs/2025" "$DEMO/media" "$DEMO/src/search"
printf 'quarterly report\n' > "$DEMO/docs/2025/report-q1.pdf"
printf 'annual report\n' > "$DEMO/docs/2025/report-annual.pdf"
printf 'old report\n' > "$DEMO/docs/2024/report-old.pdf"
dd if=/dev/zero of="$DEMO/docs/2025/scan-large.pdf" bs=1024 count=1200 2>/dev/null
dd if=/dev/zero of="$DEMO/media/photo.jpg" bs=1024 count=200 2>/dev/null
dd if=/dev/zero of="$DEMO/media/video.mp4" bs=1024 count=4000 2>/dev/null
printf 'fn main() {}\n' > "$DEMO/src/search/main.mbt"
printf 'module search\n' > "$DEMO/src/search/moon.pkg"
printf 'hidden\n' > "$DEMO/.hidden-note.txt"
touch -t 202511010900 "$DEMO/docs/2024/report-old.pdf"
run find "$DEMO" -type f | sort

step "index the tree"
run "$BIN" -D "$DB" index --stats "$DEMO"

step "query the persisted index"
run "$BIN" -D "$DB" search --engine bitmap 'report'

step "two trigram groups"
run "$BIN" -D "$DB" search --engine bitmap 'report pdf'

step "bitmap x range, with the plan"
run "$BIN" -D "$DB" search --engine bitmap --explain 'ext:pdf size:>1mb'

step "count without materializing paths"
run "$BIN" -D "$DB" count --engine bitmap 'ext:pdf'

step "sort by size, JSON output"
run "$BIN" -D "$DB" search --engine bitmap --sort size --json -n 3 ''

step "compare with the linear scan oracle"
run "$BIN" -D "$DB" search --engine scan -n 3 'report pdf'

step "index metadata and integrity"
run "$BIN" -D "$DB" info --verify

step "done"
printf '\nDatabase: %s\n' "$DB"
