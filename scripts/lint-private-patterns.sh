#!/usr/bin/env bash
# Fails when a tracked (or new, not-ignored) file contains a maintainer-private
# identifier: a home-network address, server hostname, device identifier, or
# local path. The patterns live in the gitignored
# scripts/lib/private-patterns.txt, one extended regex per line; blank lines
# and lines starting with # are ignored. Without that file the lint skips, so
# a public clone is unaffected and the patterns themselves never enter git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PATTERNS_FILE="${ACTUALIST_PRIVATE_PATTERNS:-$ROOT/scripts/lib/private-patterns.txt}"

if [[ ! -f "$PATTERNS_FILE" ]]; then
  echo "skip: no private pattern list"
  exit 0
fi

patterns="$(mktemp)"
trap 'rm -f "$patterns"' EXIT
grep -vE '^[[:space:]]*(#|$)' "$PATTERNS_FILE" > "$patterns" || true

if [[ ! -s "$patterns" ]]; then
  echo "skip: private pattern list is empty"
  exit 0
fi

count="$(wc -l < "$patterns" | tr -d ' ')"

# --untracked also covers new files that are not yet added but not ignored.
# git grep exits 0 on a match, 1 on none, and >1 on an error; an error must
# fail the gate rather than read as "no matches".
set +e
matches="$(git grep --untracked -I -n -E -f "$patterns")"
grep_status=$?
set -e

case "$grep_status" in
  0)
    echo "error: files contain private identifiers from $PATTERNS_FILE:" >&2
    printf '%s\n' "$matches" >&2
    echo "Replace them with neutral values (example.com, 10.0.0.x, placeholders) or move the content to the private overlay." >&2
    exit 1
    ;;
  1)
    echo "ok: no private identifiers ($count patterns)"
    ;;
  *)
    echo "error: git grep failed (status $grep_status)" >&2
    exit 2
    ;;
esac
