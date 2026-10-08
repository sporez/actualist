#!/bin/bash
# usage: run.sh <step>
#   seedA | offlineB | syncB | final | compare
# Env: ACTUAL_LAB_URL, ACTUAL_LAB_PASSWORD, ACTUAL_UPSTREAM_DIR,
#      ACTUAL_LAB_HANDOFF_DIR (shared with the Swift tests). See README.md.
set -euo pipefail
# /bin/pwd returns the on-disk case; bash's builtin keeps a mistyped one (cc vs CC),
# and vitest then matches no test file.
HERE="$(cd "$(dirname "$0")" && /bin/pwd -P)"
: "${ACTUAL_UPSTREAM_DIR:?set to the pinned Actual v26.9.0 checkout}"
: "${ACTUAL_LAB_URL:?}" "${ACTUAL_LAB_PASSWORD:?}" "${ACTUAL_LAB_HANDOFF_DIR:?}"
EXPECTED_SHA='59fe126f637d858c061e1eeedbef5436c8f2225a'
test "$(git -C "$ACTUAL_UPSTREAM_DIR" rev-parse HEAD)" = "$EXPECTED_SHA"
test -z "$(git -C "$ACTUAL_UPSTREAM_DIR" status --short)"
mkdir -p "$ACTUAL_LAB_HANDOFF_DIR"
export ACTUAL_UPSTREAM_DIR LAB_STEP="$1"
export LAB_VITE_CACHE_DIR="$ACTUAL_LAB_HANDOFF_DIR/vite-cache"
status=0
node --experimental-vm-modules "$ACTUAL_UPSTREAM_DIR/node_modules/vitest/vitest.mjs" run \
  --configLoader native --config "$HERE/vitest.config.mjs" || status=$?
test -z "$(git -C "$ACTUAL_UPSTREAM_DIR" status --short)" || { echo 'upstream checkout changed' >&2; exit 97; }
exit "$status"
