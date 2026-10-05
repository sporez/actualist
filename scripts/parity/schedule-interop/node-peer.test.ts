import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import {
  chmod,
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  stat,
  writeFile,
} from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as api from './actual-api-overlay';
import {
  recordingProxyPort,
  startRecordingProxy,
  type ProtocolCapture,
} from './node-peer-proxy';
import {
  afterEach,
  test,
} from '@actual-oracle/node_modules/vitest/dist/index.js';

const actualRevision = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const freezeID = 'schedule-interop-manual-v1';
const swiftControlPort = 5008;

type D0Handoff = {
  schemaVersion: 1;
  runID: string;
  actualRevision: string;
  serverOrigin: string;
  fileID: string;
  ownershipNonce: string;
  budgetName: string;
  baselineFileIDs: string[];
  baselineSHA256: string;
};
type Credentials = { schemaVersion: 1; runID: string; sessionToken: string };
type OwnerMarker = { schemaVersion: 1; runID: string; ownershipNonce: string };
type SwiftResult = {
  schemaVersion: 1;
  runID: string;
  fixtureArchiveSHA256: string;
  scheduleID: string;
  transactionID: string;
  occurrenceDayID: string;
  postedDayID: string;
  appliedMessageCount: number;
};
type RemoteFile = {
  fileId: string;
  groupId?: string;
  name: string;
  deleted?: boolean;
};
type TransactionProjection = {
  id: string;
  schedule?: string;
  amount?: number;
  date?: string;
};
let apiInitialized = false;
afterEach(async () => {
  if (apiInitialized) await shutdownAPI();
});

