#!/bin/bash

set -euo pipefail

EXPECTED_COMMIT='59fe126f637d858c061e1eeedbef5436c8f2225a'
EXPECTED_TAG='v26.9.0'
EXPECTED_VERSION='26.9.0'
EXPECTED_NODE_PREFIX='v24.21.'
EXPECTED_YARN='4.17.1'
EXPECTED_VITEST='4.1.10'
EXPECTED_BETTER_SQLITE3='12.11.1'
CEILING_SECONDS=180
GRACE_SECONDS=10
KILL_CONFIRM_SECONDS=10

usage() {
  cat >&2 <<'EOF'
Usage: scripts/transaction-command-parity/run-oracle.sh \
  --source-checkout <read-only-pinned-actual-v26.9.0> \
  --actual-checkout <owned-writable-copy-under-this-lane-artifact-root> \
  --evidence <this-checkout>/.artifacts/transaction-command-oracle/evidence \
  --run-label policy-admission-20260929
EOF
  exit 64
}

source_checkout=''
actual_checkout=''
evidence_root=''
run_label=''
while (($# > 0)); do
  case "$1" in
    --source-checkout) source_checkout=${2:-}; shift 2 ;;
    --actual-checkout) actual_checkout=${2:-}; shift 2 ;;
    --evidence) evidence_root=${2:-}; shift 2 ;;
    --run-label) run_label=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$source_checkout" && -n "$actual_checkout" && -n "$evidence_root" && -n "$run_label" ]] || usage
case "$run_label" in
  investigation|post-correction)
    echo "command oracle: run label already spent: $run_label" >&2
    exit 65
    ;;
  policy-admission-20260929) ;;
  *) usage ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
actualist_root=$(cd "$script_dir/../.." && pwd -P)
owned_root_path="$actualist_root/.artifacts/transaction-command-oracle"
[[ -d "$owned_root_path" ]] || { echo 'command oracle: lane-owned artifact root is missing' >&2; exit 66; }
owned_root=$(cd "$owned_root_path" && pwd -P)
source_checkout=$(cd "$source_checkout" && pwd -P)
actual_checkout=$(cd "$actual_checkout" && pwd -P)
python_path=$(command -v python3)
node_path=$(command -v node)
evidence_root=$("$python_path" -c 'import os,sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))' "$evidence_root")

