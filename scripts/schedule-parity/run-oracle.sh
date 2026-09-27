#!/bin/bash

set -e -u -o pipefail

EXPECTED_COMMIT='59fe126f637d858c061e1eeedbef5436c8f2225a'
EXPECTED_TAG='v26.9.0'
EXPECTED_VERSION='26.9.0'
EXPECTED_NODE_PREFIX='v24.21.'
EXPECTED_YARN='4.17.1'
ORACLE_TZ='UTC'
CEILING_SECONDS=600
TERMINATION_GRACE_SECONDS=10

usage() {
  cat >&2 <<'EOF'
Usage: scripts/schedule-parity/run-oracle.sh \
  --source-checkout <read-only-pinned-actual-v26.9.0-source> \
  --actual-checkout <writable-distinct-clone> \
  --evidence <evidence-root> \
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

if path_is_equal_or_nested "$evidence_root" "$source_checkout"; then
  echo 'schedule parity oracle: evidence root must be outside the shared source checkout' >&2
  exit 66
fi
if path_is_equal_or_nested "$evidence_root" "$actual_checkout"; then
  echo 'schedule parity oracle: evidence root must be outside the writable clone' >&2
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
  echo 'schedule parity oracle: writable checkout is the shared pinned source' >&2
  exit 66
fi
if [[ "$source_git_common" == "$actual_git_common" ]]; then
  echo 'schedule parity oracle: writable checkout shares the source git worktree identity' >&2
  exit 66
fi

mkdir -p "$evidence_root"
evidence_root=$(cd "$evidence_root" && pwd -P)
run_dir="$evidence_root/$run_label"
marker="$run_dir/started"
if [[ -e "$marker" ]]; then
  echo "schedule parity oracle: run label already spent: $run_label" >&2
  exit 65
fi
mkdir -p "$run_dir"
synthetic_data_dir="$run_dir/synthetic-data"
synthetic_data_cleanup_file="$run_dir/synthetic-data-cleanup.env"
synthetic_data_created=0
if [[ -e "$synthetic_data_dir" ]]; then
  echo 'schedule parity oracle: synthetic data directory already exists' >&2
  exit 66
fi

node_path=$(command -v node)
yarn_bootstrap_path=$(command -v yarn || true)
yarn_release_path="$actual_checkout/.yarn/releases/yarn-4.17.1.cjs"
vitest_path="$actual_checkout/node_modules/.bin/vitest"
vitest_package="$actual_checkout/node_modules/vitest/package.json"
[[ -f "$yarn_release_path" ]] || {
  echo "schedule parity oracle: missing Yarn release $yarn_release_path" >&2
  exit 66
}
[[ -x "$vitest_path" ]] || {
  echo "schedule parity oracle: missing Vitest executable $vitest_path" >&2
  exit 66
}
[[ -f "$vitest_package" ]] || {
  echo "schedule parity oracle: missing Vitest package metadata $vitest_package" >&2
  exit 66
}

vitest_link=$(readlink "$vitest_path" || true)
if [[ -n "$vitest_link" ]]; then
  if [[ "$vitest_link" == /* ]]; then
    vitest_real_path="$vitest_link"
  else
    vitest_real_path=$(cd "$(dirname "$vitest_path")/$(dirname "$vitest_link")" && pwd -P)/$(basename "$vitest_link")
  fi
else
  vitest_real_path="$vitest_path"
fi

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

if [[ "$observed_commit" != "$EXPECTED_COMMIT" || "$source_commit" != "$EXPECTED_COMMIT" ]]; then
  echo 'schedule parity oracle: source or writable clone is not at the pinned commit' >&2
  exit 66
fi
if [[ "$observed_tag" != "$EXPECTED_TAG" || "$source_tag" != "$EXPECTED_TAG" ]]; then
  echo 'schedule parity oracle: source or writable clone is not at the pinned tag' >&2
  exit 66
fi
if [[ "$observed_version" != "$EXPECTED_VERSION" ]]; then
  echo "schedule parity oracle: expected core $EXPECTED_VERSION, found $observed_version" >&2
  exit 66
fi
if [[ "$observed_node" != "$EXPECTED_NODE_PREFIX"* ]]; then
  echo "schedule parity oracle: expected Node ${EXPECTED_NODE_PREFIX}x, found $observed_node" >&2
  exit 66
fi
if [[ "$observed_yarn" != "$EXPECTED_YARN" ]]; then
  echo "schedule parity oracle: expected Yarn $EXPECTED_YARN, found $observed_yarn" >&2
  exit 66
fi
if [[ -n "$(git -C "$actual_checkout" status --porcelain --untracked-files=no)" ]]; then
  echo 'schedule parity oracle: writable clone has tracked changes before overlay' >&2
  exit 66
fi

target_dir="$actual_checkout/packages/loot-core/src/server/schedules"
test_target="$target_dir/cross-client-occurrence.test.ts"
support_target="$target_dir/schedule-occurrence-oracle-support.ts"
if [[ -e "$test_target" || -e "$support_target" ]]; then
  echo 'schedule parity oracle: overlay target already exists' >&2
  exit 66
fi

supervisor_pid=''
supervisor_expected=0
supervisor_pid_file="$run_dir/supervisor.pid"
supervisor_pgid_file="$run_dir/supervisor-child-pgid"

cleanup_overlay() {
  rm -f "$test_target" "$support_target"
}

cleanup_synthetic_data() {
  local cleanup_status='not-created'
  local result=0
  if [[ "$synthetic_data_created" -eq 1 ]]; then
    case "$synthetic_data_dir" in
      "$run_dir"/*)
        if rm -rf -- "$synthetic_data_dir" && [[ ! -e "$synthetic_data_dir" ]]; then
          cleanup_status='removed'
        else
          cleanup_status='blocked'
          result=1
        fi
        ;;
      *)
        cleanup_status='refused-outside-run-directory'
        result=1
        ;;
    esac
  fi
  printf 'path=%s\nstatus=%s\n' \
    "$synthetic_data_dir" \
    "$cleanup_status" > "$synthetic_data_cleanup_file"
  return "$result"
}

cleanup_owned_files() {
  local result=0
  cleanup_overlay || result=1
  cleanup_synthetic_data || result=1
  return "$result"
}

owned_child_pgid() {
  local pgid=''
  if [[ -f "$supervisor_pgid_file" ]]; then
    pgid=$(cat "$supervisor_pgid_file")
  fi
  if [[ "$pgid" =~ ^[0-9]+$ && "$pgid" -gt 1 ]]; then
    printf '%s\n' "$pgid"
  fi
}

owned_supervisor_pid() {
  local pid=$supervisor_pid
  if [[ -z "$pid" && -f "$supervisor_pid_file" ]]; then
    pid=$(cat "$supervisor_pid_file")
  fi
  if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; then
    printf '%s\n' "$pid"
  fi
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

signal_owned_processes() {
  local signal_name=$1
  local pgid=''
  local pid=''
  wait_for_supervisor_identity
  pgid=$(owned_child_pgid)
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
    pgid=$(owned_child_pgid)
    pid=$(owned_supervisor_pid)
    if ! process_is_running "$pid" &&
      ! process_group_is_running "$pgid"; then
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
  printf 'outcome=%s\nstatus=%s\n' \
    "$outcome" \
    "$exit_status" > "$run_dir/outcome.env"
}

capture_post_cleanup_status() {
  git -C "$actual_checkout" status --short > \
    "$run_dir/post-cleanup-git-status.txt"
}

shell_interrupted() {
  local exit_status=$1
  trap - EXIT INT TERM
  if terminate_owned_processes; then
    if cleanup_owned_files; then
      record_run_outcome "$exit_status" interrupted
    else
      record_run_outcome "$exit_status" interrupted-cleanup-blocked
    fi
  else
    record_run_outcome "$exit_status" interrupted-cleanup-blocked
  fi
  capture_post_cleanup_status
  exit "$exit_status"
}

shell_exited() {
  local exit_status=$1
  trap - EXIT INT TERM
  if [[ "$supervisor_expected" -eq 1 ]] && ! terminate_owned_processes; then
    record_run_outcome "$exit_status" exit-cleanup-blocked
    capture_post_cleanup_status
    exit "$exit_status"
  fi
  if ! cleanup_owned_files; then
    record_run_outcome "$exit_status" exit-cleanup-blocked
  fi
  capture_post_cleanup_status
  exit "$exit_status"
}
trap 'shell_exited $?' EXIT
trap 'shell_interrupted 130' INT
trap 'shell_interrupted 143' TERM

mkdir -m 700 "$synthetic_data_dir"
synthetic_data_created=1
cp "$script_dir/cross-client-occurrence.test.ts" "$test_target"
cp "$script_dir/schedule-occurrence-oracle-support.ts" "$support_target"
mkdir -p "$run_dir/oracle-source"
cp "$script_dir/README.md" "$run_dir/oracle-source/README.md"
cp "$script_dir/cross-client-occurrence.test.ts" \
  "$run_dir/oracle-source/cross-client-occurrence.test.ts"
cp "$script_dir/schedule-occurrence-oracle-support.ts" \
  "$run_dir/oracle-source/schedule-occurrence-oracle-support.ts"
cp "$script_dir/run-oracle.sh" "$run_dir/oracle-source/run-oracle.sh"

{
  printf 'actual_commit=%s\n' "$observed_commit"
  printf 'actual_tag=%s\n' "$observed_tag"
  printf 'core_version=%s\n' "$observed_version"
  printf 'node_version=%s\n' "$observed_node"
  printf 'yarn_version=%s\n' "$observed_yarn"
  printf 'vitest_version=%s\n' "$observed_vitest"
  printf 'node_path=%s\n' "$node_path"
  printf 'yarn_bootstrap_path=%s\n' "${yarn_bootstrap_path:-not-on-path}"
  printf 'yarn_release_path=%s\n' "$yarn_release_path"
  printf 'vitest_path=%s\n' "$vitest_path"
  printf 'vitest_real_path=%s\n' "$vitest_real_path"
  printf 'python_path=%s\n' "$python_path"
  printf 'tz=%s\n' "$ORACLE_TZ"
  printf 'ceiling_seconds=%s\n' "$CEILING_SECONDS"
  printf 'termination_grace_seconds=%s\n' "$TERMINATION_GRACE_SECONDS"
  printf 'outer_termination_max_seconds=%s\n' \
    "$((TERMINATION_GRACE_SECONDS * 3))"
  printf 'actual_data_dir=%s\n' "$synthetic_data_dir"
  printf 'actual_data_dir_ownership=run-label-exclusive-synthetic-temporary\n'
  printf 'actual_data_dir_mode=700\n'
  printf 'run_label=%s\n' "$run_label"
  printf 'source_checkout=%s\n' "$source_checkout"
  printf 'actual_checkout=%s\n' "$actual_checkout"
  printf 'source_git_common=%s\n' "$source_git_common"
  printf 'actual_git_common=%s\n' "$actual_git_common"
  printf 'actualist_source=%s\n' "$actualist_root"
  printf 'node_sha256=%s\n' "$(shasum -a 256 "$node_path" | awk '{print $1}')"
  printf 'yarn_release_sha256=%s\n' \
    "$(shasum -a 256 "$yarn_release_path" | awk '{print $1}')"
  printf 'vitest_sha256=%s\n' \
    "$(shasum -a 256 "$vitest_real_path" | awk '{print $1}')"
  printf 'test_sha256=%s\n' "$(shasum -a 256 "$test_target" | awk '{print $1}')"
  printf 'support_sha256=%s\n' "$(shasum -a 256 "$support_target" | awk '{print $1}')"
  printf 'schedule_app_sha256=%s\n' \
    "$(shasum -a 256 "$target_dir/app.ts" | awk '{print $1}')"
  printf 'schedule_shared_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/src/shared/schedules.ts" | awk '{print $1}')"
  printf 'accounts_sync_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/src/server/accounts/sync.ts" | awk '{print $1}')"
  printf 'transaction_handlers_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/src/server/transactions/index.ts" | awk '{print $1}')"
  printf 'transfer_handler_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/src/server/transactions/transfer.ts" | awk '{print $1}')"
  printf 'sync_engine_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/src/server/sync/index.ts" | awk '{print $1}')"
  printf 'schedule_schema_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/migrations/1618975177358_schedules.sql" | awk '{print $1}')"
  printf 'transfer_schedule_migration_sha256=%s\n' \
    "$(shasum -a 256 "$actual_checkout/packages/loot-core/migrations/1720310586000_link_transfer_schedules.sql" | awk '{print $1}')"
} > "$run_dir/provenance.env"

cat > "$run_dir/exact-command.txt" <<EOF
cd '$actual_checkout' && PATH='$(dirname "$node_path")':"\$PATH" TZ='$ORACLE_TZ' ENV=node ACTUAL_DATA_DIR='$synthetic_data_dir' ACTUAL_SCHEDULE_PARITY_EVIDENCE='$run_dir/oracle-result.json' '$node_path' '$yarn_release_path' workspace @actual-app/core exec '$vitest_path' --run src/server/schedules/cross-client-occurrence.test.ts --reporter=verbose --bail=1
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
  "$synthetic_data_dir" \
  "$supervisor_pid_file" \
  "$supervisor_pgid_file" \
  "$ORACLE_TZ" \
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
actual_data_dir = sys.argv[6]
supervisor_pid_path = sys.argv[7]
pgid_path = sys.argv[8]
timezone = sys.argv[9]
command = [
    sys.argv[10],
    sys.argv[11],
    'workspace',
    '@actual-app/core',
    'exec',
    sys.argv[12],
    '--run',
    'src/server/schedules/cross-client-occurrence.test.ts',
    '--reporter=verbose',
    '--bail=1',
]
environment = os.environ.copy()
environment.update({
    'ACTUAL_DATA_DIR': actual_data_dir,
    'ACTUAL_SCHEDULE_PARITY_EVIDENCE': result_path,
    'ENV': 'node',
    'PATH': os.path.dirname(sys.argv[10]) + os.pathsep + environment['PATH'],
    'TZ': timezone,
})
requested_signal = None

def request_stop(signum, _frame):
    global requested_signal
    requested_signal = signum

signal.signal(signal.SIGINT, request_stop)
signal.signal(signal.SIGTERM, request_stop)

with open(supervisor_pid_path, 'w', encoding='utf-8') as supervisor_pid_file:
    supervisor_pid_file.write(f'{os.getpid()}\n')
    supervisor_pid_file.flush()
    os.fsync(supervisor_pid_file.fileno())

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
supervisor_expected=0
set -e
printf '%s\n' "$oracle_status" > "$run_dir/oracle.exit"
case "$oracle_status" in
  0)
    outcome='completed-success'
    ;;
  124)
    outcome='timeout'
    ;;
  130|143)
    outcome='interrupted'
    ;;
  *)
    outcome='completed-failure'
    ;;
esac
if ! cleanup_owned_files; then
  outcome="${outcome}-cleanup-blocked"
fi
record_run_outcome "$oracle_status" "$outcome"
capture_post_cleanup_status
trap - EXIT INT TERM
exit "$oracle_status"
