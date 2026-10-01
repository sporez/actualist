import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  writeFileSync,
} from 'node:fs';
import { dirname } from 'node:path';

import * as db from '#server/db';
import { deserializeValue } from '#server/sync';

export const EXPECTED_ACTUAL_COMMIT =
  '59fe126f637d858c061e1eeedbef5436c8f2225a';
export const EXPECTED_CASE_COUNT = 39;

export type JSONPrimitive = boolean | null | number | string;
export type JSONValue =
  | JSONPrimitive
  | JSONValue[]
  | { [key: string]: JSONValue };

export type CommandCase = {
  expectedObservation?: string;
  gate: 'D1' | 'D2' | 'M1' | 'M2' | 'M3' | 'M4';
  graph: string;
  id: string;
  selected: string[];
};

type CaseEvidence = CommandCase & {
  failure: string | null;
  observed: Record<string, JSONValue> | null;
  state: 'pending' | 'running' | 'captured' | 'failed';
};

type Evidence = {
  cases: CaseEvidence[];
  completed: boolean;
  failedCriterion: string | null;
  generatedAt: string;
  harness: {
    actualCommit: string;
    actualTag: string;
    actualVersion: string;
    caseCount: number;
    caseIdentities: string[];
    evidencePolicy: string;
    schemaVersion: 1;
    syntheticDataOnly: true;
    timezone: string;
  };
};

type MessageRow = {
  column: string;
  dataset: string;
  id: number;
  row: string;
  serialized_value: string;
};

export class CommandOracleRecorder {
  private readonly evidence: Evidence;
  private readonly outputPath: string;

  constructor(cases: CommandCase[]) {
    const outputPath = process.env.ACTUAL_TRANSACTION_COMMAND_PARITY_EVIDENCE;
    if (!outputPath) {
      throw new Error(
        'ACTUAL_TRANSACTION_COMMAND_PARITY_EVIDENCE must name the evidence file',
      );
    }
    if (cases.length !== EXPECTED_CASE_COUNT) {
      throw new Error(`Expected ${EXPECTED_CASE_COUNT} cases, received ${cases.length}`);
    }
    const identities = cases.map(item => item.id);
    if (new Set(identities).size !== identities.length) {
      throw new Error('Command oracle case identities must be unique');
    }
    const counts = new Set(cases.map(item => item.gate));
    for (const gate of ['D1', 'D2', 'M1', 'M2', 'M3', 'M4']) {
      if (!counts.has(gate as CommandCase['gate'])) {
        throw new Error(`Missing command oracle gate ${gate}`);
      }
    }

    this.outputPath = outputPath;
    this.evidence = {
      cases: cases.map(item => ({
        ...item,
        failure: null,
        observed: null,
        state: 'pending',
      })),
      completed: false,
      failedCriterion: null,
      generatedAt: new Date().toISOString(),
      harness: {
        actualCommit: process.env.ACTUAL_TRANSACTION_COMMAND_PARITY_COMMIT ?? 'missing',
        actualTag: process.env.ACTUAL_TRANSACTION_COMMAND_PARITY_TAG ?? 'missing',
        actualVersion: process.env.ACTUAL_TRANSACTION_COMMAND_PARITY_VERSION ?? 'missing',
        caseCount: cases.length,
        caseIdentities: identities,
        evidencePolicy:
          'No expected outcome is synthesized. Each case records source rows, actual handler result/refusal, physical rows, CRDT deltas, and the actual upstream undo result.',
        schemaVersion: 1,
        syntheticDataOnly: true,
        timezone: process.env.TZ ?? 'missing',
      },
    };
    this.validateHarness();
    this.persist();
  }

  begin(id: string): void {
    const item = this.caseEvidence(id);
    item.state = 'running';
    item.failure = null;
    item.observed = null;
    this.persist();
  }

  pass(id: string, observed: Record<string, JSONValue>): void {
    const item = this.caseEvidence(id);
    item.observed = observed;
    item.state = 'captured';
    this.persist();
  }

  fail(id: string, failure: string): void {
    const item = this.caseEvidence(id);
    item.failure = failure;
    item.state = 'failed';
    this.persist();
  }

  finish(failures: string[]): void {
    const unfinished = this.evidence.cases
      .filter(item => item.state === 'pending' || item.state === 'running')
      .map(item => item.id);
    const failed = this.evidence.cases
      .filter(item => item.state === 'failed')
      .map(item => item.id);
    this.evidence.completed = unfinished.length === 0 && failed.length === 0;
    this.evidence.failedCriterion =
      failures.length > 0
        ? failures.join('; ')
        : failed.length > 0
          ? `failed cases: ${failed.join(', ')}`
          : unfinished.length > 0
            ? `unfinished cases: ${unfinished.join(', ')}`
            : null;
    this.persist();
  }

  private caseEvidence(id: string): CaseEvidence {
    const item = this.evidence.cases.find(candidate => candidate.id === id);
    if (!item) throw new Error(`Unknown command oracle case ${id}`);
    return item;
  }

  private persist(): void {
    mkdirSync(dirname(this.outputPath), { recursive: true });
    const temporaryPath = `${this.outputPath}.tmp`;
    writeFileSync(temporaryPath, `${JSON.stringify(this.evidence, null, 2)}\n`, 'utf8');
    const fileDescriptor = openSync(temporaryPath, 'r');
    fsyncSync(fileDescriptor);
    closeSync(fileDescriptor);
    renameSync(temporaryPath, this.outputPath);
    const directoryDescriptor = openSync(dirname(this.outputPath), 'r');
    fsyncSync(directoryDescriptor);
    closeSync(directoryDescriptor);
  }

