#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/source-freeze.json"
: "${ACTUALIST_PARITY_ORACLE_ROOT:?set to the pinned Actual v26.9.0 checkout}"
# This checkout, derived from the harness location (scripts/parity/schedule-interop).
ACTUALIST_ROOT="$(cd "$HERE/../../.." && pwd -P)"

python3 - "$MANIFEST" "$ACTUALIST_PARITY_ORACLE_ROOT" "$ACTUALIST_ROOT" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

manifest_path = pathlib.Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
roots = {
    "actual": pathlib.Path(sys.argv[2]),
    "actualist": pathlib.Path(sys.argv[3]),
}

actual_head = subprocess.run(
    ["git", "-C", str(roots["actual"]), "rev-parse", "HEAD"],
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
if actual_head != manifest["actualRevision"]:
    raise SystemExit(
        f"source freeze mismatch: Actual HEAD {actual_head} != {manifest['actualRevision']}"
    )

failures = []
for owner, files in manifest["sha256"].items():
    root = roots[owner]
    for relative, expected in files.items():
        path = root / relative
        if not path.is_file():
            failures.append(f"missing {owner}:{relative}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            failures.append(
                f"changed {owner}:{relative}: expected {expected}, found {actual}"
            )

if failures:
    raise SystemExit("source freeze failed:\n" + "\n".join(failures))
print("schedule interop source freeze matches")
PY
