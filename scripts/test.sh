#!/usr/bin/env bash
# Unit tests run in parallel by default. UI tests run in parallel across
# simulator clones by default; the suites in serial_ui_suites run afterwards in
# a serial pass. ACTUALIST_TEST_PARALLEL overrides both with a single pass. The
# lock coordinates cooperating scripts/test.sh invocations in this checkout
# only. It does not cover raw xcodebuild commands, other checkouts, or every
# simulator process.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/load-destinations.sh"

# UI suites that depend on state a simulator clone does not isolate. They run
# in a serial pass after the parallel one. Give each entry its reason.
#   LabBudgetSwitchUITests: signs in to the shared lab server and leaves the
#     device signed in, which no demo reset clears. Skipped unless
#     TEST_RUNNER_ACTUAL_LAB_URL is set.
serial_ui_suites=(
  LabBudgetSwitchUITests
)

# Simulator clones used by a parallel pass that runs UI tests.
default_ui_workers=4

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [--dry-run] unit|ui|all [Suite[/testMethod] ...]

  unit [selectors]  Selected unit suites, or all unit tests when omitted.
  ui selectors      Selected UI suites or methods; at least one is required.
  all               Full unit and UI suites; accepts no selectors.
  --dry-run         Print the commands without invoking Xcode or taking a lock.

Selectors omit the target prefix, e.g. BankSyncReconcilerTests.
Swift Testing methods may include argument labels, e.g. 'ExampleTests/check(_:)'.
Uses ACTUALIST_SIMULATOR_ID from the environment or local destinations.sh.
DERIVED_DATA_PATH defaults to .derivedData in the repository.
ACTUALIST_SCHEME may be Actualist (the default) or Actualist Dev.
ACTUALIST_TEST_SANITIZER=thread adds -enableThreadSanitizer YES (diagnostic
runs only; it rebuilds with instrumentation and runs much slower).

ACTUALIST_TEST_PARALLEL:
  unset   unit: one pass with -parallel-testing-enabled YES.
          ui and all: up to three xcodebuild passes, in this order:
            unit       all unit tests in parallel (all only)
            ui-parallel UI suites in parallel on simulator clones
            ui-serial  the serial-only UI suites listed at the top of this
                       script, with -parallel-testing-enabled NO
          A pass with nothing selected is left out.
  1       one pass with -parallel-testing-enabled YES for the whole selection.
  0       one pass with -parallel-testing-enabled NO for the whole selection.
  other   error, including an empty value. Help, invalid arguments, invalid
          parallel values, and dry-run do not create or touch a test-run lock.
ACTUALIST_UI_TEST_WORKERS sets -parallel-testing-worker-count for a parallel
pass that runs UI tests (default 4).

All passes share one lock and one log. A failing pass does not stop the next,
so a run reports every selected suite; an interrupted or signal-terminated
pass stops the run. Exit status: the first failing pass's xcodebuild status;
3 when a pass replaced a test host mid-run; 4 when a pass succeeded without
running a test; 2 for usage errors and a held lock.

A run releases its lock when xcodebuild exits on its own, including test or
build failures (exit status below 128). An interrupted run stops xcodebuild
and waits up to 60 seconds for it to exit; it releases the lock if xcodebuild
exited. The lock is kept when xcodebuild outlives that wait, is killed by a
signal while the script was not interrupted, or ownership no longer matches.

A real invocation that finds .artifacts/.test-run.lock refuses to run. It does
not delete or reclaim that lock, even if the recorded PID is dead or the
metadata is missing. Recovery means verifying the prior invocation and its
test activity have ended, then removing the lock. A dead PID is not that
verification.

A real invocation deletes shut-down simulator clones in
~/Library/Developer/XCTestDevices: on exit, the ones it created; before it
starts, any at least 10 minutes old, including the clone Xcode finishes
creating after the previous run exited. Booted clones are left alone.
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

