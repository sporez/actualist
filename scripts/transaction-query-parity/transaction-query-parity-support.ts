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
export const EXPECTED_CASE_COUNT = 46;
export const EVIDENCE_SCHEMA_VERSION = 1;

export type JSONPrimitive = boolean | null | number | string;
export type JSONValue =
  | JSONPrimitive
  | JSONValue[]
  | { [key: string]: JSONValue };

export type OracleCaseDefinition = {
  assertions: string[];
  gate: 'Q1' | 'Q2' | 'Q3';
  id: string;
  input: Record<string, JSONValue>;
  sourcePrediction: Record<string, JSONValue>;
  sourceReferences: Array<{
    lines: string;
    path: string;
    relevance: string;
  }>;
};

type OracleCaseEvidence = OracleCaseDefinition & {
  failure: string | null;
  observed: Record<string, JSONValue> | null;
  state: 'pending' | 'running' | 'passed' | 'failed';
};

type OracleEvidence = {
  cases: OracleCaseEvidence[];
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
    schemaVersion: number;
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

export type NormalizedMessage = {
  column: string;
  dataset: string;
  row: string;
  value: JSONPrimitive;
};

export type QueryTransaction = {
  _unmatched?: boolean;
  account: string | null;
  category: string | null;
  date: string;
  id: string;
  is_child: boolean;
  is_parent: boolean;
  notes: string | null;
  parent_id: string | null;
  payee: string | null;
  subtransactions?: QueryTransaction[];
};

export class OracleRecorder {
  private readonly evidence: OracleEvidence;
  private readonly outputPath: string;

  constructor(definitions: OracleCaseDefinition[]) {
    const outputPath = process.env.ACTUAL_TRANSACTION_QUERY_PARITY_EVIDENCE;
    if (!outputPath) {
      throw new Error(
        'ACTUAL_TRANSACTION_QUERY_PARITY_EVIDENCE must name the evidence file',
      );
    }
    if (definitions.length !== EXPECTED_CASE_COUNT) {
      throw new Error(
        `Expected ${EXPECTED_CASE_COUNT} cases, received ${definitions.length}`,
      );
    }
    const identities = definitions.map(definition => definition.id);
    if (new Set(identities).size !== identities.length) {
      throw new Error('Oracle case identities must be unique');
    }

    this.outputPath = outputPath;
    this.evidence = {
      cases: definitions.map(definition => ({
        ...definition,
        failure: null,
        observed: null,
        state: 'pending',
      })),
      completed: false,
      failedCriterion: null,
      generatedAt: new Date().toISOString(),
      harness: {
        actualCommit:
          process.env.ACTUAL_TRANSACTION_QUERY_PARITY_COMMIT ?? 'missing',
        actualTag: process.env.ACTUAL_TRANSACTION_QUERY_PARITY_TAG ?? 'missing',
        actualVersion:
          process.env.ACTUAL_TRANSACTION_QUERY_PARITY_VERSION ?? 'missing',
        caseCount: definitions.length,
        caseIdentities: identities,
        evidencePolicy:
          'sourcePrediction is pre-run source analysis; observed is runtime evidence; assertions are independently evaluated criteria',
        schemaVersion: EVIDENCE_SCHEMA_VERSION,
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
    item.state = 'passed';
    this.persist();
  }

  fail(
    id: string,
    error: unknown,
    observed: Record<string, JSONValue> | null,
  ): void {
    const item = this.caseEvidence(id);
    item.failure = normalizeError(error);
    item.observed = observed;
    item.state = 'failed';
    this.persist();
  }

  finish(failures: string[]): void {
    const unfinished = this.evidence.cases
      .filter(item => item.state === 'pending' || item.state === 'running')
      .map(item => item.id);
    this.evidence.completed = unfinished.length === 0;
    this.evidence.failedCriterion =
      failures.length > 0
        ? failures.join('; ')
        : unfinished.length > 0
          ? `unfinished cases: ${unfinished.join(', ')}`
          : null;
    this.persist();
  }

  private caseEvidence(id: string): OracleCaseEvidence {
    const item = this.evidence.cases.find(candidate => candidate.id === id);
    if (!item) throw new Error(`Unknown oracle case ${id}`);
    return item;
  }

  private persist(): void {
    mkdirSync(dirname(this.outputPath), { recursive: true });
    const temporaryPath = `${this.outputPath}.tmp`;
    writeFileSync(
      temporaryPath,
      `${JSON.stringify(this.evidence, null, 2)}\n`,
      'utf8',
    );
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
      throw new Error(
        `Expected Actual ${EXPECTED_ACTUAL_COMMIT}, received ${this.evidence.harness.actualCommit}`,
      );
    }
    if (this.evidence.harness.actualTag !== 'v26.9.0') {
      throw new Error(
        `Expected Actual tag v26.9.0, received ${this.evidence.harness.actualTag}`,
      );
    }
    if (this.evidence.harness.actualVersion !== '26.9.0') {
      throw new Error(
        `Expected Actual core 26.9.0, received ${this.evidence.harness.actualVersion}`,
      );
    }
    if (this.evidence.harness.timezone !== 'UTC') {
      throw new Error(
        `Expected UTC timezone, received ${this.evidence.harness.timezone}`,
      );
    }
  }
}

export async function crdtMarker(): Promise<number> {
  const row = await db.first<{ maximum: number | null }>(
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
    column: row.column,
    dataset: row.dataset,
    row: row.row,
    value: deserializeValue(row.serialized_value) as JSONPrimitive,
  }));
}

