#!/bin/bash
# Manage test budgets on the disposable lab Actual server. See README.md.
#   budgets.sh list
#   budgets.sh create <standard|basic|tracking|pair|large|empty> [--name <suffix>] [--anchor YYYY-MM] [--months N] [--per-month N]
#   budgets.sh delete <name> | --all-managed
#   budgets.sh reset
#   budgets.sh wipe --yes        (deletes EVERY budget on the server)
#   budgets.sh download <name> <dir>
set -euo pipefail
# /bin/pwd returns the on-disk case; bash's builtin keeps a mistyped one (cc vs CC),
# and vitest then matches no test file.
HERE="$(cd "$(dirname "$0")" && /bin/pwd -P)"
ROOT="$(cd "$HERE/../.." && /bin/pwd -P)"
LAB_ENV="$ROOT/scripts/lib/lab.env"
# Values already in the environment win over lab.env.
if [ -f "$LAB_ENV" ]; then
  # shellcheck disable=SC1090
  source "$LAB_ENV"
fi
: "${ACTUAL_LAB_URL:?set ACTUAL_LAB_URL (or scripts/lib/lab.env); see scripts/lab/README.md}"
: "${ACTUAL_LAB_PASSWORD:?set ACTUAL_LAB_PASSWORD (or scripts/lib/lab.env)}"
: "${ACTUAL_UPSTREAM_DIR:=/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual}"
EXPECTED_SHA='59fe126f637d858c061e1eeedbef5436c8f2225a'

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
CMD="$1"; shift

# Run one node step: lab.test.mjs reads LAB_ARGS (JSON array) and dispatches.
run_node() {
  test "$(git -C "$ACTUAL_UPSTREAM_DIR" rev-parse HEAD)" = "$EXPECTED_SHA" \
    || { echo 'upstream checkout is not at the pinned commit' >&2; exit 96; }
  test -z "$(git -C "$ACTUAL_UPSTREAM_DIR" status --short)" \
    || { echo 'upstream checkout is not clean' >&2; exit 96; }
  local scratch="$ROOT/.artifacts/lab"
  mkdir -p "$scratch"
  export ACTUAL_UPSTREAM_DIR ACTUAL_LAB_URL ACTUAL_LAB_PASSWORD
  # Outside "test" mode upstream debounces syncs instead of awaiting one per write.
  export NODE_ENV=production
  export LAB_VITE_CACHE_DIR="$scratch/vite-cache"
  export LAB_SCRATCH_DIR="$scratch"
  export LAB_ARGS="$1"
  local status=0 log="$scratch/last-run.log"
  set +e
  node --experimental-vm-modules "$ACTUAL_UPSTREAM_DIR/node_modules/vitest/vitest.mjs" run \
    --configLoader native --config "$HERE/vitest.config.mjs" --reporter=dot 2>&1 \
    | tee "$log" | grep --line-buffered '^LAB| ' | sed -u 's/^LAB| //'
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -ne 0 ]; then
    echo "lab command failed (full log: $log)" >&2
    grep -E 'Error|error|failed' "$log" | grep -v 'source map\|map file\|ENOENT\|    at ' | head -15 >&2
  fi
  test -z "$(git -C "$ACTUAL_UPSTREAM_DIR" status --short)" \
    || { echo 'upstream checkout changed' >&2; exit 97; }
  return "$status"
}

json_args() { node -e 'console.log(JSON.stringify(process.argv.slice(1)))' -- "$@"; }

announce() { echo "Lab server: $ACTUAL_LAB_URL" >&2; }

create_one() { # profile + extra args
  run_node "$(json_args create "$@")"
}

case "$CMD" in
  list)
    run_node "$(json_args list)" ;;
  create)
    [ $# -ge 1 ] || usage
    announce
    create_one "$@" ;;
  delete)
    [ $# -ge 1 ] || usage
    announce
    run_node "$(json_args delete "$@")" ;;
  reset)
    announce
    run_node "$(json_args delete --all-managed)"
    for p in standard tracking pair; do create_one "$p"; done
    run_node "$(json_args list)" ;;
  wipe)
    [ "${1:-}" = "--yes" ] || { echo 'wipe deletes every budget on the lab server; pass --yes' >&2; exit 2; }
    announce
    run_node "$(json_args wipe --yes)" ;;
  download)
    [ $# -eq 2 ] || usage
    mkdir -p "$2"
    run_node "$(json_args download "$1" "$(cd "$2" && /bin/pwd -P)")" ;;
  *) usage ;;
esac
