#!/usr/bin/env python3
"""Derive a deterministic tracking demo from the committed synthetic envelope demo.

No personal database or server is used. Regenerate from the repository root.
The fixed July/August/September 2026 window covers closed/open month UI tests.
"""
import hashlib
import sqlite3
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
output = root / 'Actualist/Resources/TrackingDemoBudget.zip'
with tempfile.TemporaryDirectory() as directory:
    database = Path(directory) / 'db.sqlite'
    with zipfile.ZipFile(root / 'Actualist/Resources/DemoBudget.zip') as archive:
        database.write_bytes(archive.read('db.sqlite'))
    with sqlite3.connect(database) as connection:
        connection.executescript('''
            CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
            INSERT INTO preferences VALUES ('budgetType', 'tracking');
            CREATE TABLE reflect_budgets (
                id TEXT PRIMARY KEY, month INTEGER, category TEXT,
                amount INTEGER NOT NULL DEFAULT 0, carryover INTEGER NOT NULL DEFAULT 0,
                goal INTEGER, long_goal INTEGER);
            INSERT INTO reflect_budgets
                SELECT month || '-' || category, month, category, amount, carryover, goal, long_goal
                FROM zero_budgets;
            INSERT OR REPLACE INTO reflect_budgets
                SELECT '202609-' || category, 202609, category, amount, carryover, goal, long_goal
                FROM zero_budgets WHERE month = 202608;
        ''')
        for month in (202607, 202608, 202609):
            for category, amount in [('paycheck', 500000), ('freelance', 60000), ('interest', 1500)]:
                connection.execute('INSERT OR REPLACE INTO reflect_budgets (id, month, category, amount) VALUES (?, ?, ?, ?)',
                                   (f'{month}-{category}', month, category, amount))
        connection.execute("UPDATE category_groups SET sort_order = -1 WHERE is_income = 1")
        connection.execute("UPDATE reflect_budgets SET amount = 100 WHERE category = 'groceries' AND month = 202608")
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        info = zipfile.ZipInfo('db.sqlite', date_time=(2026, 9, 7, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, database.read_bytes())
print(f'{output.name}: {len(output.read_bytes())} bytes; SHA-256 {hashlib.sha256(output.read_bytes()).hexdigest()}')