export async function rawFilterRows(): Promise<
  Array<Record<string, JSONPrimitive>>
> {
  const rows = await db.all<Record<string, unknown>>(
    `SELECT id, name, conditions, conditions_op, tombstone
       FROM transaction_filters
      ORDER BY name, id`,
  );
  return normalizeRows(rows);
}

export async function rawTransactionRows(): Promise<
  Array<Record<string, JSONPrimitive>>
> {
  const rows = await db.all<Record<string, unknown>>(
    `SELECT id, isParent, isChild, parent_id, acct, category, description,
            notes, date, tombstone, sort_order
       FROM transactions
      ORDER BY id`,
  );
  return normalizeRows(rows);
}

export async function rawQueryFixture(): Promise<
  Record<string, JSONValue>
> {
  const [
    accounts,
    categories,
    categoryMappings,
    payees,
    payeeMappings,
    transactions,
  ] = await Promise.all([
      db.all<Record<string, unknown>>(
        'SELECT id, name, offbudget, closed, tombstone FROM accounts ORDER BY id',
      ),
      db.all<Record<string, unknown>>(
        'SELECT id, name, cat_group, tombstone FROM categories ORDER BY id',
      ),
      db.all<Record<string, unknown>>(
        'SELECT id, transferId FROM category_mapping ORDER BY id',
      ),
      db.all<Record<string, unknown>>(
        'SELECT id, name, transfer_acct, tombstone FROM payees ORDER BY id',
      ),
      db.all<Record<string, unknown>>(
        'SELECT id, targetId FROM payee_mapping ORDER BY id',
      ),
      rawTransactionRows(),
    ]);
  return {
    accounts: normalizeRows(accounts),
    categories: normalizeRows(categories),
    categoryMappings: normalizeRows(categoryMappings),
    payees: normalizeRows(payees),
    payeeMappings: normalizeRows(payeeMappings),
    transactions,
  };
}

export function normalizeQueryRows(rows: unknown[]): QueryTransaction[] {
  return rows.map(row => {
    const value = row as Record<string, unknown>;
    const normalized: QueryTransaction = {
      account: nullableString(value.account),
      category: nullableString(value.category),
      date: String(value.date),
      id: String(value.id),
      is_child: Boolean(value.is_child),
      is_parent: Boolean(value.is_parent),
      notes: nullableString(value.notes),
      parent_id: nullableString(value.parent_id),
      payee: nullableString(value.payee),
    };
    if (value._unmatched === true) normalized._unmatched = true;
    if (Array.isArray(value.subtransactions)) {
      normalized.subtransactions = normalizeQueryRows(value.subtransactions);
    }
    return normalized;
  });
}

export function flattenQueryIDs(rows: QueryTransaction[]): string[] {
  return rows
    .flatMap(row => [
      row.id,
      ...(row.subtransactions ? flattenQueryIDs(row.subtransactions) : []),
    ])
    .sort();
}

export function queryRootIDs(rows: QueryTransaction[]): string[] {
  return rows.map(row => row.id).sort();
}

export function toJSON(value: unknown): JSONValue {
  return JSON.parse(JSON.stringify(value)) as JSONValue;
}

export function normalizeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}

function normalizeRows(
  rows: Array<Record<string, unknown>>,
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
        return [key, String(value)];
      }),
    ),
  );
}

function nullableString(value: unknown): string | null {
  return value === null || value === undefined ? null : String(value);
}
