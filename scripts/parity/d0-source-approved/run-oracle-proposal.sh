#!/bin/bash
set -euo pipefail

UPSTREAM='/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual'
RESEARCH='/Users/neil/CC/actualist-dev/scripts/parity/d0-source-approved'
EVIDENCE='/Users/neil/CC/actualist-dev/.artifacts/parity-sprint-20260927/d0-source-approved'
EXPECTED_SHA='59fe126f637d858c061e1eeedbef5436c8f2225a'

: "${ACTUAL_ORACLE_SERVER_URL:?set in the environment; never put it in this script}"
: "${ACTUAL_ORACLE_SERVER_PASSWORD:?set in the environment; never put it in this script}"
: "${ACTUAL_ORACLE_ENCRYPTION_PASSWORD:?set in the environment; never put it in this script}"
: "${ACTUAL_ORACLE_RUN_ID:?set a synthetic safe run label}"
: "${ACTUAL_ORACLE_PYTHON:?set the reviewed supervisor interpreter path}"
: "${ACTUAL_ORACLE_CLEANUP:=1}"
export ACTUAL_ORACLE_CLEANUP
export ACTUAL_ORACLE_EVIDENCE_DIR="$EVIDENCE"

if [[ ! "$ACTUAL_ORACLE_SERVER_URL" =~ ^https?://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?$ ]]; then
  echo 'Oracle refused execution: server URL must be a loopback origin without embedded credentials or path.' >&2
  exit 94
fi

test "$(git -C "$UPSTREAM" rev-parse HEAD)" = "$EXPECTED_SHA"
test -z "$(git -C "$UPSTREAM" status --short)"
test "$(node --version)" = 'v24.21.0'
test "$(node "$UPSTREAM/.yarn/releases/yarn-4.17.1.cjs" --version)" = '4.17.1'
(cd "$RESEARCH" && shasum -a 256 -c dev-copy-sha256.txt)

oracle_pid=''
oracle_pgid=''
oracle_reaped=1
oracle_group_verified=0
launch_pending=0
oracle_status=0

oracle_is_active() {
  # Include stopped jobs in the watchdog, but do not mistake a completed job
  # still present in Bash's job table for a live child.
  test -n "$oracle_pid" && { jobs -pr; jobs -ps; } | grep -qx "$oracle_pid"
}

terminate_oracle_group() {
  if test "$oracle_reaped" -eq 1 || test -z "$oracle_pgid"; then
    return
  fi
  if test "$oracle_group_verified" -eq 1; then
    kill -TERM -- "-$oracle_pgid" 2>/dev/null || true
    # TERM can remain pending while a process is stopped. CONT is harmless for a
    # running group and lets the exact stopped group observe TERM during grace.
    kill -CONT -- "-$oracle_pgid" 2>/dev/null || true
  else
    # Until the exclusive group has been proved, only the exact direct child is
    # eligible for termination; never infer group ownership from $! alone.
    kill -TERM "$oracle_pid" 2>/dev/null || true
  fi
  local grace_deadline=$((SECONDS + 10))
  while oracle_is_active && test "$SECONDS" -lt "$grace_deadline"; do
    sleep 1
  done
  if oracle_is_active; then
    if test "$oracle_group_verified" -eq 1; then
      kill -KILL -- "-$oracle_pgid" 2>/dev/null || true
    else
      kill -KILL "$oracle_pid" 2>/dev/null || true
    fi
  fi
}

reap_oracle() {
  if test "$oracle_reaped" -eq 1; then
    return 0
  fi
  if test -z "$oracle_pid"; then
    oracle_reaped=1
    return 0
  fi

  if oracle_is_active; then
    # A wait on a live/stopped process has no deadline. Escalate only against
    # identities already established, and bound confirmation before returning.
    if test "$oracle_group_verified" -eq 1; then
      kill -KILL -- "-$oracle_pgid" 2>/dev/null || true
    else
      kill -KILL "$oracle_pid" 2>/dev/null || true
    fi
    local kill_deadline=$((SECONDS + 10))
    while oracle_is_active && test "$SECONDS" -lt "$kill_deadline"; do
      sleep 1
    done
    if oracle_is_active; then
      return 1
    fi
  fi

  set +e
  wait "$oracle_pid" 2>/dev/null
  oracle_status=$?
  set -e
  if oracle_is_active; then
    # wait can return a stopped status. That is not a reap and must never set
    # oracle_reaped.
    return 1
  fi
  oracle_reaped=1
  return 0
}

recover_pending_launch() {
  if test "$launch_pending" -ne 1; then
    return 0
  fi

  # No background job is permitted before the oracle launch. During this small
  # window, $! is therefore the oracle if it is set; jobs -p is a guarded
  # fallback and must contain at most that one provisional job.
  local saved_last_job="${!:-}"
  local active_jobs
  local job_count
  local sole_job=''
  active_jobs="$(jobs -p)"
  set -- $active_jobs
  job_count=$#
  if test "$job_count" -gt 1; then
    echo 'Oracle EXIT guard found more than one launch-window job; refusing broad termination.' >&2
    return 1
  fi
  if test "$job_count" -eq 1; then
    sole_job=$1
  fi

  if test -z "$oracle_pid"; then
    if test -n "$saved_last_job"; then
      oracle_pid=$saved_last_job
    elif test -n "$sole_job"; then
      oracle_pid=$sole_job
    else
      # A signal arrived after launch_pending was set but before a child existed.
      oracle_reaped=1
      launch_pending=0
      return 0
    fi
  fi
  if test -n "$sole_job" && test "$sole_job" != "$oracle_pid"; then
    echo 'Oracle EXIT guard found a mismatched launch-window job; refusing broad termination.' >&2
    return 1
  fi
  if test -z "$oracle_pgid"; then
    oracle_pgid=$oracle_pid
  fi
  launch_pending=0
  return 0
}

on_exit() {
  local exit_code=$?
  trap - EXIT HUP INT TERM
  if ! recover_pending_launch; then
    # If $! was already saved, it remains the only exact identity eligible for
    # termination. Never act on any additional job discovered here.
    if test -n "$oracle_pid" && test -z "$oracle_pgid"; then
      oracle_pgid=$oracle_pid
    fi
  fi
  if test "$oracle_reaped" -eq 0; then
    if test -n "$oracle_pid" && test -n "$oracle_pgid"; then
      terminate_oracle_group
      if ! reap_oracle; then
        echo 'Oracle EXIT guard could not confirm direct-child termination.' >&2
        exit_code=98
      fi
    elif test -z "$oracle_pid"; then
      # A pre-child signal has nothing to terminate or wait for.
      oracle_reaped=1
    fi
  fi
  exit "$exit_code"
}

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$UPSTREAM"
set -m
if test -n "$(jobs -p)"; then
  echo 'Oracle refused execution: a background job exists before launch.' >&2
  exit 95
fi
launch_pending=1
oracle_reaped=0
# The disposable server keeps NODE_ENV=production. This Vitest process hosts
# @actual-app/api in-process. Actual skips writing metadata.json when
# NODE_ENV=test, so getBudgets cannot see the groupId upload just stored.
# Clear it even if a parent shell exported it.
env -u NODE_ENV NODE_OPTIONS='--experimental-vm-modules --trace-warnings' \
  "$ACTUAL_ORACLE_PYTHON" -B -c '
import os
import sys

try:
    os.setpgid(0, 0)
except OSError as error:
    if os.getpgrp() != os.getpid():
        print(
            f"Oracle refused execution: setpgid failed without an exclusive child group: {error}",
            file=sys.stderr,
        )
        raise SystemExit(96)

if os.getpgrp() != os.getpid():
    print("Oracle refused execution: child did not establish its own process group.", file=sys.stderr)
    raise SystemExit(96)

os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
' node "$UPSTREAM/node_modules/vitest/vitest.mjs" run \
  --configLoader native \
  --config "$RESEARCH/oracle.vitest.config.ts" \
  "$RESEARCH/zip-registration-oracle.test.ts" &
oracle_pid=$!
oracle_pgid=$oracle_pid
launch_pending=0

if ! process_groups="$("$ACTUAL_ORACLE_PYTHON" -B -c \
  'import os, sys; print(os.getpgid(int(sys.argv[1])), os.getpgid(int(sys.argv[2])))' \
  "$oracle_pid" "$$")"; then
  echo 'Oracle refused execution: unable to inspect the exact child and runner process groups.' >&2
  exit 96
fi
if [[ ! "$process_groups" =~ ^([0-9]+)[[:blank:]]+([0-9]+)$ ]]; then
  echo 'Oracle refused execution: malformed process-group query response.' >&2
  exit 96
fi
observed_oracle_pgid="${BASH_REMATCH[1]}"
shell_pgid="${BASH_REMATCH[2]}"
if test -z "$observed_oracle_pgid" || test "$observed_oracle_pgid" != "$oracle_pgid" || test "$oracle_pgid" = "$shell_pgid"; then
  echo 'Oracle refused execution: unable to establish an exclusive child process group.' >&2
  exit 96
fi
oracle_group_verified=1

outer_deadline=$((SECONDS + 290))
timed_out=0
while oracle_is_active; do
  if test "$SECONDS" -ge "$outer_deadline"; then
    timed_out=1
    terminate_oracle_group
    break
  fi
  sleep 1
done

if ! reap_oracle; then
  echo 'Oracle refused handoff: exact child termination could not be confirmed.' >&2
  exit 98
fi
if test "$timed_out" -eq 1; then
  oracle_status=124
fi

if test -n "$(git status --short)"; then
  echo 'Oracle refused handoff: the pinned upstream checkout changed.' >&2
  exit 97
fi

exit "$oracle_status"
