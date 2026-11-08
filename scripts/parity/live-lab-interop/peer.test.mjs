// Node peers for the live-lab interop checks. One vitest run per LAB_STEP so
// the Swift phases can interleave (see README.md). Reads ACTUAL_LAB_URL and
// ACTUAL_LAB_PASSWORD from the environment and never prints either.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

import * as api from '@harness/api';

const step = process.env.LAB_STEP;
const url = process.env.ACTUAL_LAB_URL;
const password = process.env.ACTUAL_LAB_PASSWORD;
const handoff = process.env.ACTUAL_LAB_HANDOFF_DIR;

const readJSON = name => JSON.parse(fs.readFileSync(path.join(handoff, name), 'utf8'));
const writeJSON = (name, value) =>
  fs.writeFileSync(path.join(handoff, name), JSON.stringify(value, null, 2) + '\n');
const clientDir = name => {
  const dir = path.join(handoff, `node-${name}`);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};

// `online: false` keeps the client in Actual's "enabled" syncing mode (so its
// writes are recorded as CRDT messages for later upload) but points it at a
// dead port with no login. With no server URL at all upstream disables sync
// and records no messages, which would not model an offline client.
async function withClient(name, { online }, body) {
  const dataDir = clientDir(name);
  await (online
    ? api.init({ dataDir, serverURL: url, password })
    : api.init({ dataDir, serverURL: 'http://127.0.0.1:59999' }));
  try {
    return await body(dataDir);
  } finally {
    try { await api.shutdown(); } catch {}
  }
}

async function openRemote(fileID, dataDir) {
  const remote = (await api.getBudgets()).find(b => b.cloudFileId === fileID);
  if (!remote) throw new Error('budget not listed on the server');
  const known = fs.readdirSync(dataDir).some(d => d.length > 0 && fs.existsSync(path.join(dataDir, d, 'metadata.json')));
  if (!known) await api.downloadBudget(remote.groupId);
  else await api.loadBudget(localID(dataDir));
  return remote;
}

function localID(dataDir) {
  const dirs = fs.readdirSync(dataDir).filter(d => fs.existsSync(path.join(dataDir, d, 'metadata.json')));
  if (dirs.length !== 1) throw new Error(`expected one local budget, found ${dirs.length}`);
  return dirs[0];
}

function merkleHash(dataDir) {
  const db = path.join(dataDir, localID(dataDir), 'db.sqlite');
  const clock = execFileSync('sqlite3', [db, 'SELECT clock FROM messages_clock ORDER BY id LIMIT 1']).toString().trim();
  return JSON.parse(clock).merkle?.hash ?? null;
}

async function dump(dataDir) {
  const { data } = await api.runQuery(
    api.q('transactions').select(['id', 'amount', 'category', 'account']),
  );
  const transactions = data
    .map(t => ({ id: t.id, amount: t.amount, category: t.category ?? '', account: t.account }))
    .sort((a, b) => (a.id < b.id ? -1 : 1));
  return { transactions, merkleHash: merkleHash(dataDir) };
}

const today = new Date().toISOString().slice(0, 10);

