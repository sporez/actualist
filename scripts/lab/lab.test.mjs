// Lab budget tool: one vitest run per command (see budgets.sh / README.md).
// Reads ACTUAL_LAB_URL / ACTUAL_LAB_PASSWORD from the environment and never
// prints the password. Only budgets whose names start with MANAGED_PREFIX are
// ever deleted.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

import * as api from '@harness/api';
import { buildBasic, buildLarge, buildPair, setAnchor } from './profiles.mjs';
import { buildStandard } from './standard.mjs';

const MANAGED_PREFIX = 'Lab · ';
const url = (process.env.ACTUAL_LAB_URL ?? '').replace(/\/+$/, '');
const password = process.env.ACTUAL_LAB_PASSWORD;
const scratchRoot = process.env.LAB_SCRATCH_DIR;
const args = JSON.parse(process.env.LAB_ARGS ?? '[]');

const isManaged = name => typeof name === 'string' && name.startsWith(MANAGED_PREFIX);
// budgets.sh shows only lines carrying this prefix (vitest output is noisy).
const out = msg => process.stdout.write(msg.split('\n').map(l => `LAB| ${l}`).join('\n') + '\n');

// ---- plain HTTP (list / delete / download) ----
let tokenCache;
async function token() {
  if (tokenCache) return tokenCache;
  const res = await fetch(`${url}/account/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password }),
  });
  const body = await res.json();
  if (!res.ok || !body?.data?.token) throw new Error(`login failed (HTTP ${res.status})`);
  return (tokenCache = body.data.token);
}
async function serverFetch(pathname, init = {}) {
  const res = await fetch(`${url}${pathname}`, {
    ...init,
    headers: { 'x-actual-token': await token(), ...(init.headers ?? {}) },
  });
  if (!res.ok) throw new Error(`${pathname} failed (HTTP ${res.status})`);
  return res;
}
async function listFiles() {
  const body = await (await serverFetch('/sync/list-user-files')).json();
  return body.data.filter(f => !f.deleted);
}
async function deleteFile(f) {
  await serverFetch('/sync/delete-user-file', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ fileId: f.fileId }),
  });
}

// ---- commands ----
function printList(files) {
  const rows = files.map(f => [f.name, f.fileId, f.groupId ?? '-', f.encryptKeyId ? 'yes' : 'no', isManaged(f.name) ? 'yes' : 'no']);
  rows.unshift(['NAME', 'FILE ID', 'GROUP ID', 'ENCRYPTED', 'MANAGED']);
  const w = rows[0].map((_, i) => Math.max(...rows.map(r => [...String(r[i])].length)));
  for (const r of rows) out(r.map((c, i) => String(c) + ' '.repeat(w[i] - [...String(c)].length)).join('  ').trimEnd());
  if (files.length === 0) out('(no budgets on the server)');
}

function opt(rest, name, fallback) {
  const i = rest.indexOf(name);
  if (i < 0) return fallback;
  if (!rest[i + 1]) throw new Error(`${name} needs a value`);
  return rest[i + 1];
}
const intOpt = (rest, name, fallback) => {
  const v = Number(opt(rest, name, fallback));
  if (!Number.isInteger(v) || v < 1) throw new Error(`${name} must be a positive integer`);
  return v;
};

function countMessages(dbPath) {
  return Number(execFileSync('sqlite3', [dbPath, 'SELECT COUNT(*) FROM messages_crdt']).toString().trim());
}

// Create an empty uploaded budget with upstream's import flow, then fill it
// through the normal client so every write is a synced CRDT message.
async function createBudget(name, build) {
  if ((await listFiles()).some(f => f.name === name)) throw new Error(`a budget named "${name}" already exists; delete it first`);
  const dataDir = fs.mkdtempSync(path.join(scratchRoot, 'client-'));
  await api.init({ dataDir, serverURL: url, password });
  let summary;
  try {
    await api.runImport(name, async () => {});
    // Leave import mode: sync() puts the client back in "enabled" mode so the
    // writes below are recorded as messages for upload.
    await api.sync();
    summary = await build();
    await api.sync();
    // Re-upload the file so a fresh download (what Actualist imports) already
    // holds the data and its message log, not just the empty first snapshot.
    const up = await api.internal.send('upload-budget');
    if (up?.error) throw new Error(`upload-budget failed: ${up.error.reason}`);
    const localID = fs.readdirSync(dataDir).find(d => fs.existsSync(path.join(dataDir, d, 'metadata.json')));
    const messages = countMessages(path.join(dataDir, localID, 'db.sqlite'));
    const file = (await listFiles()).find(f => f.name === name);
    out(`created "${name}"  fileId=${file?.fileId}  groupId=${file?.groupId}  messages_crdt=${messages}`);
    if (summary) out(summary);
  } catch (e) {
    // Do not leave a half-built budget behind (the name was verified free above).
    try {
      for (const f of (await listFiles()).filter(x => x.name === name)) await deleteFile(f);
      out(`removed incomplete "${name}"`);
    } catch {}
    throw e;
  } finally {
    try { await api.shutdown(); } catch {}
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
}

async function create(rest) {
  const profile = rest[0];
  const suffix = opt(rest, '--name', null);
  const named = (def) => (suffix ? `${MANAGED_PREFIX}${suffix}` : def);
  const anchor = opt(rest, '--anchor', null);
  if (anchor && !/^\d{4}-(0[1-9]|1[0-2])$/.test(anchor)) throw new Error('--anchor must be YYYY-MM');
  setAnchor(anchor);
  switch (profile) {
    case 'basic':
      return createBudget(named('Lab · Basic'), () => buildBasic({ tracking: false }));
    case 'tracking':
      return createBudget(named('Lab · Tracking'), () => buildBasic({ tracking: true }));
    case 'standard':
      return createBudget(named('Lab · Standard'), () => buildStandard({ months: intOpt(rest, '--months', 24) }));
    case 'empty':
      return createBudget(named('Lab · Empty'), async () => {});
    case 'pair': {
      if (suffix) throw new Error('pair always creates "Lab · Pair A" and "Lab · Pair B"; --name is not supported');
      await createBudget('Lab · Pair A', () => buildPair('A'));
      return createBudget('Lab · Pair B', () => buildPair('B'));
    }
    case 'large': {
      const months = intOpt(rest, '--months', 36);
      const perMonth = intOpt(rest, '--per-month', 150);
      return createBudget(named(`Lab · Large ${months}m x ${perMonth}`), () => buildLarge({ months, perMonth }));
    }
    default:
      throw new Error(`unknown profile "${profile}" (basic, standard, tracking, pair, large, empty)`);
  }
}

async function del(rest) {
  const files = await listFiles();
  let targets;
  if (rest[0] === '--all-managed') {
    targets = files.filter(f => isManaged(f.name));
  } else {
    const name = rest[0];
    if (!name) throw new Error('delete needs a name or --all-managed');
    if (!isManaged(name)) throw new Error(`refusing to delete "${name}": only budgets named "${MANAGED_PREFIX}..." are managed`);
    targets = files.filter(f => f.name === name);
    if (targets.length === 0) throw new Error(`no budget named "${name}"`);
  }
  for (const f of targets) {
    if (!isManaged(f.name)) throw new Error('internal safety check failed'); // never reached
    await deleteFile(f);
    out(`deleted "${f.name}" (${f.fileId})`);
  }
  if (targets.length === 0) out('no managed budgets to delete');
}

// Deletes every budget on the server, managed or not. The lab server is
// disposable; --yes is required so a stray call cannot empty it.
async function wipe(rest) {
  if (rest[0] !== '--yes') throw new Error('wipe deletes every budget on the lab server; pass --yes');
  const files = await listFiles();
  for (const f of files) {
    await deleteFile(f);
    out(`deleted "${f.name}" (${f.fileId})`);
  }
  if (files.length === 0) out('no budgets to delete');
}

async function download(rest) {
  const [name, dir] = rest;
  const f = (await listFiles()).find(x => x.name === name);
  if (!f) throw new Error(`no budget named "${name}"`);
  const res = await serverFetch('/sync/download-user-file', { headers: { 'x-actual-file-id': f.fileId } });
  const zip = path.join(dir, 'budget.zip');
  fs.writeFileSync(zip, Buffer.from(await res.arrayBuffer()));
  execFileSync('unzip', ['-o', '-q', zip, 'db.sqlite', 'metadata.json', '-d', dir]);
  fs.rmSync(zip);
  out(`downloaded "${name}" (fileId=${f.fileId}) to ${dir}: db.sqlite, metadata.json`);
}

test(`lab ${args[0]}`, async () => {
  if (!url) throw new Error('ACTUAL_LAB_URL is not set');
  fs.mkdirSync(scratchRoot, { recursive: true });
  const [cmd, ...rest] = args;
  if (cmd === 'list') printList(await listFiles());
  else if (cmd === 'create') await create(rest);
  else if (cmd === 'delete') await del(rest);
  else if (cmd === 'wipe') await wipe(rest);
  else if (cmd === 'download') await download(rest);
  else throw new Error(`unknown command ${cmd}`);
});
