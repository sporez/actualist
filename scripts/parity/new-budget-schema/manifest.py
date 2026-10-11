#!/usr/bin/env python3
"""Write newbudget-manifest.json beside a generator output.

Records the pinned release, the oracle source files behind the generated
schema (hashed from the oracle root), the harness files, and the sha256 of each
fixture file in this folder. verify.mjs checks the committed copy; drift.py
compares a fresh copy with it.

usage: manifest.py <out-dir> <oracle-root>
"""
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
PIN_FIELDS = ("tag", "commit", "packageVersion")
FIXTURE_FILES = ("starter-schema.json", "migrations.txt")
ORACLE_SOURCES = [
    "packages/loot-core/src/server/budgetfiles/app.ts",  # create-budget handler
    "packages/loot-core/src/server/budget/base.ts",  # createBudget
    "packages/loot-core/src/server/update.ts",  # updateVersion
    "packages/loot-core/src/server/migrate/migrations.ts",  # migrate()
    "packages/loot-core/default-db.sqlite",  # bundled starter database
]
MIGRATION_DIR = "packages/loot-core/migrations"
HARNESS_FILES = [
    "scripts/parity/lib/oracle-pin.mjs",
    "scripts/parity/new-budget-schema/run.sh",
    "scripts/parity/new-budget-schema/dump.py",
    "scripts/parity/new-budget-schema/emit_swift.py",
    "scripts/parity/new-budget-schema/replay.py",
    "scripts/parity/new-budget-schema/manifest.py",
    "scripts/parity/new-budget-schema/drift.py",
    "scripts/parity/new-budget-schema/verify.mjs",
    "scripts/parity/new-budget-schema/generate.test.mjs",
    "scripts/parity/new-budget-schema/check.test.mjs",
    "scripts/parity/new-budget-schema/vitest.config.mjs",
    "scripts/parity/new-budget-schema/fs-shim.mjs",
    "scripts/parity/new-budget-schema/no-network-setup.mjs",
]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


out, oracle = Path(sys.argv[1]), Path(sys.argv[2])
pin = json.loads((REPO / "config/parity/oracle-pin.json").read_text())
starter = json.loads((out / "starter-schema.json").read_text())
migrations = [line for line in (out / "migrations.txt").read_text().splitlines() if line]

migration_sources = sorted(
    path.relative_to(oracle).as_posix()
    for path in (oracle / MIGRATION_DIR).iterdir()
    if path.is_file()
)
oracle_sources = ORACLE_SOURCES + migration_sources

manifest = {
    "schemaVersion": 1,
    "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "seed": None,
    "actual": {field: pin[field] for field in PIN_FIELDS},
    "oracleSources": [
        {"path": rel, "sha256": sha256(oracle / rel)} for rel in oracle_sources
    ],
    "harnessFiles": [
        {"path": rel, "sha256": sha256(REPO / rel)} for rel in HARNESS_FILES
    ],
    "fixtureFiles": [
        {"path": name, "sha256": sha256(out / name)} for name in FIXTURE_FILES
    ],
    "counts": {
        "tables": len(starter),
        "migrations": len(migrations),
        "caseCount": None,
    },
}
(out / "newbudget-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(
    f"manifest: {len(oracle_sources)} oracle sources, {len(HARNESS_FILES)} harness files, "
    f"{len(FIXTURE_FILES)} fixture files"
)
