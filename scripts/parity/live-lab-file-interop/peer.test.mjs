// Node side of the live-lab ZIP and CSV interop checks (see README.md). One
// vitest run per LAB_STEP so the Swift phases can interleave. Reads
// ACTUAL_LAB_URL and ACTUAL_LAB_PASSWORD from the environment and never
// prints either. Every comparison is written to a report-*.json file; run.sh
// turns the reports into the exit status.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

import * as api from '@harness/api';

const upstream = process.env.ACTUALIST_PARITY_ORACLE_ROOT;
const { applyFieldMappings, parseAmountFields, parseCategoryFields, parseDate } = await import(
  path.join(upstream, 'packages/desktop-client/src/components/modals/ImportTransactionsModal/utils.ts')
);
const { amountToInteger } = await import(path.join(upstream, 'packages/loot-core/src/shared/util.ts'));

const step = process.env.LAB_STEP;
const url = process.env.ACTUAL_LAB_URL;
const password = process.env.ACTUAL_LAB_PASSWORD;
const handoff = process.env.ACTUAL_LAB_HANDOFF_DIR;
const sourceName = process.env.LAB_SOURCE_BUDGET;

const file = name => path.join(handoff, name);
const readJSON = name => JSON.parse(fs.readFileSync(file(name), 'utf8'));
const writeJSON = (name, value) => fs.writeFileSync(file(name), JSON.stringify(value, null, 2) + '\n');
const say = line => console.log(`LAB| ${line}`);

// ---- clients ----

// `online: false` points the client at a dead port: imports stay local
// (Actual's import tries an upload and ignores the failure).
async function withClient(name, { online }, body) {
  const dataDir = path.join(handoff, `node-${name}`);
  fs.rmSync(dataDir, { recursive: true, force: true });
  fs.mkdirSync(dataDir, { recursive: true });
  const lib = await (online
    ? api.init({ dataDir, serverURL: url, password })
    : api.init({ dataDir, serverURL: 'http://127.0.0.1:59999' }));
  let result;
  try {
    result = await body({ lib, dataDir });
  } finally {
    try { await api.shutdown(); } catch {}
  }
  return result;
}

async function downloadRemote(match) {
  const remote = (await api.getBudgets()).find(match);
  if (!remote) throw new Error('budget not listed on the server');
  await api.downloadBudget(remote.groupId);
  return remote;
}

function localDatabase(dataDir) {
  const dirs = fs.readdirSync(dataDir).filter(d => fs.existsSync(path.join(dataDir, d, 'db.sqlite')));
  if (dirs.length !== 1) throw new Error(`expected one local budget, found ${dirs.length}`);
  return path.join(dataDir, dirs[0], 'db.sqlite');
}

async function accountBalances() {
  const accounts = await api.getAccounts();
  const out = [];
  for (const account of accounts) {
    const { data } = await api.runQuery(
      api.q('transactions').filter({ account: account.id }).options({ splits: 'inline' }).calculate({ $sum: '$amount' }),
    );
    out.push({ id: account.id, name: account.name, offbudget: !!account.offbudget, closed: !!account.closed, balance: data ?? 0 });
  }
  return out.sort((a, b) => (a.id < b.id ? -1 : 1));
}

// ---- sqlite ----

function sql(db, query, params = []) {
  const bound = params.reduce((text, value) => text.replace('?', `'${String(value).replaceAll("'", "''")}'`), query);
  const out = execFileSync('sqlite3', ['-readonly', '-json', db, bound], { maxBuffer: 1 << 30 }).toString().trim();
  return out ? JSON.parse(out) : [];
}

// Engine bookkeeping that legitimately differs between copies of one budget.
const excludedTables = /^(messages_crdt|messages_clock|messages_pending|kvcache|kvcache_key|sqlite_.*|actualist_.*)$/;

