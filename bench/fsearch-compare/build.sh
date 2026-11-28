#!/usr/bin/env bash
# Build the headless FSearch benchmark driver against FSearch's core library.
#
# Usage: build.sh <fsearch-src> <output-binary>
set -euo pipefail

FSEARCH_SRC="${1:?usage: build.sh <fsearch-src> <output-binary>}"
OUT="${2:?usage: build.sh <fsearch-src> <output-binary>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$FSEARCH_SRC/src/meson.build" ]]; then
  echo "not an FSearch source tree: $FSEARCH_SRC" >&2
  exit 2
fi

# The core source list is the non-UI static library in src/meson.build.
CORE_SOURCES=()
while IFS= read -r source; do
  CORE_SOURCES+=("$source")
done < <(
  awk '/^libfsearch_core_sources = \[/,/^\]/' "$FSEARCH_SRC/src/meson.build" \
    | grep -o "'[^']*\.c'" \
    | tr -d "'"
)

if [[ ${#CORE_SOURCES[@]} -eq 0 ]]; then
  echo "failed to find libfsearch_core_sources in $FSEARCH_SRC/src/meson.build" >&2
  exit 2
fi

CFLAGS=(
  -O2
  -g
  -std=gnu11
  -D_FILE_OFFSET_BITS=64
  -D_GNU_SOURCE
  -Dg_get_num_processors=g_bench_num_processors
  -I"$HERE"
  -I"$FSEARCH_SRC/src"
)

# FSearch's core is written for Linux.  On Darwin, provide the two missing
# GNU/Linux pieces so the same source compiles unchanged.
if [[ "$(uname -s)" == "Darwin" ]]; then
  CFLAGS+=(-I"$HERE/compat" -include "$HERE/compat/memrchr.h")
fi
PKGS=(gio-unix-2.0 pango libpcre2-8 icu-uc glib-2.0)

cc "${CFLAGS[@]}" \
  "$HERE/bench_fsearch.c" \
  "${CORE_SOURCES[@]/#/$FSEARCH_SRC/src/}" \
  $(pkg-config --cflags --libs "${PKGS[@]}") \
  -lm \
  -o "$OUT"
