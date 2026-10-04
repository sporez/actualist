#!/usr/bin/env python3
"""Dump schema, migrations, meta, seed rows and table_info from a budget db.

usage: dump.py <db.sqlite> <out-dir>
"""
import json
import sqlite3
import sys
from pathlib import Path

db_path, out = sys.argv[1], Path(sys.argv[2])
con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)

# Creation order = rowid order in sqlite_master. Views and sqlite_* internals
# are excluded; auto-indexes have no SQL and are recreated by their table.
objs = con.execute(
    "SELECT type, name, sql FROM sqlite_master "
    "WHERE type IN ('table','index','trigger') AND name NOT LIKE 'sqlite_%' "
    "AND sql IS NOT NULL ORDER BY rowid"
).fetchall()
(out / "schema.sql").write_text("".join(f"{sql};\n" for _, _, sql in objs))

ids = [r[0] for r in con.execute("SELECT id FROM __migrations__ ORDER BY id")]
(out / "migrations.txt").write_text("".join(f"{i}\n" for i in ids))

meta = {k: v for k, v in con.execute("SELECT key, value FROM __meta__ ORDER BY key")
        if k != "view-hash"}
(out / "meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")

tables = sorted(n for t, n, _ in objs if t == "table")
seed = {}
for t in tables:
    cur = con.execute(f'SELECT * FROM "{t}"')
    cols = [d[0] for d in cur.description]
    rows = sorted((dict(zip(cols, r)) for r in cur.fetchall()), key=json.dumps)
    if rows:
        seed[t] = rows
(out / "seed-rows.json").write_text(json.dumps(seed, indent=2) + "\n")

info = {
    t: [
        {"name": n, "type": ty, "notnull": nn, "dflt_value": d, "pk": pk}
        for _, n, ty, nn, d, pk in con.execute(f'PRAGMA table_info("{t}")')
    ]
    for t in tables
}
(out / "starter-schema.json").write_text(json.dumps(info, indent=2) + "\n")
print(f"tables={len(tables)} indexes={sum(1 for o in objs if o[0]=='index')} "
      f"triggers={sum(1 for o in objs if o[0]=='trigger')} migrations={len(ids)} "
      f"nonempty={sorted(seed)}")