# split is the default ui/all plan; YES or NO runs one pass for everything.
if [[ -z "${ACTUALIST_TEST_PARALLEL+x}" ]]; then
  case "$mode" in
    unit) parallel=YES ;;
    ui|all) parallel=split ;;
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

ui_workers="${ACTUALIST_UI_TEST_WORKERS:-$default_ui_workers}"
[[ "$ui_workers" =~ ^[1-9][0-9]*$ ]] || fail "ACTUALIST_UI_TEST_WORKERS must be a positive integer"

scheme="${ACTUALIST_SCHEME:-Actualist}"
case "$scheme" in
  Actualist|"Actualist Dev") ;;
  *) fail "ACTUALIST_SCHEME must be Actualist or Actualist Dev" ;;
esac

is_serial_ui_suite() {
  local suite
  for suite in "${serial_ui_suites[@]}"; do
    [[ "$1" == "$suite" ]] && return 0
  done
  return 1
}

# The selection, split by the pass that runs it.
unit_selection=()
ui_parallel_selection=()
ui_serial_selection=()
case "$mode" in
  unit)
    if [[ $# -eq 0 ]]; then
      unit_selection=(-only-testing:ActualistTests)
    fi
    ;;
  ui) [[ $# -gt 0 ]] || fail "ui requires a suite or method; use all for full coverage" ;;
  all)
    [[ $# -eq 0 ]] || fail "all accepts no selectors"
    unit_selection=(-only-testing:ActualistTests)
    ui_parallel_selection=(-only-testing:ActualistUITests)
    for suite in "${serial_ui_suites[@]}"; do
      ui_parallel_selection+=("-skip-testing:ActualistUITests/$suite")
      ui_serial_selection+=("-only-testing:ActualistUITests/$suite")
    done
    ;;
esac

for selector in "$@"; do
  [[ "$selector" =~ ^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(\(([A-Za-z_][A-Za-z0-9_]*:)*\))?)?$ ]] \
    || fail "invalid suite/method selector: $selector"
  case "$selector" in
    ActualistTests|ActualistTests/*)
      fail "omit the target prefix: $selector" ;;
  esac
  if [[ "$mode" == unit ]]; then
    unit_selection+=("-only-testing:ActualistTests/$selector")
  elif is_serial_ui_suite "${selector%%/*}"; then
    ui_serial_selection+=("-only-testing:ActualistUITests/$selector")
  else
    ui_parallel_selection+=("-only-testing:ActualistUITests/$selector")
  fi
done

[[ -n "${ACTUALIST_SIMULATOR_ID:-}" ]] \
  || fail "set ACTUALIST_SIMULATOR_ID or configure scripts/lib/destinations.sh"

case "${ACTUALIST_TEST_SANITIZER:-}" in
  "") sanitizer_flags=() ;;
  thread) sanitizer_flags=(-enableThreadSanitizer YES) ;;
  *) fail "ACTUALIST_TEST_SANITIZER must be unset or thread" ;;
esac

# Every pass's xcodebuild words live in pass_words; pass_ends[i] is the offset
# just past pass i's last word (bash 3.2 has no nested arrays).
pass_names=()
pass_words=()
pass_ends=()

add_pass() {
  local name="$1" parallel_flag="$2" runs_ui="$3"
  shift 3
  pass_names+=("$name")
  pass_words+=(xcodebuild -project Actualist.xcodeproj -scheme "$scheme"
    -destination "platform=iOS Simulator,id=$ACTUALIST_SIMULATOR_ID"
    -derivedDataPath "${DERIVED_DATA_PATH:-.derivedData}"
    -parallel-testing-enabled "$parallel_flag")
  if [[ "$parallel_flag" == YES && "$runs_ui" -eq 1 ]]; then
    pass_words+=(-parallel-testing-worker-count "$ui_workers")
  fi
  if [[ ${#sanitizer_flags[@]} -gt 0 ]]; then
    pass_words+=("${sanitizer_flags[@]}")
  fi
  if [[ $# -gt 0 ]]; then
    pass_words+=("$@")
  fi
  pass_words+=(test)
  pass_ends+=("${#pass_words[@]}")
}

# Sets command to pass $1's words.
load_pass_command() {
  local start=0
  [[ "$1" -eq 0 ]] || start="${pass_ends[$(($1 - 1))]}"
  command=("${pass_words[@]:$start:$((pass_ends[$1] - start))}")
}

if [[ "$parallel" == split ]]; then
  if [[ ${#unit_selection[@]} -gt 0 ]]; then
    add_pass unit YES 0 "${unit_selection[@]}"
  fi
  if [[ ${#ui_parallel_selection[@]} -gt 0 ]]; then
    add_pass ui-parallel YES 1 "${ui_parallel_selection[@]}"
  fi
  if [[ ${#ui_serial_selection[@]} -gt 0 ]]; then
    add_pass ui-serial NO 1 "${ui_serial_selection[@]}"
  fi
elif [[ "$mode" == all ]]; then
  # A forced single all pass selects nothing, so it runs every test target.
  add_pass all "$parallel" 1
else
  runs_ui=1
  [[ "$mode" != unit ]] || runs_ui=0
  add_pass "$mode" "$parallel" "$runs_ui" \
    "${unit_selection[@]+"${unit_selection[@]}"}" \
    "${ui_parallel_selection[@]+"${ui_parallel_selection[@]}"}" \
    "${ui_serial_selection[@]+"${ui_serial_selection[@]}"}"
fi

if [[ "$dry_run" -eq 1 ]]; then
  for index in "${!pass_names[@]}"; do
    load_pass_command "$index"
    printf '%q ' "${command[@]}"
    printf '\n'
  done
  exit 0
fi

lockdir="$ROOT/.artifacts/.test-run.lock"
acquired=0
interrupted=0
interrupt_signal=""
child_pid=""
interrupt_grace_seconds=60
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

release_lock() {
  local token_now pid_now
  token_now="$(cat "$lockdir/token" 2>/dev/null || echo "")"
  pid_now="$(cat "$lockdir/pid" 2>/dev/null || echo "")"
  if [[ "$token_now" != "$run_token" || "$pid_now" != "$$" ]]; then
    recovery_required "lock ownership no longer matches this invocation"
    exit 1
  fi
  rm -f "$lockdir/token" "$lockdir/pid" "$lockdir/child-pid" "$lockdir/mode" "$lockdir/started" \
    "$lockdir/interrupted" "$lockdir/signaled-child"
  if ! rmdir "$lockdir"; then
    recovery_required "could not remove an otherwise empty lock directory without recursive deletion"
    exit 1
  fi
  acquired=0
}

# An exited child stays a zombie until reaped, so `kill -0` cannot tell.
child_has_exited() {
  local state
  state="$(ps -o stat= -p "$child_pid" 2>/dev/null || true)"
  [[ -z "$state" || "$state" == Z* ]]
}

# xcodebuild ends its test session when it handles SIGTERM. Once it has
# exited, the lock can go; if it outlives the grace period, keep the lock.
exit_interrupted() {
  local status=129
  [[ -z "$interrupt_signal" ]] || status=$((128 + interrupt_signal))
  if [[ -n "$child_pid" ]]; then
    signal_recorded_child
    local deadline=$((SECONDS + interrupt_grace_seconds))
    while ! child_has_exited; do
      if (( SECONDS >= deadline )); then
        recovery_required "$1; xcodebuild did not exit within ${interrupt_grace_seconds}s"
        exit "$status"
      fi
      sleep 0.5
    done
    wait "$child_pid" 2>/dev/null || true
  fi
  release_lock
  echo "error: $1; the test-run lock was released" >&2
  exit "$status"
}

on_signal() {
  interrupt_signal="$1"
  interrupted=1
  if [[ "$acquired" -eq 1 ]]; then
    printf '%s\n' "$1" > "$lockdir/interrupted" 2>/dev/null || true
  fi
  signal_recorded_child
}

# Parallel testing clones the destination simulator into XCTestDevices, and
# Xcode 27 leaves a shut-down clone behind after every run. CoreSimulator can
# finish registering that clone up to a minute after xcodebuild exits, so a
# run deletes its own shut-down clones on exit and, before it starts, sweeps
# shut-down clones at least 10 minutes old. Booted clones and younger clones
# that predate this run may belong to test activity in another checkout.
clone_set="$HOME/Library/Developer/XCTestDevices"
clone_sweep_age_seconds=600
clones_before=""

list_clones() {
  xcrun simctl --set "$clone_set" list devices 2>/dev/null \
    | sed -nE "s/^ +Clone [0-9]+ of .+ \(([0-9A-F-]{36})\) \(($1)\) *\$/\1/p" || true
}

delete_clone() {
  xcrun simctl --set "$clone_set" delete "$1" 2>/dev/null \
    || echo "warning: could not delete simulator clone $1" >&2
}

delete_stale_clones() {
  [[ -d "$clone_set" ]] || return 0
  local udid created now
  now="$(date +%s)"
  for udid in $(list_clones Shutdown); do
    created="$(stat -f %m "$clone_set/$udid/device.plist" 2>/dev/null || echo "$now")"
    (( now - created >= clone_sweep_age_seconds )) || continue
    delete_clone "$udid"
  done
}

delete_new_clones() {
  [[ -d "$clone_set" ]] || return 0
  local udid
  for udid in $(list_clones Shutdown); do
    [[ "$clones_before" == *"$udid"* ]] && continue
    delete_clone "$udid"
  done
}

# tee finishes once xcodebuild and everything sharing its output have closed
# it. Wait a bounded time so a lingering descendant cannot hold the wrapper.
wait_for_run_log() {
  local waited=0
  while [[ ! -f "$run_log_done" && "$waited" -lt 30 ]]; do
    sleep 1
    waited=$((waited + 1))
  done
}

# Prints the run log from line $1 on: the output of the pass that began there.
pass_output() {
  [[ -f "$run_log" ]] || return 0
  tail -n "+$1" "$run_log"
}

# Each test host reports as "<host name> (<pid>)". The same host under a
# second pid within one pass means it was relaunched mid-run: Swift Testing
# does not report the tests that were still running in the replaced process,
# and the result bundle omits them too, so the summary alone can look
# complete. Passes are separate xcodebuild sessions, so each is checked alone.
report_replaced_hosts() {
  # A pass with no test-host lines (a build failure) has nothing to report.
  { pass_output "$1" | grep -oE "on '[^']+ \([0-9]+\)'" || true; } \
    | sed -E "s/^on '(.+) \(([0-9]+)\)'\$/\1|\2/" \
    | sort -u \
    | awk -F'|' '{ pids[$1] = pids[$1] (pids[$1] == "" ? "" : ", ") $2; count[$1]++ }
        END { for (host in count) if (count[host] > 1) print host " (pids " pids[host] ")" }'
}

# Per-test result lines in the three shapes xcodebuild prints: parallel runs
# ("Test case '...' passed on ..."), serial Swift Testing ("✔ Test name()
# passed after ..."), and XCTest ("Test Case '-[...]' passed"). The summary
# lines ("Test run with N tests", "Executed N tests") are not counted, because
# XCTest prints "Executed 0 tests" even when Swift Testing tests ran.
count_reported_tests() {
  { pass_output "$1" | grep -E "^Test case '|^Test Case '-\[.*\]' (passed|failed|skipped)|^[✔✘↪] Test .* (passed|failed|skipped)" || true; } \
    | { grep -vc "^[✔✘↪] Test run with" || true; }
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
  exit_interrupted "invocation interrupted during setup (${interrupt_signal:-signal}); xcodebuild was not launched"
fi
if [[ -d "$clone_set" ]]; then
  delete_stale_clones
  clones_before="$(list_clones '[A-Za-z ]+')"
fi
trap delete_new_clones EXIT
# The output is also kept in a log so each pass can be checked for a replaced
# test host after its xcodebuild exits (see report_replaced_hosts).
run_log="$ROOT/.artifacts/last-test-run.log"
run_log_done="$ROOT/.artifacts/last-test-run.done"
: > "$run_log"
run_status=0
for index in "${!pass_names[@]}"; do
  if [[ "$interrupted" -eq 1 || -f "$lockdir/interrupted" ]]; then
    exit_interrupted "invocation interrupted (${interrupt_signal:-signal}) before pass ${pass_names[$index]}"
  fi
  load_pass_command "$index"
  pass_first_line=$(( $(wc -l < "$run_log") + 1 ))
  if [[ ${#pass_names[@]} -gt 1 ]]; then
    printf '=== scripts/test.sh pass %d of %d: %s ===\n' \
      "$((index + 1))" "${#pass_names[@]}" "${pass_names[$index]}" | tee -a "$run_log"
  fi
  rm -f "$run_log_done"
  set +e
  "${command[@]}" > >(tee -a "$run_log"; touch "$run_log_done") 2>&1 &
  child_pid=$!
  start_status=$?
  set -e
  if [[ "$start_status" -ne 0 || -z "$child_pid" ]]; then
    recovery_required "could not start xcodebuild"
    exit 1
  fi
  printf '%s\n' "$child_pid" > "$lockdir/child-pid" || true
  if [[ "$interrupted" -eq 1 || -f "$lockdir/interrupted" ]]; then
    exit_interrupted "invocation interrupted (${interrupt_signal:-signal})"
  fi

  set +e
  wait "$child_pid"
  child_status=$?
  set -e

  if [[ "$interrupted" -eq 1 || -f "$lockdir/interrupted" ]]; then
    exit_interrupted "invocation interrupted (${interrupt_signal:-signal})"
  fi

  # xcodebuild ends its own test session before it exits, including after test
  # or build failures. A signal exit (128+) means it was killed mid-run, so test
  # activity may outlive it.
  if [[ "$child_status" -ge 128 ]]; then
    recovery_required "xcodebuild was terminated (exit $child_status)"
    exit "$child_status"
  fi
  # This pass's xcodebuild has exited; a later signal has no child to stop.
  child_pid=""

  wait_for_run_log
  pass_label="${pass_names[$index]}"
  pass_status="$child_status"
  if [[ "$pass_status" -ne 0 ]]; then
    echo "error: $pass_label: xcodebuild exited $pass_status" >&2
  fi
  replaced_hosts="$(report_replaced_hosts "$pass_first_line")"
  if [[ -n "$replaced_hosts" ]]; then
    echo "error: $pass_label: a test host was replaced during the run, so the tests still running in it were never reported:" >&2
    printf '  %s\n' "$replaced_hosts" >&2
    echo "error: the run is incomplete; full output is in $run_log" >&2
    [[ "$pass_status" -ne 0 ]] || pass_status=3
  fi
  # A selector that matches nothing (a Swift Testing method named without its
  # "()", a renamed suite) still ends in TEST SUCCEEDED with no test run.
  if [[ "$pass_status" -eq 0 && "$(count_reported_tests "$pass_first_line")" -eq 0 ]]; then
    echo "error: $pass_label: xcodebuild succeeded but no test ran; check the selection (Swift Testing methods need \"()\", e.g. Suite/test())" >&2
    pass_status=4
  fi
  [[ "$run_status" -ne 0 ]] || run_status="$pass_status"
done

release_lock
if [[ "$run_status" -ne 0 ]]; then
  echo "error: the run failed (exit $run_status); the test-run lock was released" >&2
fi
exit "$run_status"
