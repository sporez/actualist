#!/usr/bin/env bash
# Parity domains, oracle verification and the known-divergence gate.
# Never launches Xcode itself: Swift oracle suites run through scripts/test.sh,
# so its lock and the verification budget apply. Run `scripts/parity.sh help`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec node "$ROOT/scripts/parity/lib/parity.mjs" "$@"
