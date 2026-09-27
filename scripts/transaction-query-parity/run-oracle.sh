#!/bin/bash

set -e -u -o pipefail

EXPECTED_COMMIT='59fe126f637d858c061e1eeedbef5436c8f2225a'
EXPECTED_TAG='v26.9.0'
EXPECTED_VERSION='26.9.0'
EXPECTED_NODE_PREFIX='v24.21.'
EXPECTED_YARN='4.17.1'
EXPECTED_BETTER_SQLITE3='12.11.1'
ORACLE_TZ='UTC'
CEILING_SECONDS=180
TERMINATION_GRACE_SECONDS=10

usage() {
  cat >&2 <<'EOF'
Usage: scripts/transaction-query-parity/run-oracle.sh \
  --source-checkout <read-only-pinned-actual-v26.9.0-source> \
  --actual-checkout <writable-distinct-dependency-ready-clone> \
  --evidence <evidence-root-under-.artifacts> \
  --run-label <investigation|post-correction>
EOF
  exit 64
}

source_checkout=''
actual_checkout=''
evidence_root=''
run_label=''
while (($# > 0)); do
  case "$1" in
    --source-checkout)
      source_checkout=${2:-}
      shift 2
      ;;
    --actual-checkout)
      actual_checkout=${2:-}
      shift 2
      ;;
    --evidence)
      evidence_root=${2:-}
      shift 2
      ;;
    --run-label)
      run_label=${2:-}
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$source_checkout" && -n "$actual_checkout" ]] || usage
[[ -n "$evidence_root" && -n "$run_label" ]] || usage
[[ "$run_label" == 'investigation' || "$run_label" == 'post-correction' ]] || usage

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
actualist_root=$(cd "$script_dir/../.." && pwd -P)
source_checkout=$(cd "$source_checkout" && pwd -P)
actual_checkout=$(cd "$actual_checkout" && pwd -P)
python_path=$(command -v python3)
evidence_root=$("$python_path" -c \
  'import os, sys; print(os.path.realpath(os.path.abspath(sys.argv[1])))' \
  "$evidence_root")

