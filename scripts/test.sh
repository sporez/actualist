#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/load-destinations.sh"

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [--dry-run] unit|ui|all [Suite[/testMethod] ...]

  unit [selectors]  Selected unit suites, or all unit tests when omitted.
  ui selectors     Selected UI suites or methods; at least one is required.
  all              Full unit and UI suites; accepts no selectors.
  --dry-run        Print the command without invoking Xcode.

Selectors omit the target prefix, e.g. BankSyncReconcilerTests.
Uses ACTUALIST_SIMULATOR_ID from the environment or local destinations.sh.
DERIVED_DATA_PATH defaults to .derivedData in the repository.
EOF
}

fail() { echo "error: $*" >&2; exit 2; }

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  shift
fi
mode="${1:-}"
case "$mode" in
  -h|--help) usage; exit 0 ;;
  unit|ui|all) shift ;;
  *) usage >&2; exit 2 ;;
esac

selection=()
case "$mode" in
  unit) target=ActualistTests ;;
  ui)
    [[ $# -gt 0 ]] || fail "ui requires a suite or method; use all for full coverage"
    target=ActualistUITests
    ;;
  all) [[ $# -eq 0 ]] || fail "all accepts no selectors" ;;
esac

if [[ "$mode" != "all" ]]; then
  if [[ $# -eq 0 ]]; then
    selection+=("-only-testing:$target")
  else
    for selector in "$@"; do
      [[ "$selector" =~ ^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(\(\))?)?$ ]] \
        || fail "invalid suite/method selector: $selector"
      # ActualistUITests is also a suite name, so it is a valid selector.
      case "$selector" in
        ActualistTests|ActualistTests/*)
          fail "omit the target prefix: $selector" ;;
      esac
      selection+=("-only-testing:$target/$selector")
    done
  fi
fi

[[ -n "${ACTUALIST_SIMULATOR_ID:-}" ]] \
  || fail "set ACTUALIST_SIMULATOR_ID or configure scripts/lib/destinations.sh"

cd "$ROOT"
command=(xcodebuild -project Actualist.xcodeproj -scheme Actualist
  -destination "platform=iOS Simulator,id=$ACTUALIST_SIMULATOR_ID"
  -derivedDataPath "${DERIVED_DATA_PATH:-.derivedData}")
if [[ ${#selection[@]} -gt 0 ]]; then
  command+=("${selection[@]}")
fi
command+=(test)
if [[ "$dry_run" -eq 1 ]]; then
  printf '%q ' "${command[@]}"
  printf '\n'
else
  exec "${command[@]}"
fi
