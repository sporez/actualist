#!/bin/bash
# Live-lab ZIP and CSV interop between Actualist and the pinned Actual. See README.md.
#   run.sh            every step in order, then cleanup and the summary
#   run.sh <step>     prepare | verifyZip | verifyCSV | cleanup (Node), swiftA | swiftB (Swift), summary
# Env (or the gitignored scripts/lib/lab.env): ACTUAL_LAB_URL, ACTUAL_LAB_PASSWORD,
# ACTUALIST_PARITY_ORACLE_ROOT. Optional: ACTUAL_LAB_HANDOFF_DIR, ACTUALIST_SCHEME.
set -euo pipefail
# /bin/pwd returns the on-disk case; bash's builtin keeps a mistyped one (cc vs CC),
# and vitest then matches no test file.
HERE="$(cd "$(dirname "$0")" && /bin/pwd -P)"
ROOT="$(cd "$HERE/../../.." && /bin/pwd -P)"
PIN="$ROOT/scripts/parity/lib/oracle-pin.mjs"
if [ -f "$ROOT/scripts/lib/lab.env" ]; then
  # Values already in the environment win over lab.env.
  while IFS='=' read -r key value; do
    case "$key" in ''|\#*) continue ;; esac
    [ -n "${!key:-}" ] || export "$key=$value"
  done < "$ROOT/scripts/lib/lab.env"
fi
: "${ACTUAL_LAB_URL:?set ACTUAL_LAB_URL (or scripts/lib/lab.env)}"
: "${ACTUAL_LAB_PASSWORD:?set ACTUAL_LAB_PASSWORD (or scripts/lib/lab.env)}"
export ACTUAL_LAB_URL ACTUAL_LAB_PASSWORD ACTUALIST_PARITY_ORACLE_ROOT
export ACTUAL_LAB_HANDOFF_DIR="${ACTUAL_LAB_HANDOFF_DIR:-$ROOT/.artifacts/live-lab-file-interop}"
export LAB_SOURCE_BUDGET='Lab · Interop Source'
mkdir -p "$ACTUAL_LAB_HANDOFF_DIR"

node_step() {
  local oracle status=0 log="$ACTUAL_LAB_HANDOFF_DIR/node-$1.log"
  # The helper fails unless ACTUALIST_PARITY_ORACLE_ROOT is a clean checkout at the pin.
  oracle="$(node "$PIN" oracle-root)"
  echo "== node $1 (log: $log)"
  ACTUALIST_PARITY_ORACLE_ROOT="$oracle" LAB_STEP="$1" NODE_ENV=production \
    LAB_VITE_CACHE_DIR="$ACTUAL_LAB_HANDOFF_DIR/vite-cache" \
    node --experimental-vm-modules "$oracle/node_modules/vitest/vitest.mjs" run \
      --configLoader native --config "$HERE/vitest.config.mjs" --reporter=dot >"$log" 2>&1 || status=$?
  grep '^LAB| ' "$log" | sed 's/^LAB| //' || true
  [ "$status" -eq 0 ] || { echo "node $1 failed:" >&2; grep -E 'Error|error' "$log" | grep -v '    at ' | head -15 >&2; }
  node "$PIN" oracle-root >/dev/null || { echo 'oracle checkout changed during the run' >&2; exit 97; }
  return "$status"
}

swift_step() {
  local test
  case "$1" in
    swiftA) test='LiveLabFileInteropTests/exportFromActualistAndImportActualZip()' ;;
    swiftB) test='LiveLabFileInteropTests/importActualCSVIntoActualist()' ;;
  esac
  echo "== swift $1"
  ACTUALIST_SCHEME="${ACTUALIST_SCHEME:-Actualist Dev}" \
  TEST_RUNNER_ACTUAL_LAB_URL="$ACTUAL_LAB_URL" \
  TEST_RUNNER_ACTUAL_LAB_PASSWORD="$ACTUAL_LAB_PASSWORD" \
  TEST_RUNNER_ACTUAL_LAB_HANDOFF_DIR="$ACTUAL_LAB_HANDOFF_DIR" \
    "$ROOT/scripts/test.sh" unit "$test"
}

ensure_source() {
  if ! "$ROOT/scripts/lab/budgets.sh" list 2>/dev/null | grep -q "^$LAB_SOURCE_BUDGET "; then
    echo "== creating $LAB_SOURCE_BUDGET"
    "$ROOT/scripts/lab/budgets.sh" create standard --name 'Interop Source'
  fi
}

summary() { node "$HERE/summary.mjs" "$ACTUAL_LAB_HANDOFF_DIR"; }

if [ $# -ge 1 ]; then
  case "$1" in
    prepare|verifyZip|verifyCSV|cleanup) node_step "$1" ;;
    swiftA|swiftB) swift_step "$1" ;;
    summary) summary ;;
    *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
  exit
fi

echo "Lab server: $ACTUAL_LAB_URL" >&2
# Each run starts from an empty handoff; the vite cache is kept.
find "$ACTUAL_LAB_HANDOFF_DIR" -mindepth 1 -maxdepth 1 ! -name vite-cache -exec rm -rf {} +
ensure_source
status=0
node_step prepare
swift_step swiftA || status=1
node_step verifyZip || status=1
if [ -f "$ACTUAL_LAB_HANDOFF_DIR/imported.json" ]; then
  swift_step swiftB || status=1
  node_step verifyCSV || status=1
  node_step cleanup || status=1
fi
summary || status=1
exit "$status"
