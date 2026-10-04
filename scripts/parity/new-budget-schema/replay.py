#!/usr/bin/env python3
"""Replay a generator output into an empty db.sqlite to prove it is sufficient.

Applies schema.sql, __migrations__ ids and the seed rows (excluding __meta__,
which holds only the view hash, and messages_clock, which loadClock recreates).
usage: replay.py <generator-out-dir> <new-db.sqlite>
"""
import json
import sqlite3
import sys
from pathlib import Path

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
dest.unlink(missing_ok=True)
con = sqlite3.connect(dest)
con.executescript((src / "schema.sql").read_text())
seed = json.loads((src / "seed-rows.json").read_text())
for table, rows in seed.items():
    if table in ("__meta__", "messages_clock"):
        continue
    for row in rows:
        cols = ", ".join(f'"{c}"' for c in row)
        marks = ", ".join("?" for _ in row)
        con.execute(f'INSERT INTO "{table}" ({cols}) VALUES ({marks})', list(row.values()))
con.commit()
print(f"replayed into {dest}: tables={list(seed)}")
