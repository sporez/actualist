#!/usr/bin/env bash
# Unit tests run in parallel by default. ui and all stay serial unless
# ACTUALIST_TEST_PARALLEL is set explicitly. The lock coordinates cooperating
# scripts/test.sh invocations in this checkout only. It does not cover raw
# xcodebuild commands, other checkouts, or every simulator process.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/load-destinations.sh"

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [--dry-run] unit|ui|all [Suite[/testMethod] ...]

  unit [selectors]  Selected unit suites, or all unit tests when omitted.
  ui selectors      Selected UI suites or methods; at least one is required.
  all               Full unit and UI suites; accepts no selectors.
  --dry-run         Print the command without invoking Xcode or taking a lock.

Selectors omit the target prefix, e.g. BankSyncReconcilerTests.
Uses ACTUALIST_SIMULATOR_ID from the environment or local destinations.sh.
DERIVED_DATA_PATH defaults to .derivedData in the repository.

ACTUALIST_TEST_PARALLEL:
  unset   unit runs with -parallel-testing-enabled YES; ui and all use NO.
  1       -parallel-testing-enabled YES for the selected mode.
  0       -parallel-testing-enabled NO for the selected mode.
  other   error, including an empty value. Help, invalid arguments, invalid
          parallel values, and dry-run do not create or touch a test-run lock.

A real invocation that finds .artifacts/.test-run.lock refuses to run. It does
not delete or reclaim that lock, even if the recorded PID is dead or the
metadata is missing. Recovery means verifying the prior invocation and its
test activity have ended, then removing the lock. A dead PID is not that
verification.
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

if [[ -z "${ACTUALIST_TEST_PARALLEL+x}" ]]; then
  case "$mode" in
    unit) parallel=YES ;;
    ui|all) parallel=NO ;;
  esac
else
  case "${ACTUALIST_TEST_PARALLEL}" in
    0) parallel=NO ;;
    1) parallel=YES ;;
    *)
      echo "error: ACTUALIST_TEST_PARALLEL must be 0 or 1" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

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

command=(xcodebuild -project Actualist.xcodeproj -scheme Actualist
  -destination "platform=iOS Simulator,id=$ACTUALIST_SIMULATOR_ID"
  -derivedDataPath "${DERIVED_DATA_PATH:-.derivedData}"
  -parallel-testing-enabled "$parallel")
if [[ ${#selection[@]} -gt 0 ]]; then
  command+=("${selection[@]}")
fi
command+=(test)

if [[ "$dry_run" -eq 1 ]]; then
  printf '%q ' "${command[@]}"
  printf '\n'
  exit 0
fi

lockdir="$ROOT/.artifacts/.test-run.lock"
acquired=0
interrupted=0
interrupt_signal=""
child_pid=""
run_token="$(uuidgen | tr '[:upper:]' '[:lower:]')"

report_held_lock() {
  echo "error: test-run lock exists at $lockdir" >&2
  echo "error: this script does not delete or reclaim a lock, even when the recorded PID is dead or metadata is missing or malformed." >&2
  if [[ -f "$lockdir/pid" ]]; then
    echo "error: owner pid metadata: $(cat "$lockdir/pid" 2>/dev/null || echo unreadable)" >&2
  else
    echo "error: owner pid metadata: unavailable" >&2
  fi
  if [[ -f "$lockdir/token" ]]; then
    echo "error: run token metadata: $(cat "$lockdir/token" 2>/dev/null || echo unreadable)" >&2
  else
    echo "error: run token metadata: unavailable" >&2
  fi
  if [[ -f "$lockdir/child-pid" ]]; then
    echo "error: child pid metadata: $(cat "$lockdir/child-pid" 2>/dev/null || echo unreadable)" >&2
  else
    echo "error: child pid metadata: unavailable" >&2
  fi
  echo "error: recovery requires verifying the prior invocation and its associated test activity have ended, then removing $lockdir. A dead PID is not that verification." >&2
}

recovery_required() {
  echo "error: $*" >&2
  echo "error: test-run lock retained at $lockdir" >&2
  echo "error: recovery requires verifying this invocation and its test activity have ended. A dead wrapper or xcodebuild PID does not prove simulator activity has ended. This script will not delete the lock." >&2
}

signal_recorded_child() {
  [[ -n "$child_pid" ]] || return 0
  printf '%s\n' "$child_pid" > "$lockdir/signaled-child" 2>/dev/null || true
  builtin kill -TERM "$child_pid" 2>/dev/null || true
}

exit_interrupted() {
  recovery_required "$1"
  if [[ -n "$interrupt_signal" ]]; then
    exit $((128 + interrupt_signal))
  fi
  exit 129
}

on_signal() {
  interrupt_signal="$1"
  interrupted=1
  if [[ "$acquired" -eq 1 ]]; then
    printf '%s\n' "$1" > "$lockdir/interrupted" 2>/dev/null || true
  fi
  signal_recorded_child
}

trap 'on_signal 2' INT
trap 'on_signal 15' TERM
trap 'on_signal 1' HUP

mkdir -p "$ROOT/.artifacts" || fail "could not create $ROOT/.artifacts"
if ! mkdir "$lockdir" 2>/dev/null; then
  report_held_lock
  exit 2
fi
acquired=1

printf '%s\n' "$run_token" > "$lockdir/token"
printf '%s\n' "$$" > "$lockdir/pid"
printf '%s\n' "$mode" > "$lockdir/mode"
date -u +%Y-%m-%dT%H:%M:%SZ > "$lockdir/started"

cd "$ROOT"
if [[ "$interrupted" -eq 1 || -f "$lockdir/interrupted" ]]; then
  exit_interrupted "invocation interrupted during setup (${interrupt_signal:-signal}); workload was not launched"
fi
set +e
"${command[@]}" &
child_pid=$!
start_status=$?
set -e
if [[ "$start_status" -ne 0 || -z "$child_pid" ]]; then
  recovery_required "could not start xcodebuild"
  exit 1
fi
printf '%s\n' "$child_pid" > "$lockdir/child-pid" || true
if [[ "$interrupted" -eq 1 || -f "$lockdir/interrupted" ]]; then
  signal_recorded_child
  exit_interrupted "invocation interrupted (${interrupt_signal:-signal}); child termination is not confirmed"
fi

set +e
wait "$child_pid"
child_status=$?
set -e

if [[ "$interrupted" -eq 1 || -f "$lockdir/interrupted" ]]; then
  signal_recorded_child
  exit_interrupted "invocation interrupted (${interrupt_signal:-signal}); child termination is not confirmed"
fi

if [[ "$child_status" -ne 0 ]]; then
  recovery_required "xcodebuild exited $child_status"
  exit "$child_status"
fi

token_now="$(cat "$lockdir/token" 2>/dev/null || echo "")"
pid_now="$(cat "$lockdir/pid" 2>/dev/null || echo "")"
if [[ "$token_now" != "$run_token" || "$pid_now" != "$$" ]]; then
  recovery_required "lock ownership no longer matches this invocation"
  exit 1
fi

rm -f "$lockdir/token" "$lockdir/pid" "$lockdir/child-pid" "$lockdir/mode" "$lockdir/started"
if ! rmdir "$lockdir"; then
  recovery_required "could not remove an otherwise empty lock directory without recursive deletion"
  exit 1
fi
acquired=0
exit 0
