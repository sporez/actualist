#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
HARNESS="$ROOT/scripts/parity/csv-export-interop"

[[ -z "${ACTUALIST_SIMULATOR_ID+x}" ]] || { echo 'refusing ACTUALIST_SIMULATOR_ID override' >&2; exit 2; }
[[ -z "${ACTUALIST_SCHEME+x}" ]] || { echo 'refusing ACTUALIST_SCHEME override' >&2; exit 2; }
[[ -z "${DERIVED_DATA_PATH+x}" ]] || { echo 'refusing DERIVED_DATA_PATH override' >&2; exit 2; }
for name in ACTUALIST_PARITY_ORACLE_ROOT ACTUALIST_PARITY_NODE; do
  [[ -n "${!name:-}" ]] || { echo "set $name (see README: Machine-local paths)" >&2; exit 2; }
done
source "$ROOT/scripts/lib/load-destinations.sh"
[[ "${ACTUALIST_SIMULATOR_ID:-}" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]] \
  || { echo 'configured simulator UDID is missing or malformed' >&2; exit 2; }

export ACTUALIST_PARITY_ORACLE_ROOT ACTUALIST_PARITY_NODE
export ACTUALIST_SCHEME='Actualist Dev'
export ACTUALIST_SIMULATOR_ID
export DERIVED_DATA_PATH="$ROOT/.derivedData"
exec python3 "$HARNESS/orchestrate.py"
