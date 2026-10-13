#!/usr/bin/env bash
# Parity domains, oracle verification and the known-divergence gate.
# Never launches Xcode itself: Swift oracle suites run through scripts/test.sh,
# so its lock and the verification budget apply. Run `scripts/parity.sh help`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The oracle checkout path is machine-specific, so it lives in the gitignored
# copy of scripts/lib/lab.example.env. A value already in the environment wins.
# Only this one variable is read, so lab credentials never reach test runs.
LAB_ENV="$ROOT/scripts/lib/lab.env"
if [ -z "${ACTUALIST_PARITY_ORACLE_ROOT:-}" ] && [ -f "$LAB_ENV" ]; then
  ACTUALIST_PARITY_ORACLE_ROOT="$(
    # shellcheck disable=SC1090
    . "$LAB_ENV" >/dev/null
    printf '%s' "${ACTUALIST_PARITY_ORACLE_ROOT:-}"
  )"
  if [ -n "$ACTUALIST_PARITY_ORACLE_ROOT" ]; then
    export ACTUALIST_PARITY_ORACLE_ROOT
  else
    unset ACTUALIST_PARITY_ORACLE_ROOT
  fi
fi

exec node "$ROOT/scripts/parity/lib/parity.mjs" "$@"
