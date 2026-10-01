#!/bin/bash
set -euo pipefail

ROOT='/Users/neil/CC/actualist-dev'
HARNESS="$ROOT/scripts/parity/csv-export-interop"

[[ -z "${ACTUALIST_SIMULATOR_ID+x}" ]] || { echo 'refusing ACTUALIST_SIMULATOR_ID override' >&2; exit 2; }
[[ -z "${ACTUALIST_SCHEME+x}" ]] || { echo 'refusing ACTUALIST_SCHEME override' >&2; exit 2; }
[[ -z "${DERIVED_DATA_PATH+x}" ]] || { echo 'refusing DERIVED_DATA_PATH override' >&2; exit 2; }
source "$ROOT/scripts/lib/load-destinations.sh"
[[ "${ACTUALIST_SIMULATOR_ID:-}" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]] \
  || { echo 'configured simulator UDID is missing or malformed' >&2; exit 2; }

export ACTUALIST_SCHEME='Actualist Dev'
export ACTUALIST_SIMULATOR_ID
export DERIVED_DATA_PATH="$ROOT/.derivedData"
exec python3 "$HARNESS/orchestrate.py"
