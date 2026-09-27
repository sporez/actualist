#!/bin/bash

set -e -u -o pipefail

EXPECTED_COMMIT='59fe126f637d858c061e1eeedbef5436c8f2225a'
EXPECTED_TAG='v26.9.0'
EXPECTED_VERSION='26.9.0'
EXPECTED_NODE_PREFIX='v24.21.'
EXPECTED_YARN='4.17.1'

usage() {
  cat >&2 <<'EOF'
Usage: scripts/schedule-parity/run-oracle.sh \
  --actual-checkout <writable-isolated-actual-v26.9.0-copy> \
  --evidence <evidence-directory> \
  --run-label <investigation|post-correction>
EOF
  exit 64
}

actual_checkout=''
evidence=''
run_label=''
while (($# > 0)); do
  case "$1" in
    --actual-checkout)
      actual_checkout=${2:-}
      shift 2
      ;;
    --evidence)
      evidence=${2:-}
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

[[ -n "$actual_checkout" && -n "$evidence" && -n "$run_label" ]] || usage
[[ "$run_label" == 'investigation' || "$run_label" == 'post-correction' ]] || usage

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
actualist_root=$(cd "$script_dir/../.." && pwd)
actual_checkout=$(cd "$actual_checkout" && pwd)
mkdir -p "$evidence"
evidence=$(cd "$evidence" && pwd)

marker="$evidence/$run_label.started"
if [[ -e "$marker" ]]; then
  echo "schedule parity oracle: run label already spent: $run_label" >&2
  exit 65
fi

observed_commit=$(git -C "$actual_checkout" rev-parse HEAD) || exit $?
observed_tag=$(git -C "$actual_checkout" describe --tags --exact-match HEAD) || exit $?
observed_version=$(node -p "require(process.argv[1]).version" \
  "$actual_checkout/packages/loot-core/package.json") || exit $?
observed_node=$(node --version) || exit $?
observed_yarn=$(cd "$actual_checkout" && yarn --version) || exit $?

if [[ "$observed_commit" != "$EXPECTED_COMMIT" ]]; then
  echo "schedule parity oracle: expected Actual $EXPECTED_COMMIT, found $observed_commit" >&2
  exit 66
fi
if [[ "$observed_tag" != "$EXPECTED_TAG" ]]; then
  echo "schedule parity oracle: expected tag $EXPECTED_TAG, found $observed_tag" >&2
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
  echo 'schedule parity oracle: isolated Actual copy has tracked changes before overlay' >&2
  exit 66
fi

target_dir="$actual_checkout/packages/loot-core/src/server/schedules"
test_target="$target_dir/cross-client-occurrence.test.ts"
support_target="$target_dir/schedule-occurrence-oracle-support.ts"
if [[ -e "$test_target" || -e "$support_target" ]]; then
  echo 'schedule parity oracle: overlay target already exists' >&2
  exit 66
fi

cleanup() {
  rm -f "$test_target" "$support_target"
}
trap cleanup EXIT INT TERM

cp "$script_dir/cross-client-occurrence.test.ts" "$test_target"
cp "$script_dir/schedule-occurrence-oracle-support.ts" "$support_target"
mkdir -p "$evidence/oracle-source"
cp "$script_dir/README.md" "$evidence/oracle-source/README.md"
cp "$script_dir/cross-client-occurrence.test.ts" \
  "$evidence/oracle-source/cross-client-occurrence.test.ts"
cp "$script_dir/schedule-occurrence-oracle-support.ts" \
  "$evidence/oracle-source/schedule-occurrence-oracle-support.ts"
cp "$script_dir/run-oracle.sh" "$evidence/oracle-source/run-oracle.sh"

{
  printf 'actual_commit=%s\n' "$observed_commit"
  printf 'actual_tag=%s\n' "$observed_tag"
  printf 'core_version=%s\n' "$observed_version"
  printf 'node=%s\n' "$observed_node"
  printf 'yarn=%s\n' "$observed_yarn"
  printf 'run_label=%s\n' "$run_label"
  printf 'actual_checkout=%s\n' "$actual_checkout"
  printf 'actualist_source=%s\n' "$actualist_root"
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
} > "$evidence/provenance.env"

command_file="$evidence/exact-command.txt"
cat > "$command_file" <<EOF
cd '$actual_checkout' && ENV=node ACTUAL_SCHEDULE_PARITY_EVIDENCE='$evidence/oracle-result.json' yarn workspace @actual-app/core exec vitest --run src/server/schedules/cross-client-occurrence.test.ts --reporter=verbose --bail=1
EOF

printf '%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "$marker"
set +e
(
  cd "$actual_checkout" || exit $?
  ENV=node \
    ACTUAL_SCHEDULE_PARITY_EVIDENCE="$evidence/oracle-result.json" \
    yarn workspace @actual-app/core exec vitest --run \
      src/server/schedules/cross-client-occurrence.test.ts \
      --reporter=verbose \
      --bail=1
) > "$evidence/oracle.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$evidence/oracle.exit"

cleanup
trap - EXIT INT TERM
git -C "$actual_checkout" status --short > "$evidence/post-cleanup-git-status.txt"
exit "$status"
