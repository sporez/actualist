#!/usr/bin/env python3
"""
Generate the bundled Actualist demo budget artifact.

Output: a zip containing a single `db.sqlite`, committed at
`Actualist/Resources/DemoBudget.zip`. Typing `demo` in the onboarding server
URL field installs this budget and enters a fully local demo mode that never
contacts a server.

Why a generator (and why Python):
  The app never creates its budget schema at runtime — it always imports a
  server-built SQLite database. The demo needs such a database too, but a
  reproducible, dependency-free generator lets us commit a curated, 100%
  fictional dataset without depending on a live Actual server. Python's stdlib
  `sqlite3` + `zipfile` + `hashlib` produce a standard SQLite file that GRDB
  reads identically to the GRDB-built fixtures used by the unit tests (same
  DDL, same storage classes). No third-party packages are required.

  The demo-mode plan's *preferred* long-term route is a Swift harness that
  drives the app's own CRDT write paths (`LocalFirstActualStore` +
  `LocalFirstSyncMessageBuilder`) against a developer test budget, so the
  dataset exercises real write code. That route needs a server-built base
  database and a provisioned test VM that are not available in a public clone.
  This script is the artifact-seeded fallback the plan also describes: the
  committed zip is the source of truth, and regeneration is only needed when
  the fixture schema or dataset changes (bump `DemoBudget.fileID`'s version
  suffix in `DemoBudget.swift` so entry reinstalls).

Usage:
  python3 scripts/generate-demo-budget/generate_demo_budget.py \
      --output Actualist/Resources/DemoBudget.zip \
      --end-date 2026-08-31

  Run from the repository root. The script prints the zip's SHA-256 and byte
  size; copy both into `DemoBudget.swift` (`DemoBudget.artifactSHA256` /
  `DemoBudget.artifactByteCount`) so the app can integrity-log the bundled
  artifact and tests can assert it.

Scrub checklist (every entry must be fictional):
  - Budget name: "Demo Budget"
  - Account names: Everyday Checking, High-Yield Savings, Visa Credit Card,
    Car Loan
  - Payee names: Fresh Market, City Utilities, QuickFuel, SafeCover, Daily
    Grind, Bistro Nove, StreamFlix, MobileCo, Payroll Inc, Pixel Studio,
    MarketPlace, Glow Studio, Landlord Co
  - No real bank, no real person, no real merchant, no real address, no real
    account numbers, no real card numbers.
  - Amounts are round, obviously illustrative figures.

Dataset design (matches the demo-mode plan):
  - 4 accounts (one closed off-budget loan, one negative-balance credit card).
  - 4 category groups, 16 categories (Essentials, Lifestyle, Savings Goals,
    Income).
  - ~6 months of transactions ending in the current month, with recurring
    paycheck income, rent/mortgage, groceries, dining, subscriptions, an
    interest deposit, a completed checking->savings transfer, and a checking
    ->credit-card payment transfer.
  - Budget assignments for the most recent 3 months, tuned so the Budget view
    shows green (available), yellow (near zero), red (overspent) states, plus
    one uncategorized transaction.
  - Transfer payees (`xfer-<account>`) and payee/category mappings so transfer
    rendering and category/payee editors work.
  - One UI-managed template (Rent: monthly Fixed + remainder) and one
    note-managed template (Groceries) so Edit vs View is visible.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import sqlite3
import zipfile
from pathlib import Path


# --- Identity (must match DemoBudget.swift) ---------------------------------

DEMO_FILE_ID = "actualist-demo-budget-v3"
DEMO_GROUP_ID = "actualist-demo-group-v1"
DEMO_NODE_ID = "demo-node-00000001"
DEMO_BUDGET_NAME = "Demo Budget"


# --- Schema DDL -------------------------------------------------------------
# Mirrors the table/column layout the app reads and writes (see
# BudgetDatabase+Reads.swift / +TransactionWrites.swift / +BudgetWrites.swift
# and the GRDB test fixture in LocalFirstActualStoreTestSupport.swift).

SCHEMA = """
CREATE TABLE accounts (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    offbudget INTEGER NOT NULL DEFAULT 0,
    closed INTEGER NOT NULL DEFAULT 0,
    tombstone INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    bank_sync_status TEXT
);
CREATE TABLE category_groups (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    is_income INTEGER NOT NULL DEFAULT 0,
    hidden INTEGER NOT NULL DEFAULT 0,
    tombstone INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    cat_group TEXT,
    is_income INTEGER NOT NULL DEFAULT 0,
    hidden INTEGER NOT NULL DEFAULT 0,
    tombstone INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    goal_def TEXT,
    template_settings TEXT
);
CREATE TABLE zero_budgets (
    month INTEGER,
    category TEXT,
    amount INTEGER NOT NULL DEFAULT 0,
    carryover INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE transactions (
    id TEXT PRIMARY KEY,
    acct TEXT,
    date INTEGER,
    amount INTEGER,
    category TEXT,
    tombstone INTEGER NOT NULL DEFAULT 0,
    parent_id TEXT,
    is_parent INTEGER NOT NULL DEFAULT 0,
    description TEXT,
    notes TEXT,
    cleared INTEGER NOT NULL DEFAULT 0,
    reconciled INTEGER NOT NULL DEFAULT 0,
    imported_description TEXT,
    sort_order REAL,
    transferred_id TEXT,
    is_child INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE payees (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT,
    transfer_acct TEXT,
    favorite INTEGER NOT NULL DEFAULT 0,
    tombstone INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE payee_mapping (
    id TEXT PRIMARY KEY,
    targetId TEXT
);
CREATE TABLE category_mapping (
    id TEXT PRIMARY KEY,
    transferId TEXT
);
CREATE TABLE notes (
    id TEXT PRIMARY KEY,
    note TEXT
);
CREATE TABLE messages_crdt (
    timestamp TEXT,
    dataset TEXT,
    row TEXT,
    column TEXT,
    value TEXT
);
"""


# --- Static reference data --------------------------------------------------

ACCOUNTS = [
    # id, name, offbudget, closed, sort_order
    ("checking", "Everyday Checking", 0, 0, 1),
    ("savings", "High-Yield Savings", 0, 0, 2),
    ("credit", "Visa Credit Card", 0, 0, 3),
    ("carloan", "Car Loan", 1, 1, 4),  # off-budget, closed
]

GROUPS = [
    # id, name, is_income, sort_order
    ("essentials", "Essentials", 0, 1),
    ("lifestyle", "Lifestyle", 0, 2),
    ("savings", "Savings Goals", 0, 3),
    ("income", "Income", 1, 4),
]

CATEGORIES = [
    # id, name, group, is_income, sort_order
    ("rent", "Rent", "essentials", 0, 1),
    ("groceries", "Groceries", "essentials", 0, 2),
    ("utilities", "Utilities", "essentials", 0, 3),
    ("transportation", "Transportation", "essentials", 0, 4),
    ("insurance", "Insurance", "essentials", 0, 5),
    ("dining", "Dining", "lifestyle", 0, 1),
    ("entertainment", "Entertainment", "lifestyle", 0, 2),
    ("subscriptions", "Subscriptions", "lifestyle", 0, 3),
    ("shopping", "Shopping", "lifestyle", 0, 4),
    ("personal_care", "Personal Care", "lifestyle", 0, 5),
    ("emergency_fund", "Emergency Fund", "savings", 0, 1),
    ("vacation", "Vacation", "savings", 0, 2),
    ("retirement", "Retirement", "savings", 0, 3),
    ("paycheck", "Paycheck", "income", 1, 1),
    ("freelance", "Freelance", "income", 1, 2),
    ("interest", "Interest", "income", 1, 3),
]

PAYEES = [
    # id, name, category, transfer_acct
    ("landlord", "Landlord Co", "rent", None),
    ("grocer", "Fresh Market", "groceries", None),
    ("utilityco", "City Utilities", "utilities", None),
    ("gasstation", "QuickFuel", "transportation", None),
    ("insuranceco", "SafeCover", "insurance", None),
    ("cafe", "Daily Grind", "dining", None),
    ("restaurant", "Bistro Nove", "dining", None),
    ("streamflix", "StreamFlix", "subscriptions", None),
    ("telco", "MobileCo", "subscriptions", None),
    ("employer", "Payroll Inc", "paycheck", None),
    ("freelanceclient", "Pixel Studio", "freelance", None),
    ("store", "MarketPlace", "shopping", None),
    ("salon", "Glow Studio", "personal_care", None),
    ("xfer-checking", "", None, "checking"),
    ("xfer-savings", "", None, "savings"),
    ("xfer-credit", "", None, "credit"),
    ("xfer-carloan", "", None, "carloan"),
]


def month_int(year: int, month: int) -> int:
    return year * 100 + month


def date_int(year: int, month: int, day: int) -> int:
    return year * 10000 + month * 100 + day


def month_window(end_date: datetime.date, months_back: int):
    """Return list of (year, month) from months_back before end_date's month
    through end_date's month."""
    y, m = end_date.year, end_date.month
    for _ in range(months_back):
        m -= 1
        if m < 1:
            m = 12
            y -= 1
    months = []
    while (y, m) <= (end_date.year, end_date.month):
        months.append((y, m))
        m += 1
        if m > 12:
            m = 1
            y += 1
    return months


def build_transactions(months):
    """Return rows of (id, acct, date, amount, category, payee, cleared,
    transferred_id, notes)."""
    txns = []
    counter = 0

    def next_id(prefix: str) -> str:
        nonlocal counter
        counter += 1
        return f"{prefix}-{counter:05d}"

    def add_transfer(from_acct: str, to_acct: str, day: int, amount: int,
                     year: int, month: int):
        from_id = next_id("xfer")
        to_id = next_id("xfer")
        date = date_int(year, month, day)
        txns.append((from_id, from_acct, date, -amount, None,
                     f"xfer-{to_acct}", 1, to_id, None))
        txns.append((to_id, to_acct, date, amount, None,
                     f"xfer-{from_acct}", 1, from_id, None))

    for (year, month) in months:
        # Paycheck on the 1st and 15th -> checking, income.
        for day in (1, 15):
            txns.append((next_id("pay"), "checking", date_int(year, month, day),
                         450000, "paycheck", "employer", 1, None, None))
        # Rent on the 2nd -> checking, rent.
        txns.append((next_id("rent"), "checking", date_int(year, month, 2),
                     -180000, "rent", "landlord", 1, None, None))
        # Groceries: a few trips.
        for day, amt in ((5, -8400), (12, -6750), (22, -9200)):
            txns.append((next_id("groc"), "checking", date_int(year, month, day),
                         amt, "groceries", "grocer", 1, None, None))
        # Utilities mid-month.
        txns.append((next_id("util"), "checking", date_int(year, month, 18),
                     -18400, "utilities", "utilityco", 1, None, None))
        # Gas/transportation.
        for day, amt in ((8, -5200), (20, -4800)):
            txns.append((next_id("gas"), "checking", date_int(year, month, day),
                         amt, "transportation", "gasstation", 1, None, None))
        # Insurance monthly.
        txns.append((next_id("ins"), "checking", date_int(year, month, 10),
                     -12000, "insurance", "insuranceco", 1, None, None))
        # Dining.
        for day, amt, payee in ((6, -3400, "cafe"), (14, -7800, "restaurant"),
                               (27, -5200, "restaurant")):
            txns.append((next_id("din"), "checking", date_int(year, month, day),
                         amt, "dining", payee, 0, None, None))
        # Subscriptions on the credit card.
        txns.append((next_id("sub1"), "credit", date_int(year, month, 3),
                     -1500, "subscriptions", "streamflix", 1, None, None))
        txns.append((next_id("sub2"), "credit", date_int(year, month, 7),
                     -6000, "subscriptions", "telco", 1, None, None))
        # Entertainment + shopping + personal care on the credit card.
        txns.append((next_id("ent"), "credit", date_int(year, month, 9),
                     -4200, "entertainment", "store", 0, None, None))
        txns.append((next_id("shop"), "credit", date_int(year, month, 16),
                     -12900, "shopping", "store", 0, None, None))
        txns.append((next_id("care"), "credit", date_int(year, month, 23),
                     -6500, "personal_care", "salon", 0, None, None))
        # Interest income to savings.
        txns.append((next_id("int"), "savings", date_int(year, month, 28),
                     3200, "interest", None, 1, None, None))

        # Completed transfers.
        add_transfer("checking", "savings", 20, 50000, year, month)
        add_transfer("checking", "credit", 25, 30000, year, month)

    # One uncategorized transaction last month (groceries-like, no category).
    ly, lm = months[-1]
    txns.append((next_id("uncat"), "checking", date_int(ly, lm, 19),
                 -7300, None, "grocer", 0, None, "Needs a category"))

    return txns


def build_budget_assignments(months):
    """Return [(month_int, category, amount, carryover)] for the last 3 months,
    tuned for green/yellow/red Budget states."""
    last_three = months[-3:]
    assignments = []
    for idx, (year, month) in enumerate(last_three):
        m = month_int(year, month)
        if idx == 0:
            # Two months ago: overspent groceries (red), under others (green).
            assignments.append((m, "rent", 180000, 0))
            assignments.append((m, "groceries", 18000, 0))      # spent ~24350 -> red
            assignments.append((m, "utilities", 18400, 0))
            assignments.append((m, "transportation", 20000, 0))
            assignments.append((m, "insurance", 12000, 0))
            assignments.append((m, "dining", 30000, 0))         # spent ~16400 -> green
            assignments.append((m, "entertainment", 15000, 0))
            assignments.append((m, "subscriptions", 8000, 0))
            assignments.append((m, "shopping", 25000, 0))
            assignments.append((m, "personal_care", 12000, 0))
            assignments.append((m, "emergency_fund", 50000, 0))
            assignments.append((m, "vacation", 30000, 0))
            assignments.append((m, "retirement", 100000, 0))
        elif idx == 1:
            # Last month: dining near zero, shopping overspent (red).
            assignments.append((m, "rent", 180000, 0))
            assignments.append((m, "groceries", 30000, 0))      # spent ~24350 -> green
            assignments.append((m, "utilities", 18400, 0))
            assignments.append((m, "transportation", 20000, 0))
            assignments.append((m, "insurance", 12000, 0))
            assignments.append((m, "dining", 16000, 0))        # spent ~16400 -> ~zero
            assignments.append((m, "entertainment", 15000, 0))
            assignments.append((m, "subscriptions", 8000, 0))
            assignments.append((m, "shopping", 9000, 0))       # spent ~12900 -> red
            assignments.append((m, "personal_care", 12000, 0))
            assignments.append((m, "emergency_fund", 50000, 0))
            assignments.append((m, "vacation", 30000, 0))
            assignments.append((m, "retirement", 100000, 0))
        else:
            # This month: partial assignment, plenty of green available.
            assignments.append((m, "rent", 180000, 0))
            assignments.append((m, "groceries", 35000, 0))
            assignments.append((m, "utilities", 18400, 0))
            assignments.append((m, "transportation", 20000, 0))
            assignments.append((m, "insurance", 12000, 0))
            assignments.append((m, "dining", 25000, 0))
            assignments.append((m, "entertainment", 15000, 0))
            assignments.append((m, "subscriptions", 8000, 0))
            assignments.append((m, "shopping", 25000, 0))
            assignments.append((m, "personal_care", 8000, 0))
            assignments.append((m, "emergency_fund", 75000, 0))
            assignments.append((m, "vacation", 30000, 0))
            # retirement intentionally unassigned this month -> shows available.
    return assignments


def populate(conn: sqlite3.Connection, end_date: datetime.date):
    cur = conn.cursor()
    cur.executescript(SCHEMA)

    cur.executemany(
        "INSERT INTO accounts (id, name, offbudget, closed, sort_order) VALUES (?, ?, ?, ?, ?)",
        ACCOUNTS,
    )
    cur.executemany(
        "INSERT INTO category_groups (id, name, is_income, sort_order) VALUES (?, ?, ?, ?)",
        GROUPS,
    )
    cur.executemany(
        "INSERT INTO categories (id, name, cat_group, is_income, sort_order) VALUES (?, ?, ?, ?, ?)",
        CATEGORIES,
    )
    cur.executemany(
        "INSERT INTO payees (id, name, category, transfer_acct) VALUES (?, ?, ?, ?)",
        PAYEES,
    )
    cur.executemany(
        "INSERT INTO payee_mapping (id, targetId) VALUES (?, ?)",
        [(p[0], p[0]) for p in PAYEES],
    )
    cur.executemany(
        "INSERT INTO category_mapping (id, transferId) VALUES (?, ?)",
        [(c[0], c[0]) for c in CATEGORIES],
    )

    month_note_id = f"budget-{end_date.year:04d}-{end_date.month:02d}"
    cur.executemany(
        "INSERT INTO notes (id, note) VALUES (?, ?)",
        [
            # Groceries is the view-only note-managed example. Do not also put a
            # UI template on this category.
            ("groceries", "Plan pantry-first meals before shopping.\n#template 350"),
            ("essentials", "Review recurring household costs each quarter."),
            ("account-checking", "Primary account for everyday spending."),
            (month_note_id, "Keep this month focused on the vacation goal."),
        ],
    )

    # Opening balances so account balances look realistic.
    # Car Loan: off-budget negative balance (a debt), recorded ~1 year ago.
    cur.execute(
        "INSERT INTO transactions (id, acct, date, amount, category, tombstone, "
        "is_parent, description, cleared, sort_order) "
        "VALUES ('opening-carloan', 'carloan', ?, -2400000, NULL, 0, 0, "
        "'Opening Balance', 1, 0)",
        (date_int(end_date.year - 1, end_date.month, 1),),
    )

    months = month_window(end_date, months_back=6)
    txns = build_transactions(months)
    cur.executemany(
        "INSERT INTO transactions (id, acct, date, amount, category, tombstone, "
        "is_parent, description, cleared, transferred_id, notes) "
        "VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?)",
        [(t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8]) for t in txns],
    )

    assignments = build_budget_assignments(months)
    cur.executemany(
        "INSERT INTO zero_budgets (month, category, amount, carryover) VALUES (?, ?, ?, ?)",
        assignments,
    )
    apply_templates(cur, end_date)

    conn.commit()


def apply_templates(cur: sqlite3.Cursor, end_date: datetime.date) -> None:
    """Rent is UI-managed (editable). Groceries stays note-managed (view-only)."""
    starting = f"{end_date.year:04d}-{end_date.month:02d}-01"
    rent_goal_def = json.dumps(
        [
            {
                "amount": 1800,
                "directive": "template",
                "period": {"amount": 1, "period": "month"},
                "priority": 1,
                "starting": starting,
                "type": "periodic",
            },
            {
                "directive": "template",
                "priority": None,
                "type": "remainder",
                "weight": 1,
            },
        ],
        separators=(",", ":"),
    )
    groceries_goal_def = json.dumps(
        [
            {
                "directive": "template",
                "monthly": 350,
                "priority": 0,
                "type": "simple",
            }
        ],
        separators=(",", ":"),
    )
    cur.execute(
        "UPDATE categories SET goal_def = ?, template_settings = ? WHERE id = 'rent'",
        (rent_goal_def, '{"source":"ui"}'),
    )
    cur.execute(
        "UPDATE categories SET goal_def = ?, template_settings = ? WHERE id = 'groceries'",
        (groceries_goal_def, '{"source":"notes"}'),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        default="Actualist/Resources/DemoBudget.zip",
        help="Destination zip path (default: Actualist/Resources/DemoBudget.zip)",
    )
    parser.add_argument(
        "--end-date",
        default=None,
        help="Last month of the fixture as YYYY-MM-DD (default: today). Pin this when regenerating so DemoBudget.fixtureMonth stays stable.",
    )
    args = parser.parse_args()

    out_path = Path(args.output).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    today = (
        datetime.date.fromisoformat(args.end_date)
        if args.end_date
        else datetime.date.today()
    )
    db_path = out_path.parent / "db.sqlite"
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(str(db_path))
    try:
        populate(conn, today)
        rows = conn.execute("PRAGMA integrity_check").fetchall()
        if rows != [("ok",)]:
            raise SystemExit(f"integrity_check failed: {rows}")
        row_counts = {
            "accounts": conn.execute("SELECT COUNT(*) FROM accounts").fetchone()[0],
            "category_groups": conn.execute("SELECT COUNT(*) FROM category_groups").fetchone()[0],
            "categories": conn.execute("SELECT COUNT(*) FROM categories").fetchone()[0],
            "transactions": conn.execute("SELECT COUNT(*) FROM transactions").fetchone()[0],
            "zero_budgets": conn.execute("SELECT COUNT(*) FROM zero_budgets").fetchone()[0],
            "payees": conn.execute("SELECT COUNT(*) FROM payees").fetchone()[0],
            "notes": conn.execute("SELECT COUNT(*) FROM notes").fetchone()[0],
        }
    finally:
        conn.close()

    if out_path.exists():
        out_path.unlink()
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(db_path, arcname="db.sqlite")
    db_path.unlink(missing_ok=True)

    data = out_path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    size = len(data)

    print(f"Wrote {out_path}")
    print(f"Byte size: {size}")
    print(f"SHA-256:   {sha}")
    print("Row counts:")
    for name, count in row_counts.items():
        print(f"  {name}: {count}")
    print()
    print("Copy these into DemoBudget.swift:")
    print(f'  public static let artifactSHA256 = "{sha}"')
    print(f"  public static let artifactByteCount = {size}")
    print(
        f'  static let fixtureMonth = "{today.year:04d}-{today.month:02d}"'
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