test('real Swift manual post imports through the production Node peer', async () => {
  const runID = safeIdentifier(requiredEnvironment('SCHEDULE_INTEROP_RUN_ID'));
  const actualistRoot = path.resolve(requiredEnvironment('SCHEDULE_INTEROP_ACTUALIST_ROOT'));
  assert.equal(
    actualistRoot,
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..'),
  );
  const runRoot = path.resolve(requiredEnvironment('SCHEDULE_INTEROP_RUN_ROOT'));
  const cacheRoot = path.resolve(requiredEnvironment('SCHEDULE_INTEROP_CACHE_ROOT'));
  const admittedParent = path.join(
    actualistRoot,
    '.artifacts/parity-sprint-20260927/schedule-interop',
  );
  assert.ok(runRoot.startsWith(`${admittedParent}${path.sep}`));
  assert.ok(cacheRoot.startsWith(`${admittedParent}${path.sep}`));
  assert.notEqual(runRoot, cacheRoot);
  assert.equal(path.basename(runRoot), runID);

  const handoffPath = path.resolve(requiredEnvironment('SCHEDULE_INTEROP_D0_HANDOFF_FILE'));
  const credentialPath = path.resolve(requiredEnvironment('SCHEDULE_INTEROP_CREDENTIAL_FILE'));
  await requireMode600(handoffPath);
  await requireMode600(credentialPath);
  const handoff = JSON.parse(await readFile(handoffPath, 'utf8')) as D0Handoff;
  const credentials = JSON.parse(await readFile(credentialPath, 'utf8')) as Credentials;
  validateD0Handoff(handoff, credentials, runID);
  await validateOwnedRoot(runRoot, handoff, true);
  await validateOwnedRoot(cacheRoot, handoff, false);

  const evidenceDirectory = path.join(runRoot, 'evidence');
  const seedDirectory = path.join(runRoot, 'node-seed');
  const peerDirectory = path.join(runRoot, 'node-peer');
  await mkdir(evidenceDirectory, { mode: 0o700 });
  await mkdir(seedDirectory, { mode: 0o700 });
  await mkdir(peerDirectory, { mode: 0o700 });

  let syncPhase = 'seed-admission';
  const protocolCaptures: ProtocolCapture[] = [];
  const proxy = await startRecordingProxy(
    loopbackOrigin(handoff.serverOrigin),
    evidenceDirectory,
    protocolCaptures,
    () => syncPhase,
  );
  assert.equal(proxy.origin, `http://127.0.0.1:${recordingProxyPort}`);
  let controlServer: ReturnType<typeof createServer> | null = null;

  try {
    const occurrenceDayID = localDayID();
    const fixture = await seedOfficialFixture({
      handoff,
      credentials,
      serverOrigin: proxy.origin,
      seedDirectory,
      peerDirectory,
      occurrenceDayID,
      setPhase: value => {
        syncPhase = value;
      },
    });
    const beforeProjection = await scheduleTransactions(fixture.scheduleID);
    const nodeMessageCountBefore = await crdtMessageCount();
    assert.deepEqual(beforeProjection, []);

    let swiftResult: SwiftResult | null = null;
    controlServer = createServer((request, response) => {
      void route(request, response).catch(error => {
        writeJSON(response, 500, { error: safeError(error) });
      });
    });

    async function route(request: IncomingMessage, response: ServerResponse) {
      assert.equal(request.headers['x-schedule-interop-run-id'], runID);
      if (request.method === 'GET' && request.url === '/v1/handshake') {
        writeJSON(response, 200, {
          schemaVersion: 1,
          runID,
          actualRevision,
          freezeID,
          scheduleID: fixture.scheduleID,
          occurrenceDayID,
          automaticActualistRole: 'BLOCKED',
        });
      } else if (request.method === 'GET' && request.url === '/v1/fixture-handoff') {
        writeJSON(response, 200, {
          schemaVersion: 1,
          runID,
          actualRevision,
          freezeID,
          serverOrigin: proxy.origin,
          fileID: handoff.fileID,
          groupID: fixture.groupID,
          budgetName: handoff.budgetName,
          fixtureArchiveSHA256: fixture.archiveSHA256,
          syncToken: credentials.sessionToken,
        });
      } else if (request.method === 'GET' && request.url === '/v1/fixture-archive') {
        response.writeHead(200, {
          'Content-Type': 'application/zip',
          'Content-Length': String(fixture.archive.length),
          'Cache-Control': 'no-store',
        });
        response.end(fixture.archive);
      } else if (request.method === 'POST' && request.url === '/v1/swift-result') {
        const decoded = JSON.parse(
          (await readBoundedBody(request, 1_048_576)).toString('utf8'),
        ) as SwiftResult;
        validateSwiftResult(decoded, runID, fixture.archiveSHA256, fixture.scheduleID);
        swiftResult = decoded;
        writeJSON(response, 200, { accepted: true });
      } else {
        writeJSON(response, 404, { error: 'not-found' });
      }
    }

    await listenLoopback(controlServer, swiftControlPort);
    const address = controlServer.address();
    assert.ok(address && typeof address !== 'string');
    assert.equal(address.address, '127.0.0.1');
    assert.equal(address.port, swiftControlPort);
    syncPhase = 'swift-sync-first-post-flush';
    const log = await open(path.join(evidenceDirectory, 'swift-test.log'), 'wx', 0o600);
    let childStatus: number;
    try {
      childStatus = await runSwiftPeer(actualistRoot, log.fd, {
        // One focused test. A parallel clone is unnecessary and previously
        // started the suite without the runner environment.
        ACTUALIST_TEST_PARALLEL: '0',
        TEST_RUNNER_SCHEDULE_INTEROP_CONTROL_ORIGIN: `http://127.0.0.1:${swiftControlPort}`,
        TEST_RUNNER_SCHEDULE_INTEROP_RUN_ID: runID,
        TEST_RUNNER_SCHEDULE_INTEROP_ACTUAL_REVISION: actualRevision,
        TEST_RUNNER_SCHEDULE_INTEROP_FREEZE_ID: freezeID,
      });
    } finally {
      await log.close();
    }
    assert.equal(childStatus, 0);
    assert.ok(swiftResult, 'Swift test did not submit a result');

    syncPhase = 'node-import-after-swift';
    await api.sync();
    const afterProjection = await scheduleTransactions(fixture.scheduleID);
    const nodeMessageCountAfter = await crdtMessageCount();
    assert.equal(afterProjection.length, 1);
    assert.equal(afterProjection[0].id, swiftResult.transactionID);
    assert.equal(afterProjection[0].schedule, fixture.scheduleID);
    assert.equal(afterProjection[0].amount, -10_000);
    assert.equal(afterProjection[0].date, swiftResult.postedDayID);
    assert.equal(swiftResult.occurrenceDayID, occurrenceDayID);
    assert.equal(swiftResult.postedDayID, occurrenceDayID);
    assert.ok(nodeMessageCountAfter > nodeMessageCountBefore);

    await writePrivateFile(
      path.join(evidenceDirectory, 'result.json'),
      Buffer.from(
        `${JSON.stringify(
          {
            schemaVersion: 1,
            status: 'passed-manual-swift-to-node-import',
            actualRevision,
            freezeID,
            automaticActualistRole: 'BLOCKED',
            distributedUniquenessGuarantee: false,
            fixtureArchiveSHA256: fixture.archiveSHA256,
            scheduleIDHash: sha256(Buffer.from(fixture.scheduleID)),
            transactionIDHash: sha256(Buffer.from(swiftResult.transactionID)),
            occurrenceDayID,
            postedDayID: swiftResult.postedDayID,
            importedDateMatchedPostedDayID: true,
            occurrenceMatchedScheduledPost: true,
            swiftAppliedMessageCount: swiftResult.appliedMessageCount,
            nodeAppliedMessageCount: nodeMessageCountAfter - nodeMessageCountBefore,
            beforeProjection: redactProjection(beforeProjection),
            afterProjection: redactProjection(afterProjection),
            protocolCaptures,
          },
          null,
          2,
        )}\n`,
      ),
    );
  } finally {
    if (controlServer) await closeServer(controlServer);
    await proxy.close();
  }
});

