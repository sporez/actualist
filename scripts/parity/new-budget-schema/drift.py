#!/usr/bin/env python3
"""Compare a fresh generator output with the committed NewBudget fixture.

starter-schema.json and migrations.txt must match byte for byte. The manifest
must match once generatedAt is removed from both sides.

usage: drift.py <fixture-dir> <out-dir>
exit: 0 no drift, 1 drift, 2 a file is missing
"""
import json
import sys
from pathlib import Path

BYTE_FILES = ("starter-schema.json", "migrations.txt")
MANIFEST = "newbudget-manifest.json"

fixture, out = Path(sys.argv[1]), Path(sys.argv[2])
missing = [
    str(folder / name)
    for folder in (fixture, out)
    for name in (*BYTE_FILES, MANIFEST)
    if not (folder / name).is_file()
]
if missing:
    print("missing: " + ", ".join(missing), file=sys.stderr)
    sys.exit(2)


def normalized_manifest(path):
    data = json.loads(path.read_text())
    data.pop("generatedAt", None)
    return data


drifted = [
    name for name in BYTE_FILES
    if (fixture / name).read_bytes() != (out / name).read_bytes()
]
if normalized_manifest(fixture / MANIFEST) != normalized_manifest(out / MANIFEST):
    drifted.append(MANIFEST)

if drifted:
    print("NewBudget fixture drift: " + ", ".join(drifted))
    sys.exit(1)
print(f"no drift: {len(BYTE_FILES)} fixture files and the manifest match a fresh generation")
