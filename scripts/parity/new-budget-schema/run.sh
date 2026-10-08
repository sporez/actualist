#!/bin/bash
# usage:
#   run.sh generate            create a fresh upstream budget and dump it
#   run.sh emit-swift          write Actualist/.../ActualStarterSchema.swift from schema.sql
#   run.sh check <db.sqlite> [metadata.json] [result.json]
# Needs ACTUAL_UPSTREAM_DIR (pinned checkout, read-only) and node v24.21.0.
set -euo pipefail

# /bin/pwd returns the on-disk case; bash's builtin keeps a mistyped one (cc vs CC),
# and vitest then matches no test file.
HERE="$(cd "$(dirname "$0")" && /bin/pwd -P)"
REPO="$(cd "$HERE/../../.." && pwd)"
: "${ACTUAL_UPSTREAM_DIR:?set to the pinned Actual v26.9.0 checkout}"
OUT="${NEWBUDGET_OUT_DIR:-$REPO/.artifacts/audit-remediation-2026-10/newbudget-schema}"
EXPECTED_SHA='59fe126f637d858c061e1eeedbef5436c8f2225a'
mkdir -p "$OUT"

test "$(git -C "$ACTUAL_UPSTREAM_DIR" rev-parse HEAD)" = "$EXPECTED_SHA"
test -z "$(git -C "$ACTUAL_UPSTREAM_DIR" status --short)"
test "$(node --version)" = 'v24.21.0'

export ACTUAL_UPSTREAM_DIR NEWBUDGET_OUT_DIR="$OUT"
export NEWBUDGET_VITE_CACHE_DIR="$OUT/vite-cache"
vitest() {
  node --experimental-vm-modules "$ACTUAL_UPSTREAM_DIR/node_modules/vitest/vitest.mjs" run \
    --configLoader native --config "$HERE/vitest.config.mjs"
}

status=0
case "${1:-}" in
  generate)
    NEWBUDGET_TEST_FILE=generate.test.mjs vitest || status=$?
    if [ "$status" -eq 0 ]; then
      python3 "$HERE/dump.py" "$OUT/fresh-budget/db.sqlite" "$OUT" || status=$?
    fi ;;
  emit-swift)
    python3 "$HERE/emit_swift.py" "$OUT/schema.sql" "$OUT/seed-rows.json" \
      "$REPO/Actualist/LocalFirst/Database/ActualStarterSchema.swift" || status=$? ;;
  check)
    export CHECK_DB="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    export CHECK_META="${3:-}"
    export CHECK_RESULT="${4:-$OUT/interop-result.json}"
    NEWBUDGET_TEST_FILE=check.test.mjs vitest || status=$? ;;
  *) echo "usage: run.sh generate | emit-swift | check <db> [metadata] [result.json]" >&2; exit 2 ;;
esac

test -z "$(git -C "$ACTUAL_UPSTREAM_DIR" status --short)" || { echo 'upstream checkout changed' >&2; exit 97; }
echo "exit status: $status"
exit "$status"