  private validateHarness(): void {
    if (this.evidence.harness.actualCommit !== EXPECTED_ACTUAL_COMMIT) {
      throw new Error(`Expected Actual ${EXPECTED_ACTUAL_COMMIT}`);
    }
    if (this.evidence.harness.actualTag !== 'v26.9.0') {
      throw new Error(`Expected Actual tag v26.9.0, found ${this.evidence.harness.actualTag}`);
    }
    if (this.evidence.harness.actualVersion !== '26.9.0') {
      throw new Error(`Expected core 26.9.0, found ${this.evidence.harness.actualVersion}`);
    }
    if (this.evidence.harness.timezone !== 'UTC') {
      throw new Error(`Expected UTC timezone, found ${this.evidence.harness.timezone}`);
    }
  }
}

export async function crdtMarker(): Promise<number> {
  const row = await db.first<{ maximum: number | null }>(
    'SELECT MAX(id) AS maximum FROM messages_crdt',
  );
  return row?.maximum ?? 0;
}

export async function crdtMessagesSince(marker: number) {
  const rows = await db.all<MessageRow>(
    `SELECT id, dataset, row, column, CAST(value AS TEXT) AS serialized_value
       FROM messages_crdt
      WHERE id > ?
      ORDER BY id`,
    [marker],
  );
  return rows.map(row => ({
    column: row.column,
    dataset: row.dataset,
    row: row.row,
    value: deserializeValue(row.serialized_value) as JSONPrimitive,
  }));
}

export async function rawTransactionRows(): Promise<Record<string, JSONPrimitive>[]> {
  // Read the physical table (init.sql plus migrations), not public AQL aliases.
  const rows = await db.all<Record<string, unknown>>(
    `SELECT id,
            isParent AS is_parent,
            isChild AS is_child,
            acct AS account,
            category AS category_mapping_id,
            amount,
            description AS payee_mapping_id,
            notes,
            date,
            financial_id AS imported_id,
            type,
            location,
            error,
            imported_description AS imported_payee,
            starting_balance_flag,
            transferred_id AS transfer_id,
            sort_order,
            tombstone,
            parent_id,
            cleared,
            pending,
            reconciled,
            schedule,
            raw_synced_data
       FROM transactions
      ORDER BY id`,
  );
  return rows.map(row =>
    Object.fromEntries(
      Object.entries(row).map(([key, value]) => [
        key,
        value === null || typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string'
          ? value
          : String(value),
      ]),
    ),
  );
}

export async function rawReferenceRows(): Promise<{
  accounts: Record<string, JSONPrimitive>[];
  categories: Record<string, JSONPrimitive>[];
  categoryGroups: Record<string, JSONPrimitive>[];
  categoryMappings: Record<string, JSONPrimitive>[];
  payees: Record<string, JSONPrimitive>[];
  payeeMappings: Record<string, JSONPrimitive>[];
  rules: Record<string, JSONPrimitive>[];
  schedules: Record<string, JSONPrimitive>[];
}> {
  const [
    accounts,
    categories,
    categoryGroups,
    categoryMappings,
    payees,
    payeeMappings,
    rules,
    schedules,
  ] = await Promise.all([
    db.all<Record<string, unknown>>(
      'SELECT id, name, offbudget, tombstone FROM accounts ORDER BY id',
    ),
    db.all<Record<string, unknown>>(`
      SELECT id, name, is_income, cat_group, hidden, sort_order, tombstone
      FROM categories
      ORDER BY id
    `),
    db.all<Record<string, unknown>>(`
      SELECT id, name, is_income, hidden, sort_order, tombstone
      FROM category_groups
      ORDER BY id
    `),
    db.all<Record<string, unknown>>(
      'SELECT id, transferId AS category_id FROM category_mapping ORDER BY id',
    ),
    db.all<Record<string, unknown>>(
      'SELECT id, name, transfer_acct, tombstone FROM payees ORDER BY id',
    ),
    db.all<Record<string, unknown>>(
      'SELECT id, targetId AS payee_id FROM payee_mapping ORDER BY id',
    ),
    db.all<Record<string, unknown>>('SELECT * FROM rules ORDER BY id'),
    db.all<Record<string, unknown>>(
      'SELECT id, sort_order FROM schedules ORDER BY id',
    ),
  ]);
  const normalize = (rows: Array<Record<string, unknown>>) =>
    rows.map(row =>
      Object.fromEntries(
        Object.entries(row).map(([key, value]) => [
          key,
          value === null || typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string'
            ? value
            : String(value),
        ]),
      ) as Record<string, JSONPrimitive>,
    );
  return {
    accounts: normalize(accounts),
    categories: normalize(categories),
    categoryGroups: normalize(categoryGroups),
    categoryMappings: normalize(categoryMappings),
    payees: normalize(payees),
    payeeMappings: normalize(payeeMappings),
    rules: normalize(rules),
    schedules: normalize(schedules),
  };
}

export function normalizeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}

export function toJSON(value: unknown): JSONValue {
  if (value === undefined) return null;
  return JSON.parse(JSON.stringify(value)) as JSONValue;
}
