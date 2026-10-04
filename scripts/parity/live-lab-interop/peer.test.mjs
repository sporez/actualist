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
  } else {
    throw new Error(`unknown LAB_STEP ${step}`);
  }
});