path_is_within() {
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

[[ "$source_checkout" != "$actual_checkout" ]] || { echo 'command oracle: source and candidate must differ' >&2; exit 66; }
case "$actual_checkout" in
  "$owned_root"/*) ;;
  *) echo 'command oracle: writable checkout must be under this lane owned artifact root' >&2; exit 66 ;;
esac
[[ "$evidence_root" == "$owned_root/evidence" ]] || {
  echo 'command oracle: evidence path must be the fixed lane-owned evidence directory' >&2
  exit 66
}
if path_is_within "$source_checkout" "$owned_root" || path_is_within "$source_checkout" "$actual_checkout" || path_is_within "$actual_checkout" "$source_checkout"; then
  echo 'command oracle: source must remain outside the writable lane checkout' >&2
  exit 66
fi

common_dir() {
  local value
  value=$(git -C "$1" rev-parse --git-common-dir)
  [[ "$value" == /* ]] || value="$1/$value"
  (cd "$value" && pwd -P)
}
source_common=$(common_dir "$source_checkout")
actual_common=$(common_dir "$actual_checkout")
[[ "$source_common" != "$actual_common" ]] || { echo 'command oracle: checkouts share Git identity' >&2; exit 66; }

for checkout in "$source_checkout" "$actual_checkout"; do
  [[ "$(git -C "$checkout" rev-parse HEAD)" == "$EXPECTED_COMMIT" ]] || {
    echo "command oracle: checkout is not pinned at $EXPECTED_COMMIT: $checkout" >&2; exit 66;
  }
  [[ "$(git -C "$checkout" describe --tags --exact-match HEAD)" == "$EXPECTED_TAG" ]] || {
    echo "command oracle: checkout is not tagged $EXPECTED_TAG: $checkout" >&2; exit 66;
  }
  if [[ -n "$(git -C "$checkout" status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "command oracle: checkout is not clean: $checkout" >&2; exit 66
  fi
done

yarn_path="$actual_checkout/.yarn/releases/yarn-4.17.1.cjs"
vitest_path="$actual_checkout/node_modules/.bin/vitest"
for dependency in "$yarn_path" "$vitest_path" "$actual_checkout/node_modules/.yarn-state.yml" \
  "$actual_checkout/node_modules/better-sqlite3/build/Release/better_sqlite3.node"; do
  [[ -e "$dependency" ]] || { echo "command oracle: missing dependency $dependency" >&2; exit 66; }
done
[[ -x "$vitest_path" ]] || { echo 'command oracle: Vitest is not executable' >&2; exit 66; }
node_version=$("$node_path" --version)
yarn_version=$("$node_path" "$yarn_path" --version)
core_version=$("$node_path" -p "require('$actual_checkout/packages/loot-core/package.json').version")
vitest_version=$("$node_path" -p "require('$actual_checkout/node_modules/vitest/package.json').version")
better_version=$("$node_path" -p "require('$actual_checkout/node_modules/better-sqlite3/package.json').version")
[[ "$node_version" == "$EXPECTED_NODE_PREFIX"* && "$yarn_version" == "$EXPECTED_YARN" && \
   "$core_version" == "$EXPECTED_VERSION" && "$vitest_version" == "$EXPECTED_VITEST" && \
   "$better_version" == "$EXPECTED_BETTER_SQLITE3" ]] || {
  echo "command oracle: tool versions do not match pinned prerequisites ($node_version, $yarn_version, $core_version, $vitest_version, $better_version)" >&2
  exit 66
}

test_target="$actual_checkout/packages/loot-core/src/server/transactions/transaction-command-parity.test.ts"
support_target="$actual_checkout/packages/loot-core/src/server/transactions/transaction-command-parity-support.ts"
matrix_target="$actual_checkout/packages/loot-core/src/server/transactions/transaction-command-parity-matrix.json"
for target in "$test_target" "$support_target" "$matrix_target"; do
  [[ ! -e "$target" ]] || { echo "command oracle: refusing existing overlay $target" >&2; exit 66; }
done
mkdir -p "$evidence_root"
run_dir="$evidence_root/$run_label"
[[ ! -e "$run_dir" ]] || { echo "command oracle: run label already used: $run_label" >&2; exit 65; }
mkdir "$run_dir"

actual_data="$run_dir/actual-data"
test_source="$script_dir/transaction-command-parity.test.ts"
support_source="$script_dir/transaction-command-parity-support.ts"
matrix_source="$script_dir/matrix.json"
oracle_pid=''
oracle_pgid=''
oracle_reaped=1
launch_pending=0
oracle_status='not-launched'
runner_status=0
runner_signal='none'
runner_state='preparing'
started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
launch_started_at='not-started'
launch_finished_at='not-started'
term_sent_at='not-sent'
kill_sent_at='not-sent'
group_quiescent_at='not-confirmed'
finished_at='pending'
termination_phase='not-started'
group_quiescent='no-child-launched'
cleanup_status='not-started'
timed_out=0

atomic_record() {
  local path=$1
  shift
  local temporary="$path.tmp"
  printf '%s\n' "$@" > "$temporary"
  mv "$temporary" "$path"
}

persist_state() {
  [[ -d "$run_dir" ]] || return 0
  atomic_record "$run_dir/runner-state.env" \
    "state=$runner_state" "started_at=$started_at" "launch_started_at=$launch_started_at" \
    "launch_finished_at=$launch_finished_at" "finished_at=$finished_at" \
    "pid=${oracle_pid:-unknown}" "pgid=${oracle_pgid:-unknown}" \
    "launch_pending=$launch_pending" "leader_reaped=$oracle_reaped" \
    "oracle_status=$oracle_status" "runner_status=$runner_status" \
    "signal=$runner_signal" "timed_out=$timed_out" \
    "termination_phase=$termination_phase" "term_sent_at=$term_sent_at" \
    "kill_sent_at=$kill_sent_at" "group_quiescent=$group_quiescent" \
    "group_quiescent_at=$group_quiescent_at" "cleanup_status=$cleanup_status" \
    "ceiling_seconds=$CEILING_SECONDS" "term_grace_seconds=$GRACE_SECONDS" \
    "kill_confirm_seconds=$KILL_CONFIRM_SECONDS"
}

# 0 means live, 1 means no non-zombie members, 2 means liveness is unverified.
process_group_state() {
  [[ -n "$oracle_pgid" ]] || return 2
  local listing
  listing=$(ps -axo pid=,pgid=,stat=) || return 2
  awk -v group="$oracle_pgid" '$2 == group && $3 !~ /^Z/ { live=1 } END { exit(live ? 0 : 1) }' <<< "$listing"
}

wait_for_group_quiescence() {
  local seconds=$1
  local deadline=$((SECONDS + seconds))
  local state
  while :; do
    if process_group_state; then
      state=live
    else
      state=$?
      if [[ "$state" -eq 1 ]]; then
        group_quiescent=yes
        group_quiescent_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
        persist_state
        return 0
      fi
      group_quiescent=unverified-process-list
      persist_state
      return 1
    fi
    [[ "$SECONDS" -lt "$deadline" ]] || return 1
    sleep 0.2
  done
}

terminate_oracle_group() {
  [[ "$oracle_reaped" -eq 0 ]] || return 0
  if [[ -z "$oracle_pgid" ]]; then
    termination_phase=owned-process-group-unknown
    group_quiescent=unverified-process-group
    persist_state
    return 1
  fi
  local shell_pgid
  if ! shell_pgid=$(ps -o pgid= -p "$$" | tr -d ' ') || [[ -z "$shell_pgid" || "$oracle_pgid" == "$shell_pgid" ]]; then
    termination_phase=runner-group-identity-unverified
    group_quiescent=unverified-process-group
    persist_state
    return 1
  fi
  runner_state=terminating
  termination_phase=term-then-continue-owned-group
  term_sent_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  persist_state
  kill -TERM -- "-$oracle_pgid" 2>/dev/null || true
  # CONT makes stopped members of this exact job-control group observe TERM.
  kill -CONT -- "-$oracle_pgid" 2>/dev/null || true
  if wait_for_group_quiescence "$GRACE_SECONDS"; then
    termination_phase=term-quiescent
    persist_state
    return 0
  fi

  termination_phase=kill-owned-group
  kill_sent_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  persist_state
  kill -KILL -- "-$oracle_pgid" 2>/dev/null || true
  if wait_for_group_quiescence "$KILL_CONFIRM_SECONDS"; then
    termination_phase=kill-quiescent
    persist_state
    return 0
  fi
  termination_phase=quiescence-unconfirmed
  group_quiescent=no
  persist_state
  return 1
}

reap_oracle() {
  [[ "$oracle_reaped" -eq 0 ]] || return 0
  if ! wait_for_group_quiescence 0; then
    terminate_oracle_group || return 1
  fi
  if [[ -n "$oracle_pid" ]]; then
    set +e
    wait "$oracle_pid" 2>/dev/null
    oracle_status=$?
    set -e
  fi
  oracle_reaped=1
  runner_state=leader-reaped-group-quiescent
  group_quiescent=yes
  atomic_record "$run_dir/oracle.exit" "$oracle_status"
  persist_state
  return 0
}

recover_pending_launch() {
  [[ "$launch_pending" -eq 1 ]] || return 0
  local saved_last_job="${!:-}"
  local active_jobs job_count sole_job=''
  active_jobs=$(jobs -p)
  set -- $active_jobs
  job_count=$#
  if [[ "$job_count" -gt 1 ]]; then
    runner_state=launch-window-ambiguous-jobs
    persist_state
    return 1
  fi
  if [[ "$job_count" -eq 1 ]]; then sole_job=$1; fi
  if [[ -n "$sole_job" ]]; then
    oracle_pid=$sole_job
  elif [[ -n "$saved_last_job" ]] && kill -0 "$saved_last_job" 2>/dev/null; then
    oracle_pid=$saved_last_job
  else
    launch_pending=0
    oracle_reaped=1
    group_quiescent=no-child-launched
    runner_state=launch-window-no-child
    persist_state
    return 0
  fi
  if [[ -n "$sole_job" && -n "$saved_last_job" && "$sole_job" != "$saved_last_job" ]]; then
    runner_state=launch-window-identity-mismatch
    persist_state
    return 1
  fi
  oracle_pgid=$oracle_pid
  launch_pending=0
  oracle_reaped=0
  runner_state=launch-window-child-identified
  persist_state
  return 0
}

cleanup_owned_files() {
  local file source expected observed failed=0
  for file in "$test_target" "$support_target" "$matrix_target"; do
    case "$file" in
      "$test_target") source=$test_source ;;
      "$support_target") source=$support_source ;;
      "$matrix_target") source=$matrix_source ;;
    esac
    if [[ -e "$file" ]]; then
      expected=$(shasum -a 256 "$source" | awk '{print $1}')
      observed=$(shasum -a 256 "$file" | awk '{print $1}')
      if [[ "$expected" == "$observed" ]]; then
        rm -f "$file" || failed=1
      else
        failed=1
      fi
    fi
  done
  if [[ -d "$actual_data" ]]; then
    if [[ -f "$actual_data/.owner" && "$(cat "$actual_data/.owner")" == "transaction-command-parity:$run_label:$EXPECTED_COMMIT" ]]; then
      rm -rf "$actual_data" || failed=1
    else
      failed=1
    fi
  fi
  [[ "$failed" -eq 0 ]]
}

finalize_run() {
  local original_status=$1 cleanup_failed=0
  if [[ "$launch_pending" -eq 1 ]] && ! recover_pending_launch; then cleanup_failed=1; fi
  if [[ "$oracle_reaped" -eq 0 ]]; then
    case "$termination_phase" in
      quiescence-unconfirmed|owned-process-group-unknown|runner-group-identity-unverified)
        cleanup_failed=1
        ;;
      *)
        if ! terminate_oracle_group || ! reap_oracle; then cleanup_failed=1; fi
        ;;
    esac
  fi

  if [[ "$cleanup_failed" -eq 0 && ( "$group_quiescent" == yes || "$group_quiescent" == no-child-launched ) ]]; then
    cleanup_status=cleaning-owned-overlays-and-scratch
    runner_state=cleanup
    persist_state
    if ! cleanup_owned_files; then cleanup_failed=1; fi
  fi
  if [[ "$cleanup_failed" -eq 0 ]]; then
    git -C "$actual_checkout" status --short --untracked-files=all > "$run_dir/post-cleanup-git-status.txt" || cleanup_failed=1
    if [[ -s "$run_dir/post-cleanup-git-status.txt" ]]; then cleanup_failed=1; fi
  fi
  if [[ "$cleanup_failed" -ne 0 ]]; then
    cleanup_status=retained-quiescence-or-cleanup-unconfirmed
    runner_state=cleanup-blocked
    [[ "$original_status" -ne 0 ]] || original_status=74
  else
    cleanup_status=complete
    runner_state=complete
  fi
  runner_status=$original_status
  finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  persist_state
  atomic_record "$run_dir/outcome.env" \
    "outcome=$([[ "$cleanup_failed" -eq 0 && "$original_status" -eq 0 ]] && echo completed-success || echo completed-failure)" \
    "status=$original_status" "cleanup_status=$cleanup_status" \
    "group_quiescent=$group_quiescent" "finished_at=$finished_at"
  return "$original_status"
}

on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  finalize_run "$status"
  status=$?
  set -e
  exit "$status"
}

on_signal() {
  local signal_name=$1 status=$2
  runner_signal=$signal_name
  runner_status=$status
  runner_state=signal-received
  persist_state
  exit "$status"
}

atomic_record "$run_dir/runner-state.env" \
  "state=$runner_state" "started_at=$started_at" "pid=unknown" "pgid=unknown" \
  "actual_checkout=$actual_checkout" "source_checkout=$source_checkout"
trap on_exit EXIT
trap 'on_signal HUP 129' HUP
trap 'on_signal INT 130' INT
trap 'on_signal TERM 143' TERM

mkdir "$actual_data"
printf 'transaction-command-parity:%s:%s\n' "$run_label" "$EXPECTED_COMMIT" > "$actual_data/.owner"
atomic_record "$run_dir/actual-data-owner.env" "path=$actual_data" "owner=transaction-command-parity:$run_label:$EXPECTED_COMMIT"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
{
  printf 'actual_commit=%s\nactual_tag=%s\ncore_version=%s\n' "$EXPECTED_COMMIT" "$EXPECTED_TAG" "$core_version"
  printf 'node_version=%s\nyarn_version=%s\nvitest_version=%s\nbetter_sqlite3_version=%s\n' \
    "$node_version" "$yarn_version" "$vitest_version" "$better_version"
  printf 'case_count=39\nceiling_seconds=%s\ntermination_grace_seconds=%s\nkill_confirm_seconds=%s\n' \
    "$CEILING_SECONDS" "$GRACE_SECONDS" "$KILL_CONFIRM_SECONDS"
  printf 'source_checkout=%s\nactual_checkout=%s\nevidence_dir=%s\n' "$source_checkout" "$actual_checkout" "$run_dir"
  printf 'source_git_common=%s\nactual_git_common=%s\n' "$source_common" "$actual_common"
  printf 'harness_sha256=%s\nsupport_sha256=%s\nmatrix_sha256=%s\n' \
    "$(sha256 "$test_source")" "$(sha256 "$support_source")" "$(sha256 "$matrix_source")"
  printf 'merge_source_sha256=%s\n' "$(sha256 "$actual_checkout/packages/loot-core/src/server/transactions/merge.ts")"
  printf 'merge_eligibility_sha256=%s\n' "$(sha256 "$actual_checkout/packages/loot-core/src/shared/merge.ts")"
  printf 'batch_action_source_sha256=%s\n' "$(sha256 "$actual_checkout/packages/desktop-client/src/hooks/useTransactionBatchActions.ts")"
  printf 'transaction_helpers_sha256=%s\n' "$(sha256 "$actual_checkout/packages/loot-core/src/shared/transactions.ts")"
  printf 'transaction_handlers_sha256=%s\n' "$(sha256 "$actual_checkout/packages/loot-core/src/server/transactions/app.ts")"
  printf 'undo_source_sha256=%s\n' "$(sha256 "$actual_checkout/packages/loot-core/src/server/undo.ts")"
  printf 'readonly_source_merge_sha256=%s\n' "$(sha256 "$source_checkout/packages/loot-core/src/server/transactions/merge.ts")"
  printf 'readonly_source_batch_action_sha256=%s\n' "$(sha256 "$source_checkout/packages/desktop-client/src/hooks/useTransactionBatchActions.ts")"
} > "$run_dir/provenance.env"

cat > "$run_dir/exact-command.txt" <<EOF
cd '$actual_checkout' && PATH='$(dirname "$node_path")':\$PATH TZ=UTC ENV=node ACTUAL_DATA_DIR='$actual_data' ACTUAL_TRANSACTION_COMMAND_PARITY_EVIDENCE='$run_dir/oracle-result.json' ACTUAL_TRANSACTION_COMMAND_PARITY_COMMIT='$EXPECTED_COMMIT' ACTUAL_TRANSACTION_COMMAND_PARITY_TAG='$EXPECTED_TAG' ACTUAL_TRANSACTION_COMMAND_PARITY_VERSION='$EXPECTED_VERSION' '$node_path' '$yarn_path' workspace @actual-app/core exec '$vitest_path' --run src/server/transactions/transaction-command-parity.test.ts --reporter=verbose --bail=1
EOF

mkdir "$run_dir/oracle-source"
cp "$script_dir/README.md" "$matrix_source" "$test_source" "$support_source" "$script_dir/run-oracle.sh" "$run_dir/oracle-source/"
cp "$test_source" "$test_target"
cp "$support_source" "$support_target"
cp "$matrix_source" "$matrix_target"
runner_state=overlay-ready
persist_state

set -m
if [[ -n "$(jobs -p)" ]]; then
  runner_state=unexpected-job-before-launch
  runner_status=74
  persist_state
  exit 74
fi
launch_pending=1
oracle_reaped=0
runner_state=launch-pending
group_quiescent=launch-window
launch_started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
persist_state
(
  cd "$actual_checkout"
  export PATH="$(dirname "$node_path"):$PATH"
  export TZ=UTC ENV=node
  export ACTUAL_DATA_DIR="$actual_data"
  export ACTUAL_TRANSACTION_COMMAND_PARITY_EVIDENCE="$run_dir/oracle-result.json"
  export ACTUAL_TRANSACTION_COMMAND_PARITY_COMMIT="$EXPECTED_COMMIT"
  export ACTUAL_TRANSACTION_COMMAND_PARITY_TAG="$EXPECTED_TAG"
  export ACTUAL_TRANSACTION_COMMAND_PARITY_VERSION="$EXPECTED_VERSION"
  exec "$node_path" "$yarn_path" workspace @actual-app/core exec "$vitest_path" --run \
    src/server/transactions/transaction-command-parity.test.ts --reporter=verbose --bail=1
) > "$run_dir/oracle.log" 2>&1 &
oracle_pid=$!
oracle_pgid=$oracle_pid
launch_pending=0
launch_finished_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
runner_state=launched
group_quiescent=not-yet-confirmed
persist_state

runner_pgid=$(ps -o pgid= -p "$$" | tr -d ' ')
observed_oracle_pgid=$(ps -o pgid= -p "$oracle_pid" | tr -d ' ' || true)
if [[ -z "$runner_pgid" ]] || \
   [[ -n "$observed_oracle_pgid" && "$observed_oracle_pgid" != "$oracle_pgid" ]] || \
   [[ "$oracle_pgid" == "$runner_pgid" ]]; then
  runner_state=exclusive-process-group-not-established
  runner_status=74
  persist_state
  exit 74
fi
runner_state=process-group-verified
persist_state

deadline=$((SECONDS + CEILING_SECONDS))
while :; do
  if process_group_state; then
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      timed_out=1
      runner_status=124
      termination_phase=deadline
      persist_state
      terminate_oracle_group || { runner_status=74; exit 74; }
      break
    fi
    sleep 0.2
  else
    group_state=$?
    if [[ "$group_state" -eq 1 ]]; then
      group_quiescent=yes
      group_quiescent_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
      persist_state
      break
    fi
    runner_state=process-group-inspection-failed
    runner_status=74
    persist_state
    exit 74
  fi
done

if ! reap_oracle; then
  runner_state=reap-or-quiescence-unconfirmed
  runner_status=74
  persist_state
  exit 74
fi
if [[ "$timed_out" -eq 1 ]]; then runner_status=124; else runner_status=$oracle_status; fi
runner_state=oracle-finished
persist_state
exit "$runner_status"