async function seedOfficialFixture(input: {
  handoff: D0Handoff;
  credentials: Credentials;
  serverOrigin: string;
  seedDirectory: string;
  peerDirectory: string;
  occurrenceDayID: string;
  setPhase: (value: string) => void;
}) {
  const { handoff, credentials } = input;
  await initAPI(input.seedDirectory, input.serverOrigin, credentials.sessionToken);
  await assertRemoteBaseline(handoff);
  const internal = assertInternal();
  await internal.send('create-budget', {
    budgetName: handoff.budgetName,
    avoidUpload: true,
  });
  const local = (await api.getBudgets()).find(
    item => item.id && item.name === handoff.budgetName && !item.cloudFileId,
  );
  assert.ok(local?.id);
  const accountID = await api.createAccount(
    { name: `Synthetic account ${handoff.ownershipNonce}`, offbudget: false },
    0,
  );
  // Actual's client posts a due schedule on successful sync when this flag is
  // true. Leave it off so the Node seed sync does not post before Swift does.
  const scheduleID = await api.createSchedule({
    name: `Synthetic schedule ${handoff.ownershipNonce}`,
    posts_transaction: false,
    amount: -10_000,
    amountOp: 'is',
    account: accountID,
    date: input.occurrenceDayID,
  });
  const archive = Buffer.from(await api.exportBudget());
  await shutdownAPI();

  const metadataPath = path.join(input.seedDirectory, local.id, 'metadata.json');
  const metadata = JSON.parse(await readFile(metadataPath, 'utf8')) as {
    cloudFileId?: string;
    groupId?: string;
    lastUploaded?: string;
    budgetName?: string;
  };
  metadata.cloudFileId = handoff.fileID;
  metadata.budgetName = handoff.budgetName;
  delete metadata.groupId;
  delete metadata.lastUploaded;
  await replacePrivateFile(metadataPath, Buffer.from(`${JSON.stringify(metadata)}\n`));

  await initAPI(input.seedDirectory, input.serverOrigin, credentials.sessionToken);
  await api.loadBudget(local.id);
  await assertRemoteBaseline(handoff); // Immediate pre-write ownership check.
  input.setPhase('seed-first-upload');
  const upload = (await assertInternal().send('upload-budget', {})) as {
    error?: { reason?: string };
  };
  assert.equal(upload.error, undefined);
  const uploaded = await assertExactRemoteIdentity(handoff);
  assert.ok(uploaded.groupId);
  input.setPhase('seed-sync');
  await api.sync();
  await shutdownAPI();

  await initAPI(input.peerDirectory, input.serverOrigin, credentials.sessionToken);
  await api.downloadBudget(uploaded.groupId);
  input.setPhase('node-baseline-sync');
  await api.sync();
  return {
    archive,
    archiveSHA256: sha256(archive),
    groupID: uploaded.groupId,
    scheduleID,
  };
}