path_is_equal_or_nested() {
  local candidate=$1
  local parent=$2
  case "$candidate" in
    "$parent"|"$parent"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

case "$evidence_root" in
  */.artifacts/*) ;;
  *)
    echo 'transaction query parity oracle: evidence root must be below a .artifacts directory' >&2
    exit 66
    ;;
esac
if path_is_equal_or_nested "$evidence_root" "$source_checkout"; then
  echo 'transaction query parity oracle: evidence root must be outside the shared source checkout' >&2
  exit 66
fi
if path_is_equal_or_nested "$evidence_root" "$actual_checkout"; then
  echo 'transaction query parity oracle: evidence root must be outside the writable clone' >&2
  exit 66
fi

git_common_directory() {
  local checkout=$1
  local common
  common=$(git -C "$checkout" rev-parse --git-common-dir)
  if [[ "$common" != /* ]]; then
    common="$checkout/$common"
  fi
  (cd "$common" && pwd -P)
}

source_git_common=$(git_common_directory "$source_checkout")
actual_git_common=$(git_common_directory "$actual_checkout")
if [[ "$source_checkout" == "$actual_checkout" ]]; then
  echo 'transaction query parity oracle: writable clone is the shared pinned source' >&2
  exit 66
fi
if [[ "$source_git_common" == "$actual_git_common" ]]; then
  echo 'transaction query parity oracle: writable clone shares the source Git identity' >&2
  exit 66
fi

mkdir -p "$evidence_root"
evidence_root=$(cd "$evidence_root" && pwd -P)
run_dir="$evidence_root/$run_label"
marker="$run_dir/started"
if [[ -e "$run_dir" ]]; then
  echo "transaction query parity oracle: run label already spent: $run_label" >&2
  exit 65
fi
mkdir -p "$run_dir"

record_preflight_exit() {
  local exit_status=$?
  trap - EXIT
  if [[ "$exit_status" -ne 0 ]]; then
    printf '%s\n' "$exit_status" > "$run_dir/oracle.exit"
    printf 'outcome=preflight-failure\nstatus=%s\n' "$exit_status" > \
      "$run_dir/outcome.env"
  fi
  exit "$exit_status"
}
trap record_preflight_exit EXIT

node_path=$(command -v node)
yarn_release_path="$actual_checkout/.yarn/releases/yarn-4.17.1.cjs"
yarn_lock_path="$actual_checkout/yarn.lock"
yarn_configuration_path="$actual_checkout/.yarnrc.yml"
install_state_path="$actual_checkout/node_modules/.yarn-state.yml"
vitest_path="$actual_checkout/node_modules/.bin/vitest"
vitest_package="$actual_checkout/node_modules/vitest/package.json"
better_package="$actual_checkout/node_modules/better-sqlite3/package.json"
better_binary="$actual_checkout/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
for dependency in \
  "$yarn_release_path" \
  "$yarn_lock_path" \
  "$yarn_configuration_path" \
  "$install_state_path" \
  "$vitest_path" \
  "$vitest_package" \
  "$better_package" \
  "$better_binary"; do
  [[ -e "$dependency" ]] || {
    echo "transaction query parity oracle: missing prepared dependency $dependency" >&2
    exit 66
  }
done
[[ -x "$vitest_path" ]] || {
  echo "transaction query parity oracle: Vitest is not executable: $vitest_path" >&2
  exit 66
}

vitest_real_path=$("$python_path" -c \
  'import os, sys; print(os.path.realpath(sys.argv[1]))' "$vitest_path")
observed_commit=$(git -C "$actual_checkout" rev-parse HEAD)
observed_tag=$(git -C "$actual_checkout" describe --tags --exact-match HEAD)
source_commit=$(git -C "$source_checkout" rev-parse HEAD)
source_tag=$(git -C "$source_checkout" describe --tags --exact-match HEAD)
observed_version=$("$node_path" -p "require(process.argv[1]).version" \
  "$actual_checkout/packages/loot-core/package.json")
observed_node=$("$node_path" --version)
observed_yarn=$("$node_path" "$yarn_release_path" --version)
observed_vitest=$("$node_path" -p "require(process.argv[1]).version" \
  "$vitest_package")
observed_better=$("$node_path" -p "require(process.argv[1]).version" \
  "$better_package")

if [[ "$observed_commit" != "$EXPECTED_COMMIT" || "$source_commit" != "$EXPECTED_COMMIT" ]]; then
  echo 'transaction query parity oracle: source or writable clone is not at the pinned commit' >&2
  exit 66
fi
if [[ "$observed_tag" != "$EXPECTED_TAG" || "$source_tag" != "$EXPECTED_TAG" ]]; then
  echo 'transaction query parity oracle: source or writable clone is not at the pinned tag' >&2
  exit 66
fi
if [[ "$observed_version" != "$EXPECTED_VERSION" ]]; then
  echo "transaction query parity oracle: expected core $EXPECTED_VERSION, found $observed_version" >&2
  exit 66
fi
if [[ "$observed_node" != "$EXPECTED_NODE_PREFIX"* ]]; then
  echo "transaction query parity oracle: expected Node ${EXPECTED_NODE_PREFIX}x, found $observed_node" >&2
  exit 66
fi
if [[ "$observed_yarn" != "$EXPECTED_YARN" ]]; then
  echo "transaction query parity oracle: expected Yarn $EXPECTED_YARN, found $observed_yarn" >&2
  exit 66
fi
if [[ "$observed_better" != "$EXPECTED_BETTER_SQLITE3" ]]; then
  echo "transaction query parity oracle: expected better-sqlite3 $EXPECTED_BETTER_SQLITE3, found $observed_better" >&2
  exit 66
fi

git -C "$source_checkout" status --short --untracked-files=no > \
  "$run_dir/source-git-status.txt"
if [[ -s "$run_dir/source-git-status.txt" ]]; then
  echo 'transaction query parity oracle: shared source has tracked changes' >&2
  exit 66
fi
git -C "$actual_checkout" status --short --untracked-files=all > \
  "$run_dir/pre-overlay-git-status.txt"
if [[ -s "$run_dir/pre-overlay-git-status.txt" ]]; then
  echo 'transaction query parity oracle: writable clone is not clean before overlay' >&2
  exit 66
fi

target_dir="$actual_checkout/packages/loot-core/src/server/transactions"
test_target="$target_dir/transaction-query-parity.test.ts"
support_target="$target_dir/transaction-query-parity-support.ts"
if [[ -e "$test_target" || -e "$support_target" ]]; then
  echo 'transaction query parity oracle: overlay target already exists' >&2
  exit 66
fi

actual_data_dir="$run_dir/actual-data"
actual_data_owner_marker="$actual_data_dir/.actualist-transaction-query-parity-owner"
actual_data_owner="transaction-query-parity:$run_label:$observed_commit"
actual_data_prepared=0

supervisor_pid=''
supervisor_expected=0
supervisor_pid_file="$run_dir/supervisor.pid"
supervisor_pgid_file="$run_dir/supervisor-child-pgid"

cleanup_overlay() {
  rm -f "$test_target" "$support_target"
}

record_actual_data_cleanup() {
  local result=$1
  local reason=$2
  local termination_confirmed=$3
  {
    printf 'actual_data_dir=%s\n' "$actual_data_dir"
    printf 'ownership_marker=%s\n' "$actual_data_owner_marker"
    printf 'result=%s\n' "$result"
    printf 'reason=%s\n' "$reason"
    printf 'termination_confirmed=%s\n' "$termination_confirmed"
    printf 'non_scratch_evidence_retained=true\n'
  } > "$run_dir/actual-data-cleanup.env"
}

prepare_actual_data_dir() {
  if [[ -e "$actual_data_dir" ]]; then
    echo "transaction query parity oracle: owned data directory already exists: $actual_data_dir" >&2
    return 1
  fi
  mkdir "$actual_data_dir"
  actual_data_prepared=1
  printf '%s\n' "$actual_data_owner" > "$actual_data_owner_marker"
}

cleanup_actual_data_dir() {
  local reason=$1
  if [[ "$actual_data_prepared" -ne 1 ]]; then
    if [[ ! -f "$run_dir/actual-data-cleanup.env" ]]; then
      record_actual_data_cleanup not-created "$reason" true
    fi
    return 0
  fi
  if [[ "$actual_data_dir" != "$run_dir/actual-data" || \
        ! -d "$actual_data_dir" || \
        ! -f "$actual_data_owner_marker" || \
        "$(cat "$actual_data_owner_marker")" != "$actual_data_owner" ]]; then
    record_actual_data_cleanup retained-ownership-unconfirmed "$reason" true
    return 1
  fi
  if ! rm -rf -- "$actual_data_dir" || [[ -e "$actual_data_dir" ]]; then
    record_actual_data_cleanup retained-removal-failed "$reason" true
    return 1
  fi
  actual_data_prepared=0
  record_actual_data_cleanup removed "$reason" true
}

retain_actual_data_dir() {
  local reason=$1
  if [[ "$actual_data_prepared" -eq 1 && -d "$actual_data_dir" ]]; then
    record_actual_data_cleanup retained "$reason" false
  else
    record_actual_data_cleanup not-created "$reason" false
  fi
}

owned_identifier() {
  local path=$1
  local value=''
  if [[ -f "$path" ]]; then
    value=$(cat "$path")
  fi
  if [[ "$value" =~ ^[0-9]+$ && "$value" -gt 1 ]]; then
    printf '%s\n' "$value"
  fi
}

owned_supervisor_pid() {
  local pid=$supervisor_pid
  if [[ -z "$pid" ]]; then
    pid=$(owned_identifier "$supervisor_pid_file")
  fi
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; then
    printf '%s\n' "$pid"
  fi
}

process_is_running() {
  local pid=$1
  local state=''
  [[ -n "$pid" ]] || return 1
  state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  [[ -n "$state" && "$state" != Z* ]]
}

process_group_is_running() {
  local pgid=$1
  [[ -n "$pgid" ]] || return 1
  /bin/kill -0 "-$pgid" 2>/dev/null
}

wait_for_supervisor_identity() {
  local attempts=$((TERMINATION_GRACE_SECONDS * 10))
  local attempt
  [[ "$supervisor_expected" -eq 1 ]] || return 0
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    if [[ -n "$(owned_supervisor_pid)" ]]; then
      return 0
    fi
    sleep 0.1
  done
}

signal_owned_processes() {
  local signal_name=$1
  local pgid=''
  local pid=''
  wait_for_supervisor_identity
  pgid=$(owned_identifier "$supervisor_pgid_file")
  pid=$(owned_supervisor_pid)
  if [[ -n "$pgid" ]]; then
    /bin/kill "-$signal_name" "-$pgid" 2>/dev/null || true
  fi
  if process_is_running "$pid"; then
    /bin/kill "-$signal_name" "$pid" 2>/dev/null || true
  fi
}

wait_for_owned_termination() {
  local attempts=$((TERMINATION_GRACE_SECONDS * 10))
  local pgid=''
  local pid=''
  local attempt
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    pgid=$(owned_identifier "$supervisor_pgid_file")
    pid=$(owned_supervisor_pid)
    if ! process_is_running "$pid" && ! process_group_is_running "$pgid"; then
      if [[ -n "$pid" ]]; then
        wait "$pid" 2>/dev/null || true
      fi
      return 0
    fi
    sleep 0.1
  done
  return 1
}

terminate_owned_processes() {
  signal_owned_processes TERM
  if wait_for_owned_termination; then
    return 0
  fi
  signal_owned_processes KILL
  wait_for_owned_termination
}

record_run_outcome() {
  local exit_status=$1
  local outcome=$2
  printf '%s\n' "$exit_status" > "$run_dir/oracle.exit"
  printf 'outcome=%s\nstatus=%s\n' "$outcome" "$exit_status" > \
    "$run_dir/outcome.env"
}

capture_post_cleanup_status() {
  git -C "$actual_checkout" status --short --untracked-files=all > \
    "$run_dir/post-cleanup-git-status.txt"
}

shell_interrupted() {
  local exit_status=$1
  trap - EXIT HUP INT TERM
  if terminate_owned_processes; then
    cleanup_overlay
    if cleanup_actual_data_dir interrupted-owned-processes-terminated; then
      record_run_outcome "$exit_status" interrupted
    else
      record_run_outcome "$exit_status" interrupted-data-cleanup-blocked
    fi
  else
    retain_actual_data_dir interrupted-termination-unconfirmed
    record_run_outcome "$exit_status" interrupted-cleanup-blocked
  fi
  capture_post_cleanup_status
  exit "$exit_status"
}

shell_exited() {
  local exit_status=$1
  trap - EXIT HUP INT TERM
  if [[ "$supervisor_expected" -eq 1 ]] && ! terminate_owned_processes; then
    if [[ "$exit_status" -eq 0 ]]; then
      exit_status=74
    fi
    retain_actual_data_dir exit-termination-unconfirmed
    record_run_outcome "$exit_status" exit-cleanup-blocked
    capture_post_cleanup_status
    exit "$exit_status"
  fi
  cleanup_overlay
  if ! cleanup_actual_data_dir exit-after-confirmed-termination; then
    if [[ "$exit_status" -eq 0 ]]; then
      exit_status=74
    fi
    record_run_outcome "$exit_status" exit-data-cleanup-blocked
  fi
  if [[ ! -f "$run_dir/outcome.env" ]]; then
    record_run_outcome "$exit_status" pre-execution-failure
  fi
  capture_post_cleanup_status
  exit "$exit_status"
}

trap - EXIT
trap 'shell_exited $?' EXIT
trap 'shell_interrupted 129' HUP
trap 'shell_interrupted 130' INT
trap 'shell_interrupted 143' TERM

prepare_actual_data_dir
cp "$script_dir/transaction-query-parity.test.ts" "$test_target"
cp "$script_dir/transaction-query-parity-support.ts" "$support_target"
mkdir -p "$run_dir/oracle-source"
cp "$script_dir/README.md" "$run_dir/oracle-source/README.md"
cp "$script_dir/run-oracle.sh" "$run_dir/oracle-source/run-oracle.sh"
cp "$script_dir/transaction-query-parity.test.ts" \
  "$run_dir/oracle-source/transaction-query-parity.test.ts"
cp "$script_dir/transaction-query-parity-support.ts" \
  "$run_dir/oracle-source/transaction-query-parity-support.ts"

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

{
  printf 'actual_commit=%s\n' "$observed_commit"
  printf 'actual_tag=%s\n' "$observed_tag"
  printf 'core_version=%s\n' "$observed_version"
  printf 'node_version=%s\n' "$observed_node"
  printf 'yarn_version=%s\n' "$observed_yarn"
  printf 'vitest_version=%s\n' "$observed_vitest"
  printf 'better_sqlite3_version=%s\n' "$observed_better"
  printf 'node_path=%s\n' "$node_path"
  printf 'yarn_release_path=%s\n' "$yarn_release_path"
  printf 'vitest_path=%s\n' "$vitest_path"
  printf 'vitest_real_path=%s\n' "$vitest_real_path"
  printf 'python_path=%s\n' "$python_path"
  printf 'tz=%s\n' "$ORACLE_TZ"
  printf 'expected_case_count=46\n'
  printf 'ceiling_seconds=%s\n' "$CEILING_SECONDS"
  printf 'termination_grace_seconds=%s\n' "$TERMINATION_GRACE_SECONDS"
  printf 'run_label=%s\n' "$run_label"
  printf 'source_checkout=%s\n' "$source_checkout"
  printf 'actual_checkout=%s\n' "$actual_checkout"
  printf 'source_git_common=%s\n' "$source_git_common"
  printf 'actual_git_common=%s\n' "$actual_git_common"
  printf 'actualist_source=%s\n' "$actualist_root"
  printf 'actual_data_dir=%s\n' "$actual_data_dir"
  printf 'actual_data_dir_source=runner-owned-explicit\n'
  printf 'actual_data_dir_inheritance=overridden\n'
  printf 'actual_data_owner_marker=%s\n' "$actual_data_owner_marker"
  printf 'actual_data_owner_marker_sha256=%s\n' \
    "$(hash_file "$actual_data_owner_marker")"
  printf 'node_sha256=%s\n' "$(hash_file "$node_path")"
  printf 'yarn_release_sha256=%s\n' "$(hash_file "$yarn_release_path")"
  printf 'yarn_lock_sha256=%s\n' "$(hash_file "$yarn_lock_path")"
  printf 'yarn_configuration_sha256=%s\n' \
    "$(hash_file "$yarn_configuration_path")"
  printf 'yarn_state_sha256=%s\n' "$(hash_file "$install_state_path")"
  printf 'vitest_sha256=%s\n' "$(hash_file "$vitest_real_path")"
  printf 'better_sqlite3_package_sha256=%s\n' "$(hash_file "$better_package")"
  printf 'better_sqlite3_binary_sha256=%s\n' "$(hash_file "$better_binary")"
  printf 'readme_sha256=%s\n' "$(hash_file "$script_dir/README.md")"
  printf 'runner_sha256=%s\n' "$(hash_file "$script_dir/run-oracle.sh")"
  printf 'test_sha256=%s\n' "$(hash_file "$test_target")"
  printf 'support_sha256=%s\n' "$(hash_file "$support_target")"
  printf 'filter_handler_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/server/filters/app.ts")"
  printf 'condition_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/server/rules/condition.ts")"
  printf 'condition_aql_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/server/transactions/transaction-rules.ts")"
  printf 'rule_condition_types_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/types/models/rule.ts")"
  printf 'transaction_filter_types_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/types/models/transaction-filter.ts")"
  printf 'transaction_executor_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/server/aql/schema/executors.ts")"
  printf 'filter_ui_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/desktop-client/src/components/filters/FiltersMenu.tsx")"
  printf 'saved_filter_ui_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/desktop-client/src/components/filters/SavedFilterMenuButton.tsx")"
  printf 'transaction_query_ui_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/desktop-client/src/queries/index.ts")"
  printf 'filter_schema_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/migrations/1688749527273_transaction_filters.sql")"
  printf 'source_filter_handler_sha256=%s\n' \
    "$(hash_file "$source_checkout/packages/loot-core/src/server/filters/app.ts")"
  printf 'source_transaction_executor_sha256=%s\n' \
    "$(hash_file "$source_checkout/packages/loot-core/src/server/aql/schema/executors.ts")"
  printf 'electron_fs_sha256=%s\n' \
    "$(hash_file "$actual_checkout/packages/loot-core/src/platform/server/fs/index.electron.ts")"
} > "$run_dir/provenance.env"

cat > "$run_dir/exact-command.txt" <<EOF
cd '$actual_checkout' && PATH='$(dirname "$node_path")':"\$PATH" TZ='$ORACLE_TZ' ENV=node ACTUAL_DATA_DIR='$actual_data_dir' ACTUAL_TRANSACTION_QUERY_PARITY_EVIDENCE='$run_dir/oracle-result.json' ACTUAL_TRANSACTION_QUERY_PARITY_COMMIT='$observed_commit' ACTUAL_TRANSACTION_QUERY_PARITY_TAG='$observed_tag' ACTUAL_TRANSACTION_QUERY_PARITY_VERSION='$observed_version' '$node_path' '$yarn_release_path' workspace @actual-app/core exec '$vitest_path' --run src/server/transactions/transaction-query-parity.test.ts --reporter=verbose --bail=1
EOF

printf '%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$marker"
set +e
supervisor_expected=1
"$python_path" - \
  "$CEILING_SECONDS" \
  "$TERMINATION_GRACE_SECONDS" \
  "$actual_checkout" \
  "$run_dir/oracle.log" \
  "$run_dir/oracle-result.json" \
  "$supervisor_pid_file" \
  "$supervisor_pgid_file" \
  "$ORACLE_TZ" \
  "$actual_data_dir" \
  "$observed_commit" \
  "$observed_tag" \
  "$observed_version" \
  "$node_path" \
  "$yarn_release_path" \
  "$vitest_path" <<'PY' &
import os
import signal
import subprocess
import sys
import time

ceiling = int(sys.argv[1])
grace = int(sys.argv[2])
cwd = sys.argv[3]
log_path = sys.argv[4]
result_path = sys.argv[5]
supervisor_pid_path = sys.argv[6]
pgid_path = sys.argv[7]
timezone = sys.argv[8]
actual_data_dir = sys.argv[9]
actual_commit = sys.argv[10]
actual_tag = sys.argv[11]
actual_version = sys.argv[12]
command = [
    sys.argv[13],
    sys.argv[14],
    'workspace',
    '@actual-app/core',
    'exec',
    sys.argv[15],
    '--run',
    'src/server/transactions/transaction-query-parity.test.ts',
    '--reporter=verbose',
    '--bail=1',
]
environment = os.environ.copy()
environment.update({
    'ACTUAL_DATA_DIR': actual_data_dir,
    'ACTUAL_TRANSACTION_QUERY_PARITY_EVIDENCE': result_path,
    'ACTUAL_TRANSACTION_QUERY_PARITY_COMMIT': actual_commit,
    'ACTUAL_TRANSACTION_QUERY_PARITY_TAG': actual_tag,
    'ACTUAL_TRANSACTION_QUERY_PARITY_VERSION': actual_version,
    'ENV': 'node',
    'PATH': os.path.dirname(sys.argv[13]) + os.pathsep + environment['PATH'],
    'TZ': timezone,
})
requested_signal = None

def request_stop(signum, _frame):
    global requested_signal
    requested_signal = signum

signal.signal(signal.SIGHUP, request_stop)
signal.signal(signal.SIGINT, request_stop)
signal.signal(signal.SIGTERM, request_stop)

with open(supervisor_pid_path, 'w', encoding='utf-8') as pid_file:
    pid_file.write(f'{os.getpid()}\n')
    pid_file.flush()
    os.fsync(pid_file.fileno())

def signal_group(process_group, requested):
    try:
        os.killpg(process_group, requested)
    except ProcessLookupError:
        pass

with open(log_path, 'wb') as output:
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=environment,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    with open(pgid_path, 'w', encoding='utf-8') as pgid_file:
        pgid_file.write(f'{process.pid}\n')
        pgid_file.flush()
        os.fsync(pgid_file.fileno())
    deadline = time.monotonic() + ceiling
    stop_status = None
    while process.poll() is None:
        if requested_signal is not None:
            stop_status = 128 + requested_signal
            break
        if time.monotonic() >= deadline:
            stop_status = 124
            break
        time.sleep(0.2)

    if stop_status is not None and process.poll() is None:
        signal_group(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            signal_group(process.pid, signal.SIGKILL)
            process.wait()

    if stop_status is not None:
        sys.exit(stop_status)
    return_code = process.returncode
    sys.exit(128 - return_code if return_code < 0 else return_code)
PY
supervisor_pid=$!
wait "$supervisor_pid"
oracle_status=$?
supervisor_pid=''
set -e

owned_process_cleanup='not-needed'
if ! wait_for_owned_termination; then
  owned_process_cleanup='required'
  if terminate_owned_processes; then
    owned_process_cleanup='terminated-and-confirmed'
    if [[ "$oracle_status" -eq 0 ]]; then
      oracle_status=74
    fi
  else
    if [[ "$oracle_status" -eq 0 ]]; then
      oracle_status=74
    fi
    retain_actual_data_dir oracle-finished-termination-unconfirmed
    record_run_outcome "$oracle_status" oracle-finished-cleanup-blocked
    capture_post_cleanup_status
    trap - EXIT HUP INT TERM
    exit "$oracle_status"
  fi
fi
supervisor_expected=0

case "$oracle_status" in
  0) outcome='completed-success' ;;
  124) outcome='timeout' ;;
  129|130|143) outcome='interrupted' ;;
  *) outcome='completed-failure' ;;
esac
if [[ "$owned_process_cleanup" == 'terminated-and-confirmed' ]]; then
  outcome="$outcome-owned-processes-terminated"
fi
record_run_outcome "$oracle_status" "$outcome"

cleanup_overlay
if ! cleanup_actual_data_dir oracle-finished-owned-processes-terminated; then
  if [[ "$oracle_status" -eq 0 ]]; then
    oracle_status=74
  fi
  record_run_outcome "$oracle_status" "$outcome-data-cleanup-blocked"
fi
capture_post_cleanup_status
if [[ -s "$run_dir/post-cleanup-git-status.txt" && "$oracle_status" -eq 0 ]]; then
  oracle_status=74
  record_run_outcome "$oracle_status" post-cleanup-dirty
fi
trap - EXIT HUP INT TERM
exit "$oracle_status"
