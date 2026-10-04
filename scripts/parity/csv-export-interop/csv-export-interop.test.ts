import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const overlay = requiredDirectory('ACTUALIST_CSV_INTEROP_ACTUAL_OVERLAY');
const importFromOverlay = (relativePath: string) =>
  import(/* @vite-ignore */ pathToFileURL(path.join(overlay, relativePath)).href);
const { test } = await importFromOverlay('node_modules/vitest/dist/index.js');
const { parseFile } = await importFromOverlay(
  'packages/loot-core/src/server/transactions/import/parse-file.ts',
);
const { applyFieldMappings, parseAmountFields, parseCategoryFields, parseDate } =
  await importFromOverlay(
    'packages/desktop-client/src/components/modals/ImportTransactionsModal/utils.ts',
  );

type ManifestCase = {
  id: string;
  intent: string;
  expectedRawFields: Record<string, string>;
};

type Manifest = {
  schema: number;
  scope: string;
  generatedFilename: string;
  header: string[];
  source: {
    actualCommit: string;
    actualVersion: string;
    encoderSHA256: string;
    fixtureTestSHA256: string;
  };
  cases: ManifestCase[];
};

const expectedActualCommit = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const expectedNodeVersion = '24.21.0';
const fixtureDirectory = requiredDirectory('ACTUALIST_CSV_INTEROP_FIXTURE_DIR');
const evidenceDirectory = requiredDirectory('ACTUALIST_CSV_INTEROP_EVIDENCE_DIR');
const csvPath = path.join(fixtureDirectory, 'transaction-export.csv');
const manifestPath = path.join(fixtureDirectory, 'manifest.json');
const observationPath = path.join(evidenceDirectory, 'actual-import-observation.json');

const mappings = {
  date: 'Date',
  amount: 'Amount',
  payee: 'Payee',
  notes: 'Notes',
  category: 'Category',
  inOut: null,
  outflow: null,
  inflow: null,
};

function requiredDirectory(name: string): string {
  const value = process.env[name];
  assert.ok(value, `Missing ${name}`);
  const resolved = path.resolve(value);
  const ownedRoot = path.resolve(process.env.ACTUALIST_CSV_INTEROP_OWNED_ROOT ?? '');
  assert.ok(process.env.ACTUALIST_CSV_INTEROP_OWNED_ROOT, 'Missing ACTUALIST_CSV_INTEROP_OWNED_ROOT');
  assert.ok(
    resolved === ownedRoot || resolved.startsWith(`${ownedRoot}${path.sep}`),
    `${name} must remain under the ignored DEV-owned CSV interoperability directory`,
  );
  return resolved;
}

async function writeAtomicJSON(filePath: string, value: unknown) {
  const temporary = `${filePath}.tmp-${process.pid}`;
  await fs.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
    mode: 0o600,
  });
  await fs.rename(temporary, filePath);
}

test('production Swift CSV is observed by pinned Actual parser and desktop mappings', async () => {
  assert.equal(process.versions.node, expectedNodeVersion);
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8')) as Manifest;
  assert.equal(manifest.schema, 1);
  assert.equal(manifest.source.actualCommit, expectedActualCommit);

  const parsed = await parseFile(csvPath, { hasHeaderRow: true });
  assert.deepEqual(parsed.errors, []);
  assert.ok(parsed.transactions);
  assert.equal(parsed.transactions.length, manifest.cases.length);

  const rawRows = parsed.transactions as Array<Record<string, string>>;
  assert.deepEqual(Object.keys(rawRows[0]), manifest.header);
  rawRows.forEach((row, index) => {
    assert.deepEqual(row, manifest.cases[index].expectedRawFields);
  });

  const categoryNames = [...new Set(rawRows.map(row => row.Category).filter(Boolean))];
  const categories = categoryNames.map((name, index) => ({
    id: `synthetic-category-${index + 1}`,
    name,
  }));
  const selectedClearedValue = true;
  const mappedRows = rawRows.map((raw, index) => {
    const transaction = {
      ...raw,
      trx_id: String(index),
      existing: false,
      ignored: false,
      selected: true,
      selected_merge: false,
    };
    const mapped = applyFieldMappings(transaction, mappings);
    const amounts = parseAmountFields(mapped, false, false, '', false, '');
    const parsedDate = parseDate(mapped.date ?? null, 'yyyy mm dd');
    const categoryID = parseCategoryFields(mapped, categories);

    return {
      caseID: manifest.cases[index].id,
      mapped: {
        dateInput: mapped.date ?? null,
        parsedDate,
        amountInput: mapped.amount ?? null,
        amount: amounts.amount,
        inflow: amounts.inflow,
        outflow: amounts.outflow,
        payeeName: mapped.payee_name ?? null,
        notes: mapped.notes ?? null,
        categoryName: mapped.category ?? null,
        categoryID,
        selectedClearedValue,
      },
      exporterOnlyFields: {
        account: raw.Account,
        categoryGroup: raw.Category_Group,
        splitAmount: raw.Split_Amount,
        cleared: raw.Cleared,
      },
    };
  });
  const signOf = (amount: number) =>
    amount < 0 ? 'negative' : amount > 0 ? 'positive' : 'zero';

  await fs.mkdir(evidenceDirectory, { recursive: true, mode: 0o700 });
  await writeAtomicJSON(observationPath, {
    schema: 1,
    outcome: 'parser-and-mapping-observation-passed',
    compatibilityAcceptance: false,
    scope:
      'Pinned Actual parseFile plus desktop mapping helpers only. No import apply, reconciliation, duplicate handling, or split reconstruction ran.',
    source: manifest.source,
    runtime: { node: process.versions.node, actualOverlay: overlay },
    mappings,
    parserErrors: parsed.errors,
    rawRowCount: rawRows.length,
    mappedRowCount: mappedRows.length,
    dateFailures: mappedRows
      .filter(row => row.mapped.parsedDate == null)
      .map(row => ({ caseID: row.caseID, input: row.mapped.dateInput })),
    signs: mappedRows.map(row => ({
      caseID: row.caseID,
      sign: signOf(row.mapped.amount),
    })),
    rawRows,
    mappedRows,
    limitations: [
      'The target Actual account is selected outside CSV field mappings; Account is retained only as a raw observation.',
      'Category_Group has no paired desktop field mapping in this harness.',
      'Split_Amount has no desktop field mapping here. Parent and child records remain separate physical rows.',
      'Cleared is not a desktop FieldMapping target. The recorded selectedClearedValue is a separate UI choice, not a value restored from each CSV row.',
      'Split marker notes are text observations only; no lossless split-family round trip is claimed.',
      'Apostrophe-prefixed formula-trigger strings remain visible in raw rows. Date parsing and numeric precision are recorded from Actual helpers rather than normalized by this harness.',
      'The full modal import/apply path was not executed. Empty-payee handling and final category/account resolution remain outside this observation.',
    ],
  });
});