async function remoteFiles(): Promise<RemoteFile[]> {
  const files = (await assertInternal().send('get-remote-files')) as RemoteFile[];
  return files.filter(file => !file.deleted);
}

async function assertRemoteBaseline(handoff: D0Handoff) {
  const ids = (await remoteFiles()).map(file => file.fileId).sort();
  assert.deepEqual(ids, [...handoff.baselineFileIDs].sort());
  assert.equal(sha256(Buffer.from(JSON.stringify(ids))), handoff.baselineSHA256);
  assert.ok(!ids.includes(handoff.fileID));
}

async function assertExactRemoteIdentity(handoff: D0Handoff) {
  const files = await remoteFiles();
  const byID = files.filter(file => file.fileId === handoff.fileID);
  const byName = files.filter(file => file.name === handoff.budgetName);
  assert.equal(byID.length, 1);
  assert.equal(byName.length, 1);
  assert.equal(byID[0], byName[0]);
  assert.ok(byID[0].groupId);
  return byID[0];
}

async function scheduleTransactions(scheduleID: string): Promise<TransactionProjection[]> {
  const result = await api.aqlQuery(
    api.q('transactions').filter({ schedule: scheduleID }).select([
      'id',
      'schedule',
      'amount',
      'date',
    ]),
  );
  return result.data as TransactionProjection[];
}

async function crdtMessageCount() {
  const rows = await assertInternal().db.all<{ count: number }>(
    'SELECT COUNT(*) AS count FROM messages_crdt',
  );
  assert.equal(rows.length, 1);
  return rows[0].count;
}

function redactProjection(rows: TransactionProjection[]) {
  return rows.map(row => ({
    idHash: sha256(Buffer.from(row.id)),
    scheduleIDHash: sha256(Buffer.from(row.schedule ?? '')),
    amount: row.amount,
    date: row.date,
  }));
}

async function initAPI(dataDir: string, serverURL: string, sessionToken: string) {
  await api.init({ dataDir, serverURL, sessionToken });
  apiInitialized = true;
}

async function shutdownAPI() {
  await api.shutdown();
  apiInitialized = false;
}

function assertInternal() {
  assert.ok(api.internal);
  return api.internal;
}

function validateD0Handoff(handoff: D0Handoff, credentials: Credentials, runID: string) {
  assert.equal(handoff.schemaVersion, 1);
  assert.equal(handoff.runID, runID);
  assert.equal(handoff.actualRevision, actualRevision);
  safeIdentifier(handoff.fileID);
  safeIdentifier(handoff.ownershipNonce);
  assert.equal(handoff.budgetName, `Schedule Interop ${handoff.ownershipNonce}`);
  assert.equal(new Set(handoff.baselineFileIDs).size, handoff.baselineFileIDs.length);
  assert.match(handoff.baselineSHA256, /^[0-9a-f]{64}$/);
  assert.equal(credentials.schemaVersion, 1);
  assert.equal(credentials.runID, runID);
  assert.ok(credentials.sessionToken);
  loopbackOrigin(handoff.serverOrigin);
}