function digest(db) {
  const tables = {};
  const excluded = {};
  for (const { name } of sql(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
    if (excludedTables.test(name)) {
      excluded[name] = sql(db, `SELECT COUNT(*) AS n FROM "${name}"`)[0].n;
      continue;
    }
    const columns = sql(db, `PRAGMA table_info("${name}")`).map(c => c.name);
    const where = columns.includes('tombstone') ? ' WHERE tombstone = 0' : '';
    const lines = sql(db, `SELECT * FROM "${name}"${where}`)
      .map(row => JSON.stringify(Object.keys(row).sort().map(k => [k, row[k]])))
      .sort();
    tables[name] = { count: lines.length, hash: createHash('sha256').update(lines.join('\n')).digest('hex'), lines };
  }
  return { tables, excluded };
}

function compareDigests(expected, actual) {
  const names = [...new Set([...Object.keys(expected.tables), ...Object.keys(actual.tables)])].sort();
  const differences = [];
  for (const name of names) {
    const a = expected.tables[name];
    const b = actual.tables[name];
    if (!a || !b) {
      differences.push({ table: name, missingFrom: a ? 'actual' : 'expected' });
      continue;
    }
    if (a.hash === b.hash) continue;
    const inB = new Set(b.lines);
    const inA = new Set(a.lines);
    const short = line => (line.length > 400 ? line.slice(0, 400) + '…' : line);
    differences.push({
      table: name,
      expectedCount: a.count,
      actualCount: b.count,
      onlyExpected: a.lines.filter(l => !inB.has(l)).slice(0, 5).map(short),
      onlyActual: b.lines.filter(l => !inA.has(l)).slice(0, 5).map(short),
    });
  }
  return { equal: differences.length === 0, tables: names.length, differences };
}

function compareBalances(expected, actual) {
  const byID = new Map(actual.map(a => [a.id, a]));
  const mismatches = [];
  for (const account of expected) {
    const other = byID.get(account.id);
    if (!other || other.balance !== account.balance) {
      mismatches.push({ id: account.id, name: account.name, expected: account.balance, actual: other?.balance ?? 'missing' });
    }
  }
  return { equal: mismatches.length === 0 && expected.length === actual.length, expectedCount: expected.length, actualCount: actual.length, mismatches };
}

// Transactions of one account as comparable values (no ids), starting
// balance rows left out.
function accountRows(db, accountID) {
  return sql(
    db,
    `SELECT t.date, t.amount, t.notes, t.cleared, t.reconciled, t.isParent, t.isChild,
            p.name AS payee, c.name AS category
       FROM transactions t
       LEFT JOIN payee_mapping pm ON pm.id = t.description
       LEFT JOIN payees p ON p.id = pm.targetId
       LEFT JOIN category_mapping cm ON cm.id = t.category
       LEFT JOIN categories c ON c.id = cm.transferId
      WHERE t.acct = ? AND t.tombstone = 0 AND COALESCE(t.starting_balance_flag, 0) = 0`,
    [accountID],
  ).map(r => JSON.stringify([r.date, r.amount, r.payee ?? '', r.notes ?? '', r.category ?? '', r.cleared, r.isParent, r.isChild]));
}

// Actual's import modal clears every row by default ("Clear transactions on
// import"); Actualist keeps each row's Cleared value. Row comparisons are
// reported with and without the cleared field so one does not hide the other.
const withoutCleared = rows => rows.map(line => {
  const fields = JSON.parse(line);
  fields.splice(5, 1);
  return JSON.stringify(fields);
});

function compareImportedRows(expected, actual) {
  return { ...compareRows(expected, actual), ignoringCleared: compareRows(withoutCleared(expected), withoutCleared(actual)) };
}

function compareRows(expected, actual) {
  const count = list => list.reduce((m, l) => m.set(l, (m.get(l) ?? 0) + 1), new Map());
  const a = count(expected);
  const b = count(actual);
  const minus = (x, y) => [...x].flatMap(([l, n]) => Array(Math.max(0, n - (y.get(l) ?? 0))).fill(l));
  const onlyExpected = minus(a, b);
  const onlyActual = minus(b, a);
  return {
    equal: onlyExpected.length === 0 && onlyActual.length === 0,
    expectedCount: expected.length,
    actualCount: actual.length,
    fields: '[date, amount, payee, notes, category, cleared, isParent, isChild]',
    onlyExpected: onlyExpected.slice(0, 10),
    onlyActual: onlyActual.slice(0, 10),
    onlyExpectedCount: onlyExpected.length,
    onlyActualCount: onlyActual.length,
  };
}

// ---- CSV ----

// The steps Actual's import modal runs on Import for a headered CSV with the
// default field mapping, date format, cleared and notes settings
// (ImportTransactionsModal.tsx onImport, without the preview UI).
async function importCSVLikeActual(lib, csvPath, accountId) {
  const parsed = await lib.send('transactions-parse-file', {
    filepath: csvPath,
    options: { hasHeaderRow: true, delimiter: ',', skipStartLines: 0, skipEndLines: 0 },
  });
  if (parsed.errors?.length) return { error: `parse errors: ${JSON.stringify(parsed.errors).slice(0, 300)}` };
  const categories = (await api.getCategories()).map(c => ({ id: c.id, name: c.name }));
  const mappings = { date: 'Date', amount: 'Amount', payee: 'Payee', notes: 'Notes', category: 'Category', inOut: null, outflow: null, inflow: null };
  const transactions = [];
  for (const [index, raw] of parsed.transactions.entries()) {
    const trans = applyFieldMappings(
      { ...raw, trx_id: String(index), existing: false, ignored: false, selected: true, selected_merge: false },
      mappings,
    );
    const date = parseDate(trans.date, 'yyyy mm dd');
    if (date == null) return { error: `unparseable date ${trans.date}` };
    const { amount } = parseAmountFields(trans, false, false, '', false, '');
    trans.category = parseCategoryFields(trans, categories);
    const { inflow, outflow, inOut, existing, ignored, selected, selected_merge, trx_id, ...rest } = trans;
    transactions.push({ ...rest, date, amount: amountToInteger(amount), cleared: true, notes: rest.notes });
  }
  const result = await lib.send('transactions-import', { accountId, transactions, isPreview: false });
  return { parsedRows: parsed.transactions.length, added: result?.added?.length ?? 0, updated: result?.updated?.length ?? 0, errors: result?.errors ?? [] };
}

function parseCSVRows(lib, csvPath) {
  return lib.send('transactions-parse-file', {
    filepath: csvPath,
    options: { hasHeaderRow: true, delimiter: ',', skipStartLines: 0, skipEndLines: 0 },
  });
}

async function compareCSVFiles(lib, expectedPath, actualPath) {
  const expected = await parseCSVRows(lib, expectedPath);
  const actual = await parseCSVRows(lib, actualPath);
  const header = rows => Object.keys(rows?.[0] ?? {});
  const lines = rows => (rows ?? []).map(r => JSON.stringify(r));
  const rows = compareRows(lines(expected.transactions), lines(actual.transactions));
  const sameOrder = JSON.stringify(lines(expected.transactions)) === JSON.stringify(lines(actual.transactions));
  return {
    equal: rows.equal && JSON.stringify(header(expected.transactions)) === JSON.stringify(header(actual.transactions)),
    sameOrder,
    expectedHeader: header(expected.transactions),
    actualHeader: header(actual.transactions),
    parseErrors: { expected: expected.errors ?? [], actual: actual.errors ?? [] },
    rows: { ...rows, fields: 'parsed CSV row objects' },
  };
}

// ---- server ----

async function deleteServerFile(fileId) {
  const login = await fetch(`${url}/account/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password }),
  });
  const token = (await login.json())?.data?.token;
  if (!token) throw new Error(`login failed (HTTP ${login.status})`);
  const res = await fetch(`${url}/sync/delete-user-file`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-actual-token': token },
    body: JSON.stringify({ fileId }),
  });
  if (!res.ok) throw new Error(`delete failed (HTTP ${res.status})`);
}

// ---- steps ----

const steps = {
  // Download the source budget with Actual, export its ZIP and the CSVs of
  // one split-heavy and one split-free account, and record its digest.
  async prepare() {
    const source = await withClient('source', { online: true }, async ({ lib, dataDir }) => {
      const remote = await downloadRemote(b => b.name === sourceName);
      fs.writeFileSync(file('actual-export.zip'), await api.exportBudget());
      const db = localDatabase(dataDir);
      const split = sql(db, `SELECT acct, COUNT(*) AS n FROM transactions WHERE tombstone = 0 AND isParent = 1 GROUP BY acct ORDER BY n DESC LIMIT 1`)[0];
      const plain = sql(
        db,
        `SELECT t.acct, COUNT(*) AS n FROM transactions t JOIN accounts a ON a.id = t.acct
          WHERE t.tombstone = 0 AND a.closed = 0 AND a.tombstone = 0
            AND t.acct NOT IN (SELECT acct FROM transactions WHERE isParent = 1 AND tombstone = 0)
          GROUP BY t.acct ORDER BY n DESC LIMIT 1`,
      )[0];
      const accounts = await accountBalances();
      const csvAccounts = [];
      for (const [key, pick] of [['split', split], ['plain', plain]]) {
        if (!pick) continue;
        const account = accounts.find(a => a.id === pick.acct);
        const csv = await lib.send('transactions-export-query', {
          query: api.q('transactions').filter({ account: pick.acct }).options({ splits: 'grouped' }).select('*').serialize(),
        });
        fs.writeFileSync(file(`actual-${key}.csv`), csv);
        csvAccounts.push({ key, id: pick.acct, name: account?.name, offbudget: account?.offbudget ?? false });
      }
      return { fileID: remote.cloudFileId, groupID: remote.groupId, name: remote.name, csvAccounts, accounts };
    });
    const db = localDatabase(path.join(handoff, 'node-source'));
    writeJSON('source.json', source);
    writeJSON('source-digest.json', digest(db));
    say(`prepared ${source.name}: ${source.accounts.length} accounts, CSV accounts ${source.csvAccounts.map(a => `${a.key}=${a.name}`).join(', ')}`);
  },

  async verifyZip() {
    const source = readJSON('source.json');
    const sourceDigest = readJSON('source-digest.json');
    const swift = readJSON('swift-a.json');
    const report = { swiftErrors: swift.errors ?? {} };

    report.actualistReadsSource = compareBalances(source.accounts, swift.sourceAccounts ?? []);
    if (fs.existsSync(file('actualist-source.sqlite'))) {
      report.actualistDownloadMatchesSource = compareDigests(sourceDigest, digest(file('actualist-source.sqlite')));
    }

    // Actualist export → Actual import (local only).
    if (fs.existsSync(file('actualist-export.zip'))) {
      report.actualImportsActualistZip = await withClient('zip-import', { online: false }, async ({ dataDir }) => {
        try {
          await api.importBudget(file('actualist-export.zip'));
        } catch (error) {
          return { equal: false, error: String(error?.message ?? error) };
        }
        const balances = compareBalances(source.accounts, await accountBalances());
        await api.shutdown();
        return { balances, data: compareDigests(sourceDigest, digest(localDatabase(dataDir))) };
      });
    }

    // Actual export → Actualist import: Actualist's local copy, and the copy
    // it uploaded as Actual downloads it.
    if (fs.existsSync(file('imported.json'))) {
      const imported = readJSON('imported.json');
      report.actualistImportsActualZip = {
        balances: compareBalances(source.accounts, swift.importedAccounts ?? []),
        data: fs.existsSync(file('actualist-imported.sqlite'))
          ? compareDigests(sourceDigest, digest(file('actualist-imported.sqlite')))
          : { equal: false, error: 'no snapshot' },
      };
      report.actualReadsActualistUpload = await withClient('upload-check', { online: true }, async ({ dataDir }) => {
        try {
          await downloadRemote(b => b.cloudFileId === imported.fileID);
        } catch (error) {
          return { equal: false, error: String(error?.message ?? error) };
        }
        const balances = compareBalances(source.accounts, await accountBalances());
        await api.shutdown();
        return { balances, data: compareDigests(sourceDigest, digest(localDatabase(dataDir))) };
      });
    }
    writeJSON('report-zip.json', report);
  },

  async verifyCSV() {
    const source = readJSON('source.json');
    const imported = readJSON('imported.json');
    const swift = readJSON('swift-b.json');
    const report = { swiftImports: swift.imports, swiftErrors: swift.errors ?? {}, accounts: {} };

    // Actual imports its own CSV and Actualist's CSV, each into a new account
    // of a local copy of the source budget.
    const actualSide = await withClient('csv', { online: false }, async ({ lib, dataDir }) => {
      await api.importBudget(file('actual-export.zip'));
      const out = {};
      for (const account of source.csvAccounts) {
        const entry = { encoder: await compareCSVFiles(lib, file(`actual-${account.key}.csv`), file(`actualist-${account.key}.csv`)) };
        for (const origin of ['actual', 'actualist']) {
          const id = await api.createAccount({ name: `CSV from ${origin} ${account.key}`, offbudget: account.offbudget }, 0);
          entry[`${origin}Import`] = { id, ...(await importCSVLikeActual(lib, file(`${origin}-${account.key}.csv`), id)) };
        }
        out[account.key] = entry;
      }
      await api.shutdown();
      const db = localDatabase(dataDir);
      for (const entry of Object.values(out)) {
        entry.actualRows = accountRows(db, entry.actualImport.id);
        entry.actualistCSVRows = accountRows(db, entry.actualistImport.id);
      }
      return out;
    });

    // Actualist's local rows right after the import, before sync.
    const localDB = file('actualist-csv.sqlite');
    const localRows = Object.fromEntries(
      source.csvAccounts.map(a => {
        const id = (swift.imports ?? []).find(i => i.key === a.key)?.accountID;
        return [a.key, id && fs.existsSync(localDB) ? accountRows(localDB, id) : null];
      }),
    );

    // The server copy Actualist imported into, as Actual downloads it.
    const serverRows = await withClient('csv-server', { online: true }, async ({ dataDir }) => {
      await downloadRemote(b => b.cloudFileId === imported.fileID);
      const names = Object.fromEntries((await api.getAccounts()).map(a => [a.name, a.id]));
      await api.shutdown();
      const db = localDatabase(dataDir);
      return Object.fromEntries(
        source.csvAccounts.map(a => {
          const id = names[`CSV Import ${a.key}`];
          return [a.key, id ? accountRows(db, id) : null];
        }),
      );
    });

    for (const account of source.csvAccounts) {
      const entry = actualSide[account.key];
      report.accounts[account.key] = {
        sourceAccount: account.name,
        encoderParity: entry.encoder,
        actualImport: entry.actualImport,
        actualistCSVInActual: {
          import: entry.actualistImport,
          rowsVsActualCSV: compareRows(entry.actualRows, entry.actualistCSVRows),
        },
        actualCSVInActualist: localRows[account.key]
          ? compareImportedRows(entry.actualRows, localRows[account.key])
          : { equal: false, error: 'no local import result' },
        actualistCSVImportOnServer: serverRows[account.key] && localRows[account.key]
          ? compareRows(localRows[account.key], serverRows[account.key])
          : { equal: false, error: 'account missing from the server copy or the local snapshot' },
      };
    }
    writeJSON('report-csv.json', report);
  },

  async cleanup() {
    if (!fs.existsSync(file('imported.json'))) return;
    const { fileID } = readJSON('imported.json');
    await deleteServerFile(fileID);
    say(`deleted imported server file ${fileID}`);
  },
};

test(`step ${step}`, async () => {
  if (!steps[step]) throw new Error(`unknown LAB_STEP ${step}`);
  await steps[step]();
});
