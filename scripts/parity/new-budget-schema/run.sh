#!/bin/bash
# usage:
#   run.sh generate                    create a fresh upstream budget, dump it and write the manifest
#   run.sh drift                       regenerate into a temp dir and compare with the committed NewBudget fixture
#   run.sh emit-swift [target.swift]   write the Swift starter-schema source (default: $NEWBUDGET_OUT_DIR)
#   run.sh check <db.sqlite> [metadata.json] [result.json]
# generate, drift and check need ACTUALIST_PARITY_ORACLE_ROOT (a clean checkout
# of the pinned release, config/parity/oracle-pin.json) and node v24.21.0.
# Nothing is written into the oracle checkout.
set -euo pipefail

# /bin/pwd returns the on-disk case; bash's builtin keeps a mistyped one (cc vs CC),
# and vitest then matches no test file.
HERE="$(cd "$(dirname "$0")" && /bin/pwd -P)"
REPO="$(cd "$HERE/../../.." && pwd)"
PIN="$REPO/scripts/parity/lib/oracle-pin.mjs"
MODE="${1:-}"

case "$MODE" in
  generate|drift|check|emit-swift) ;;
  *) echo "usage: run.sh generate | drift | emit-swift [target.swift] | check <db> [metadata] [result.json]" >&2; exit 2 ;;
esac

ORACLE=""
if [ "$MODE" != emit-swift ]; then
  if ! node "$PIN" has-oracle; then
    echo "Set ACTUALIST_PARITY_ORACLE_ROOT to a clean checkout of the pinned Actual release (config/parity/oracle-pin.json)." >&2
    exit 2
  fi
  ORACLE="$(node "$PIN" oracle-root)"
  test "$(node --version)" = 'v24.21.0'
fi

if [ "$MODE" = drift ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/newbudget-drift.XXXXXX")"
else
  OUT="${NEWBUDGET_OUT_DIR:-$REPO/.artifacts/audit-remediation-2026-10/newbudget-schema}"
fi
mkdir -p "$OUT"

if [ -n "$ORACLE" ]; then
  export ACTUALIST_PARITY_ORACLE_ROOT="$ORACLE" NEWBUDGET_OUT_DIR="$OUT"
  export NEWBUDGET_VITE_CACHE_DIR="$OUT/vite-cache"
fi
vitest() {
  node --experimental-vm-modules "$ORACLE/node_modules/vitest/vitest.mjs" run \
    --configLoader native --config "$HERE/vitest.config.mjs"
}

status=0
case "$MODE" in
  generate)
    NEWBUDGET_TEST_FILE=generate.test.mjs vitest || status=$?
    if [ "$status" -eq 0 ]; then
      python3 "$HERE/dump.py" "$OUT/fresh-budget/db.sqlite" "$OUT" &&
        python3 "$HERE/manifest.py" "$OUT" "$ORACLE" || status=$?
    fi ;;
  drift)
    NEWBUDGET_TEST_FILE=generate.test.mjs vitest || status=$?
    if [ "$status" -eq 0 ]; then
      FIXTURE="$REPO/$(node "$PIN" fixtureDirectory)/NewBudget"
      python3 "$HERE/dump.py" "$OUT/fresh-budget/db.sqlite" "$OUT" &&
        python3 "$HERE/manifest.py" "$OUT" "$ORACLE" &&
        python3 "$HERE/drift.py" "$FIXTURE" "$OUT" || status=$?
    fi ;;
  emit-swift)
    TARGET="${2:-$OUT/ActualStarterSchema.swift}"
    python3 "$HERE/emit_swift.py" "$OUT/schema.sql" "$OUT/seed-rows.json" "$TARGET" || status=$?
    echo "wrote $TARGET" ;;
  check)
    export CHECK_DB="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
    export CHECK_META="${3:-}"
    export CHECK_RESULT="${4:-$OUT/interop-result.json}"
    NEWBUDGET_TEST_FILE=check.test.mjs vitest || status=$? ;;
esac

if [ -n "$ORACLE" ]; then
  node "$PIN" oracle-root >/dev/null || { echo 'oracle checkout changed during the run' >&2; exit 97; }
fi
if [ "$MODE" = drift ] && [ "$status" -eq 0 ]; then
  rm -rf "$OUT"
fi
echo "exit status: $status"
exit "$status"
