import { writeFileSync } from 'node:fs';

import * as db from '#server/db';
import { deserializeValue } from '#server/sync';

export const FIXED_DAY = '2026-09-27';
export const FIXED_DATE_INTEGER = 20260927;
export const RAW_SCHEMA_VERSION = 1;

export type JSONPrimitive = boolean | null | number | string;
export type JSONValue =
  | JSONPrimitive
  | JSONValue[]
  | { [key: string]: JSONValue };

export type NormalizedMessage = {
  dataset: string;
  row: string;
  column: string;
  value: JSONPrimitive;
};

export type DomainSnapshot = {
  accounts: Array<Record<string, JSONPrimitive>>;
  banks: Array<Record<string, JSONPrimitive>>;
  payees: Array<Record<string, JSONPrimitive>>;
  transactions: Array<Record<string, JSONPrimitive>>;
  rules: Array<Record<string, JSONPrimitive>>;
  schedules: Array<Record<string, JSONPrimitive>>;
  scheduleDates: Array<Record<string, JSONPrimitive>>;
};

export type OracleCase = {
  id: string;
  input: Record<string, JSONValue>;
  assertions: string[];
  observed: Record<string, JSONValue>;
};

type MessageRow = {
  id: number;
  dataset: string;
  row: string;
  column: string;
  serialized_value: string;
};

type CountRow = { count: number };
type MaxRow = { maximum: number | null };

function normalizeRows<T extends Record<string, unknown>>(
  rows: T[],
): Array<Record<string, JSONPrimitive>> {
  return rows.map(row =>
    Object.fromEntries(
      Object.entries(row).map(([key, value]) => {
        if (
          value === null ||
          typeof value === 'boolean' ||
          typeof value === 'number' ||
          typeof value === 'string'
        ) {
          return [key, value];
        }
        if (value instanceof Uint8Array) {
          return [key, new TextDecoder().decode(value)];
        }
        throw new Error(
          `Unsupported SQLite fixture value for ${key}: ${String(value)}`,
        );
      }),
    ),
  );
}

export async function crdtMarker(): Promise<number> {
  const row = await db.first<MaxRow>(
    'SELECT MAX(id) AS maximum FROM messages_crdt',
  );
  return row?.maximum ?? 0;
}

export async function crdtMessagesSince(
  marker: number,
): Promise<NormalizedMessage[]> {
  const rows = await db.all<MessageRow>(
    `SELECT id, dataset, row, column, CAST(value AS TEXT) AS serialized_value
       FROM messages_crdt
      WHERE id > ?
      ORDER BY id`,
    [marker],
  );
  return rows.map(row => ({
    dataset: row.dataset,
    row: row.row,
    column: row.column,
    value: deserializeValue(row.serialized_value),
  }));
}

export async function crdtCount(): Promise<number> {
  const row = await db.first<CountRow>(
    'SELECT COUNT(*) AS count FROM messages_crdt',
  );
  return row?.count ?? 0;
}

export async function domainSnapshot(): Promise<DomainSnapshot> {
  const [accounts, banks, payees, transactions, rules, schedules, scheduleDates] =
    await Promise.all([
      db.all<Record<string, unknown>>(
        `SELECT id, name, offbudget, closed, tombstone, sort_order,
                account_id, bank, balance_current, balance_available,
                balance_limit, account_sync_source, bank_sync_status,
                last_sync, account_group_id
           FROM accounts
          ORDER BY id`,
      ),
      db.all<Record<string, unknown>>(
        'SELECT id, bank_id, name, tombstone FROM banks ORDER BY id',
      ),
      db.all<Record<string, unknown>>(
        `SELECT id, name, transfer_acct, favorite, learn_categories, tombstone
           FROM payees
          ORDER BY id`,
      ),
      db.all<Record<string, unknown>>(
        `SELECT id, isParent, isChild, parent_id, acct, category, amount,
                description, notes, date, financial_id, transferred_id,
                sort_order, tombstone, cleared, reconciled, schedule,
                starting_balance_flag
           FROM transactions
          ORDER BY id`,
      ),
      db.all<Record<string, unknown>>(
        `SELECT id, stage, conditions, conditions_op, actions, tombstone
           FROM rules
          ORDER BY id`,
      ),
      db.all<Record<string, unknown>>(
        `SELECT id, name, rule, active, completed, posts_transaction,
                custom_upcoming_length, tombstone, sort_order
           FROM schedules
          ORDER BY id`,
      ),
      db.all<Record<string, unknown>>(
        `SELECT id, schedule_id, local_next_date, local_next_date_ts,
                base_next_date, base_next_date_ts
           FROM schedules_next_date
          ORDER BY id`,
      ),
    ]);

  return {
    accounts: normalizeRows(accounts),
    banks: normalizeRows(banks),
    payees: normalizeRows(payees),
    transactions: normalizeRows(transactions),
    rules: normalizeRows(rules),
    schedules: normalizeRows(schedules),
    scheduleDates: normalizeRows(scheduleDates),
  };
}

export async function accountRow(
  accountID: string,
): Promise<Record<string, JSONPrimitive>> {
  const row = await db.first<Record<string, unknown>>(
    `SELECT id, name, offbudget, closed, tombstone, sort_order,
            account_id, bank, balance_current, balance_available,
            balance_limit, account_sync_source, bank_sync_status,
            last_sync, account_group_id
       FROM accounts
      WHERE id = ?`,
    [accountID],
  );
  if (!row) throw new Error(`Missing synthetic account ${accountID}`);
  return normalizeRows([row])[0];
}

export async function transactionRows(
  accountIDs: string[],
): Promise<Array<Record<string, JSONPrimitive>>> {
  if (accountIDs.length === 0) return [];
  const placeholders = accountIDs.map(() => '?').join(', ');
  const rows = await db.all<Record<string, unknown>>(
    `SELECT id, isParent, isChild, parent_id, acct, category, amount,
            description, notes, date, financial_id, transferred_id,
            sort_order, tombstone, cleared, reconciled, schedule,
            starting_balance_flag
       FROM transactions
      WHERE acct IN (${placeholders})
      ORDER BY id`,
    accountIDs,
  );
  return normalizeRows(rows);
}

export async function scheduleRows(): Promise<{
  rules: Array<Record<string, JSONPrimitive>>;
  schedules: Array<Record<string, JSONPrimitive>>;
  scheduleDates: Array<Record<string, JSONPrimitive>>;
}> {
  const snapshot = await domainSnapshot();
  return {
    rules: snapshot.rules,
    schedules: snapshot.schedules,
    scheduleDates: snapshot.scheduleDates,
  };
}

export function writeOracle(cases: OracleCase[]): void {
  const output = process.env.ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT;
  if (!output) {
    throw new Error(
      'ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT must name the raw output file',
    );
  }
  writeFileSync(
    output,
    `${JSON.stringify(
      {
        schemaVersion: RAW_SCHEMA_VERSION,
        syntheticDataOnly: true,
        amountUnits: 'integer minor units',
        fixedDay: FIXED_DAY,
        normalization: {
          omitted: ['messages_crdt.id', 'messages_crdt.timestamp'],
          preserved: [
            'CRDT emission order',
            'dataset',
            'row',
            'column',
            'typed value',
            'selected raw relational rows',
          ],
        },
        cases,
      },
      null,
      2,
    )}\n`,
  );
}
