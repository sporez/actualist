#!/bin/bash
# usage: run.sh <step>
#   seedA | offlineB | syncB | final | compare
# Env: ACTUAL_LAB_URL, ACTUAL_LAB_PASSWORD, ACTUALIST_PARITY_ORACLE_ROOT,
#      ACTUAL_LAB_HANDOFF_DIR (shared with the Swift tests). See README.md.
set -euo pipefail
# /bin/pwd returns the on-disk case; bash's builtin keeps a mistyped one (cc vs CC),
# and vitest then matches no test file.
HERE="$(cd "$(dirname "$0")" && /bin/pwd -P)"
PIN="$HERE/../lib/oracle-pin.mjs"
: "${ACTUAL_LAB_URL:?}" "${ACTUAL_LAB_PASSWORD:?}" "${ACTUAL_LAB_HANDOFF_DIR:?}"
# The helper fails unless ACTUALIST_PARITY_ORACLE_ROOT is a clean checkout at the pin.
ORACLE="$(node "$PIN" oracle-root)"
mkdir -p "$ACTUAL_LAB_HANDOFF_DIR"
export ACTUALIST_PARITY_ORACLE_ROOT="$ORACLE" LAB_STEP="$1"
export LAB_VITE_CACHE_DIR="$ACTUAL_LAB_HANDOFF_DIR/vite-cache"
status=0
node --experimental-vm-modules "$ORACLE/node_modules/vitest/vitest.mjs" run \
  --configLoader native --config "$HERE/vitest.config.mjs" || status=$?
node "$PIN" oracle-root >/dev/null || { echo 'oracle checkout changed during the run' >&2; exit 97; }
exit "$status"