test(`step ${step}`, async () => {
  if (step === 'seedA') {
    const { fileID } = readJSON('newbudget.json');
    await withClient('A', { online: true }, async dataDir => {
      const remote = await openRemote(fileID, dataDir);
      const accountID = await api.createAccount({ name: 'Peer Checking' }, 100000);
      const groupID = await api.createCategoryGroup({ name: 'Peer Group' });
      const categoryID = await api.createCategory({ name: 'Peer Food', group_id: groupID });
      await api.addTransactions(accountID, [
        { date: today, amount: -1200, category: categoryID, notes: 'A1' },
        { date: today, amount: -3400, category: categoryID, notes: 'A2' },
        { date: today, amount: 5600, notes: 'A3' },
      ]);
      await api.sync();
      writeJSON('peer-seed.json', { fileID, groupID: remote.groupId, accountID, categoryID });
    });
  } else if (step === 'offlineB') {
    const { fileID, accountID, categoryID } = readJSON('peer-seed.json');
    fs.rmSync(path.join(handoff, 'node-B'), { recursive: true, force: true });
    await withClient('B', { online: true }, dataDir => openRemote(fileID, dataDir));
    // Offline: the server is unreachable, so these messages stay local and carry
    // timestamps older than anything Actualist writes afterwards.
    await withClient('B', { online: false }, async dataDir => {
      await api.loadBudget(localID(dataDir));
      // Under vitest (NODE_ENV=test) load-budget turns syncing off, so writes
      // would not be recorded as CRDT messages. api.sync() sets syncing back to
      // "enabled" before it tries the (unreachable) server and fails.
      await api.sync().catch(() => {});
      // Under NODE_ENV=test every write awaits a full sync and rethrows its
      // network failure after the messages are applied and recorded; ignore it.
      await api.addTransactions(accountID, [
        { date: today, amount: -777, category: categoryID, notes: 'B1' },
        { date: today, amount: -888, notes: 'B2' },
      ]).catch(e => {
        if (!String(e?.message ?? e).includes('network-failure')) throw e;
      });
    });
  } else if (step === 'syncB') {
    const { fileID } = readJSON('peer-seed.json');
    await withClient('B', { online: true }, async dataDir => {
      await openRemote(fileID, dataDir);
      await api.sync();
      writeJSON('node-b-final.json', await dump(dataDir));
    });
  } else if (step === 'final') {
    const { fileID } = readJSON('peer-seed.json');
    await withClient('A', { online: true }, async dataDir => {
      await openRemote(fileID, dataDir);
      await api.sync();
      writeJSON('node-a-final.json', await dump(dataDir));
    });
  } else if (step === 'compare') {
    const a = readJSON('node-a-final.json');
    const b = readJSON('node-b-final.json');
    const swift = readJSON('swift-phase-b.json');
    const canon = rows => JSON.stringify(rows.map(r => [r.id, r.amount, r.category, r.account]));
    const result = {
      nodeAEqualsNodeB: canon(a.transactions) === canon(b.transactions),
      swiftEqualsNodeA: canon(swift.transactions) === canon(a.transactions),
      transactionCount: { nodeA: a.transactions.length, nodeB: b.transactions.length, swift: swift.transactions.length },
      merkle: { nodeA: a.merkleHash, nodeB: b.merkleHash, swift: swift.merkleHash },
      merkleEqual: a.merkleHash === swift.merkleHash && b.merkleHash === swift.merkleHash,
      swiftRequests: { phaseBOpenPull: swift.requestsAfterOpen, phaseBTotal: swift.requestsTotal },
    };
    writeJSON('convergence-result.json', result);
    console.log(JSON.stringify(result));
    expect(result.swiftEqualsNodeA).toBe(true);
    expect(result.nodeAEqualsNodeB).toBe(true);
  } else if (step === 'syncBatchCheck') {
    // LiveLabSyncBatchTests: Actual downloads each budget, syncs and counts the
    // Diag payees; then the budget is deleted from the server.
    const budgets = readJSON('sync-batch.json');
    const login = await fetch(`${url}/account/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    const token = (await login.json())?.data?.token;
    if (!token) throw new Error(`login failed (HTTP ${login.status})`);
    const result = {};
    for (const [label, entry] of Object.entries(budgets)) {
      fs.rmSync(path.join(handoff, `node-batch-${label}`), { recursive: true, force: true });
      result[label] = await withClient(`batch-${label}`, { online: true }, async () => {
        await openRemote(entry.fileID, path.join(handoff, `node-batch-${label}`));
        await api.sync();
        const payees = (await api.getPayees()).filter(p => p.name?.startsWith('Diag ')).length;
        return { swiftOutcome: entry.outcome, swiftPending: entry.pending, expected: entry.expectedPayees, actualPayees: payees };
      });
      await fetch(`${url}/sync/delete-user-file`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-actual-token': token },
        body: JSON.stringify({ fileId: entry.fileID }),
      });
    }
    writeJSON('sync-batch-result.json', result);
    console.log(JSON.stringify(result));
    for (const r of Object.values(result)) {
      expect(r.swiftOutcome).toBe('ok');
      expect(r.actualPayees).toBe(r.expected);
    }
  } else if (step === 'v2611Seed') {
    // LiveLabActual2611Tests: Actual seeds the main budget and records what its
    // own v26.11.0 code decides, for Actualist to match.
    const { fileID } = readJSON('v2611.json');
    fs.rmSync(path.join(handoff, 'node-v2611'), { recursive: true, force: true });
    await withClient('v2611', { online: true }, async dataDir => {
      await openRemote(fileID, dataDir);
      const checkingID = await api.createAccount({ name: 'Interop Checking' }, 0);
      await api.createAccount({ name: 'Interop Savings' }, 12345);
      const tiesID = await api.createAccount({ name: 'Interop Ties' }, 0);
      const storeA = await api.createPayee({ name: 'Interop Store A' });

      // Formulas read amounts: parent -100.00 * 0.5, and 123.45 * -0.1 = -12.345, which
      // Math.round takes to -1234 (ties toward +infinity). The remainder takes the rest.
      await api.createRule({
        stage: null,
        conditionsOp: 'and',
        conditions: [{ op: 'contains', field: 'notes', value: 'Formula Check', type: 'string' }],
        actions: [
          { op: 'set-split-amount', value: 0, options: { splitIndex: 1, method: 'formula', formula: '=parent_amount * 0.5' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 2, method: 'formula', formula: '=BALANCE_OF("Interop Savings") * -0.1' } },
          { op: 'set-split-amount', value: 0, options: { splitIndex: 3, method: 'remainder' } },
        ],
      });
      const ruled = await api.internal.send('rules-run', {
        transaction: { account: checkingID, date: today, amount: -10000, notes: 'Formula Check' },
      });
      const formulaSplits = (ruled.subtransactions ?? []).map(sub => sub.amount);

      // Equal-distance ties, one pair per tie key: both plain (latest date wins),
      // one with its own imported_id (the plain one wins, though it is older), and
      // the same date (the view's sort_order and id decide).
      const day = offset => new Date(Date.now() + offset * 86400000).toISOString().slice(0, 10);
      const tieDay = day(-10);
      await api.addTransactions(tiesID, [
        { date: day(-13), amount: -2500, notes: 'tie-a-early' },
        { date: day(-7), amount: -2500, notes: 'tie-a-late' },
        { date: day(-8), amount: -3500, imported_id: 'interop-old-1', notes: 'tie-b-imported' },
        { date: day(-12), amount: -3500, notes: 'tie-b-plain' },
        { date: tieDay, amount: -4500, notes: 'tie-c-first' },
        { date: tieDay, amount: -4500, notes: 'tie-c-second' },
      ]);
      const preview = await api.importTransactions(
        tiesID,
        [-2500, -3500, -4500].map(amount => ({ date: tieDay, amount, payee_name: 'Interop Import' })),
        { defaultCleared: true, dryRun: true },
      );
      const tieMatches = {};
      for (const entry of preview.updatedPreview ?? []) {
        tieMatches[String(entry.transaction.amount)] = entry.existing.id;
      }

      // A future split: one split with a payee, one without.
      await api.addTransactions(checkingID, [{
        date: day(5),
        amount: -5000,
        notes: 'Interop Future Split',
        subtransactions: [
          { amount: -3000, payee: storeA, notes: 'split one' },
          { amount: -2000, notes: 'split two' },
        ],
      }]);
      const parent = await api.internal.db.first(
        "SELECT id FROM transactions WHERE notes = 'Interop Future Split' AND isParent = 1 AND tombstone = 0",
      );
      await api.sync();
      writeJSON('v2611-seed.json', {
        checkingID, tiesID, storeA, tieDay, formulaSplits, tieMatches, splitParentID: parent.id,
      });
      console.log(JSON.stringify({ formulaSplits, tieMatches }));
    });
  } else if (step === 'v2611Check') {
    // Actual reads what Actualist wrote: the converted split schedule (and posts
    // it), the same-day auto-posted row, and the clock-drift budgets. Then every
    // v2611 budget is deleted.
    const { fileID } = readJSON('v2611.json');
    const seed = readJSON('v2611-seed.json');
    const swift = readJSON('v2611-actualist.json');
    const drift = readJSON('v2611-drift.json');
    const result = {};
    fs.rmSync(path.join(handoff, 'node-v2611-check'), { recursive: true, force: true });
    await withClient('v2611-check', { online: true }, async dataDir => {
      await openRemote(fileID, dataDir);
      await api.sync();
      const rule = (await api.getRules()).find(r =>
        r.actions.some(a => a.op === 'link-schedule' && a.value === swift.convertedScheduleID));
      result.splitPayeeActions = (rule?.actions ?? [])
        .filter(a => a.op === 'set' && a.field === 'payee' && (a.options?.splitIndex ?? 0) > 0)
        .map(a => [a.options.splitIndex, a.value ?? null]);
      await api.internal.send('schedule/post-transaction', { id: swift.convertedScheduleID });
      const postedParent = await api.internal.db.first(
        'SELECT id FROM transactions WHERE schedule = ? AND isParent = 1 AND tombstone = 0',
        [swift.convertedScheduleID],
      );
      const children = postedParent
        ? await api.internal.db.all(
          'SELECT amount, description FROM transactions WHERE parent_id = ? AND tombstone = 0 ORDER BY sort_order DESC',
          [postedParent.id],
        )
        : [];
      result.postedSplits = children.map(c => [c.amount, c.description ?? null]);
      const sameDay = await api.internal.db.all(
        'SELECT date, amount FROM transactions WHERE schedule = ? AND tombstone = 0',
        [swift.sameDayScheduleID],
      );
      result.sameDayRows = sameDay.map(r => [r.date, r.amount]);
    });
    for (const [label, id] of [['far', drift.farFileID], ['near', drift.nearFileID]]) {
      fs.rmSync(path.join(handoff, `node-v2611-${label}`), { recursive: true, force: true });
      result[`${label}Payees`] = await withClient(`v2611-${label}`, { online: true }, async dataDir => {
        await openRemote(id, dataDir);
        await api.sync();
        return (await api.getPayees()).map(p => p.name).filter(n => n?.startsWith('Drift '));
      });
    }
    const login = await fetch(`${url}/account/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    const token = (await login.json())?.data?.token;
    if (!token) throw new Error(`login failed (HTTP ${login.status})`);
    for (const id of [fileID, drift.farFileID, drift.nearFileID]) {
      await fetch(`${url}/sync/delete-user-file`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-actual-token': token },
        body: JSON.stringify({ fileId: id }),
      });
    }
    writeJSON('v2611-result.json', result);
    console.log(JSON.stringify(result));
    expect(result.splitPayeeActions).toEqual([[1, seed.storeA], [2, null]]);
    expect(result.postedSplits).toEqual([[-3000, seed.storeA], [-2000, null]]);
    expect(result.sameDayRows).toEqual([[Number(swift.today.replaceAll('-', '')), -1234]]);
    expect(result.farPayees).toEqual([]);
    expect(result.nearPayees).toEqual(['Drift Near']);
  } else {
    throw new Error(`unknown LAB_STEP ${step}`);
  }
});
