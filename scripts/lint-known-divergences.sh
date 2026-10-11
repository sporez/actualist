#!/usr/bin/env bash
# Fails when a withKnownIssue in ActualistTests is not a registered OP-nn marker
# around one case, when isIntermittent appears, or when
# config/parity/known-divergences.json has a stale or mismatched entry.
# Prints the open divergences and any past their review-by date.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$ROOT/scripts/parity/lib/parity.mjs" divergences