function validateSwiftResult(
  result: SwiftResult,
  runID: string,
  archiveHash: string,
  scheduleID: string,
) {
  assert.equal(result.schemaVersion, 1);
  assert.equal(result.runID, runID);
  assert.equal(result.fixtureArchiveSHA256, archiveHash);
  assert.equal(result.scheduleID, scheduleID);
  safeIdentifier(result.transactionID);
  assert.match(result.occurrenceDayID, /^\d{4}-\d{2}-\d{2}$/);
  assert.match(result.postedDayID, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(result.appliedMessageCount > 0);
}

async function validateOwnedRoot(root: string, handoff: D0Handoff, strictContents: boolean) {
  const info = await stat(root);
  assert.ok(info.isDirectory());
  assert.equal(info.mode & 0o777, 0o700);
  const markerPath = path.join(root, '.owner.json');
  await requireMode600(markerPath);
  const marker = JSON.parse(await readFile(markerPath, 'utf8')) as OwnerMarker;
  assert.deepEqual(marker, {
    schemaVersion: 1,
    runID: handoff.runID,
    ownershipNonce: handoff.ownershipNonce,
  });
  if (strictContents) assert.deepEqual(await readdir(root), ['.owner.json']);
}

async function requireMode600(file: string) {
  const info = await stat(file);
  assert.ok(info.isFile());
  assert.equal(info.mode & 0o777, 0o600);
}

function requiredEnvironment(name: string) {
  const value = process.env[name];
  assert.ok(value, `missing ${name}`);
  return value;
}

function safeIdentifier(value: string) {
  assert.match(value, /^[A-Za-z0-9_-]{1,128}$/);
  return value;
}

// Optional disposable lab server origin, supplied by the operator. Unset means
// only loopback origins are admitted.
const admittedRemoteOrigin = process.env.SCHEDULE_INTEROP_ADMITTED_REMOTE_ORIGIN ?? '';

function loopbackOrigin(value: string) {
  if (admittedRemoteOrigin && value === admittedRemoteOrigin) return value;
  const parsed = new URL(value);
  assert.equal(parsed.protocol, 'http:');
  assert.equal(parsed.hostname, '127.0.0.1');
  // This peer does not spawn the Actual server. A local lease would spawn
  // node packages/sync-server/build/app.js. 5007 and 5008 are this process.
  assert.ok(parsed.port, 'server origin is missing a port');
  assert.ok(
    !['5006', '5007', '5008'].includes(parsed.port),
    `server origin port ${parsed.port} is reserved for D0 or this peer`,
  );
  assert.equal(parsed.username + parsed.password + parsed.search + parsed.hash, '');
  assert.equal(parsed.pathname, '/');
  return parsed.origin;
}

function localDayID() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, '0');
  const day = String(now.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

async function writePrivateFile(file: string, data: Buffer) {
  await writeFile(file, data, { mode: 0o600, flag: 'wx' });
  await chmod(file, 0o600);
}

async function replacePrivateFile(file: string, data: Buffer) {
  const temporary = `${file}.schedule-interop-${process.pid}`;
  await writePrivateFile(temporary, data);
  await rename(temporary, file);
  await chmod(file, 0o600);
}

function sha256(data: Buffer) {
  return createHash('sha256').update(data).digest('hex');
}

async function readBoundedBody(request: IncomingMessage, maximumBytes: number) {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buffer.length;
    assert.ok(size <= maximumBytes);
    chunks.push(buffer);
  }
  return Buffer.concat(chunks);
}

function writeJSON(response: ServerResponse, status: number, value: unknown) {
  if (response.headersSent) return;
  const body = Buffer.from(JSON.stringify(value));
  response.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': String(body.length),
    'Cache-Control': 'no-store',
  });
  response.end(body);
}

function safeError(error: unknown) {
  return error instanceof assert.AssertionError ? error.message : 'bridge-control-failure';
}

async function listenLoopback(
  server: ReturnType<typeof createServer>,
  port: number,
) {
  assert.equal(port, swiftControlPort);
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(swiftControlPort, '127.0.0.1', resolve);
  });
}

async function closeServer(server: ReturnType<typeof createServer>) {
  await new Promise<void>(resolve => server.close(() => resolve()));
}

async function runSwiftPeer(
  actualistRoot: string,
  logFD: number,
  environment: Record<string, string>,
) {
  const child = spawn(
    path.join(actualistRoot, 'scripts/test.sh'),
    ['unit', 'LocalFirstActualStoreScheduleInteropTests/realSyncFirstSwiftPostExportsActualMessages()'],
    {
      cwd: actualistRoot,
      env: { ...process.env, ...environment },
      stdio: ['ignore', logFD, logFD],
    },
  );
  return await new Promise<number>((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', (code, signal) => {
      if (signal) reject(new Error(`Swift wrapper terminated by ${signal}`));
      else resolve(code ?? 1);
    });
  });
}
