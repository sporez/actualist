import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

import { test } from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/node_modules/vitest/dist/index.js';

import * as api from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/api/index.ts';

declare global {
  // These globals are part of the pinned source test harness contract.
  // eslint-disable-next-line no-var
  var IS_TESTING: boolean;
  // eslint-disable-next-line no-var
  var currentMonth: string | null;
}

type RemoteFile = {
  deleted: number | boolean;
  fileId: string;
  groupId: string;
  name: string;
  encryptKeyId: string | null;
};

type EvidenceCase = {
  name: string;
  status: 'running' | 'passed' | 'failed';
  assertions: string[];
  error?: string;
};

type OperationKind = 'unencrypted' | 'encrypted' | 'starter';

type OperationReceipt = {
  kind: OperationKind;
  name: string;
  fileID: string;
  groupID?: string;
  phase: string;
  failure?: string;
  cleanup?: 'not-found' | 'deleted' | 'ambiguous' | 'failed';
  encryption?: {
    keyID: string;
    salt: string;
    testContent: string;
    uploadMeta: Record<string, string>;
    ciphertextPath: string;
    ciphertextSHA256: string;
  };
};

type StarterProjection = {
  groups: Array<{ name: string; categories: string[] }>;
};

type OwnershipReceipt = {
  schema: number;
  upstreamRevision: string;
  runID: string;
  baselineCapturedAt: string;
  baselineFileIDs: string[];
  operations: OperationReceipt[];
  failure?: { case: string; error: string };
  ambiguities: Array<{ operation: OperationKind; reason: string }>;
};

const upstreamRevision = '59fe126f637d858c061e1eeedbef5436c8f2225a';
const evidenceRoot =
  '/Users/neil/CC/actualist-dev/.artifacts/parity-sprint-20260927/d0-source-approved';
const evidenceParent = path.resolve(
  process.env.ACTUAL_ORACLE_EVIDENCE_DIR ?? evidenceRoot,
);

const serverURL = requiredEnvironment('ACTUAL_ORACLE_SERVER_URL').replace(
  /\/+$/,
  '',
);
const serverPassword = requiredEnvironment('ACTUAL_ORACLE_SERVER_PASSWORD');
const encryptionPassword = requiredEnvironment(
  'ACTUAL_ORACLE_ENCRYPTION_PASSWORD',
);
const runID = requiredEnvironment('ACTUAL_ORACLE_RUN_ID');
const cleanupEnabled = process.env.ACTUAL_ORACLE_CLEANUP === '1';

assert.match(runID, /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/);
assert.equal(
  process.versions.node,
  '24.21.0',
  'The approved oracle is pinned to Node 24.21.0',
);
assert.ok(
  evidenceParent.startsWith(`${path.resolve(evidenceRoot)}${path.sep}`) ||
    evidenceParent === path.resolve(evidenceRoot),
  'Evidence must remain under the DEV-owned D0 artifact directory',
);

const runRoot = path.join(evidenceParent, runID);
const resultPath = path.join(runRoot, 'result.json');
const ownershipPath = path.join(runRoot, 'ownership-receipt.json');
let baselineFileIDs = new Set<string>();
let ownership: OwnershipReceipt | null = null;
let token = '';
let activeCase: EvidenceCase | null = null;

const evidence: {
  schema: number;
  upstreamRevision: string;
  node: string;
  yarn: string;
  runID: string;
  startedAt: string;
  completedAt?: string;
  outcome: 'running' | 'passed' | 'failed';
  cleanupRequested: boolean;
  cleanup?: {
    attempted: number;
    confirmedDeleted: number;
    ambiguous: number;
    error?: string;
  };
  starterProjection?: StarterProjection;
  sourceArchive?: { sha256: string; byteCount: number };
  cases: EvidenceCase[];
} = {
  schema: 2,
  upstreamRevision,
  node: process.versions.node,
  yarn: '4.17.1',
  runID,
  startedAt: new Date().toISOString(),
  outcome: 'running',
  cleanupRequested: cleanupEnabled,
  cases: [],
};

globalThis.IS_TESTING = true;
globalThis.currentMonth = null;

function requiredEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value;
}

function sha256(value: Uint8Array): string {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function redact(value: unknown): string {
  let text = value instanceof Error ? value.message : String(value);
  for (const secret of [
    serverURL,
    serverPassword,
    encryptionPassword,
    token,
  ]) {
    if (secret) text = text.split(secret).join('<redacted>');
  }
  return text
    .replace(
      /\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b/gi,
      '<id>',
    )
    .replace(/\b[0-9a-f]{32}\b/gi, '<id>')
    .slice(0, 500);
}

async function durableAtomicJSON(filePath: string, value: unknown) {
  const temporaryPath = `${filePath}.tmp-${crypto.randomUUID()}`;
  const handle = await fs.open(temporaryPath, 'wx', 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.rename(temporaryPath, filePath);
  const directory = await fs.open(path.dirname(filePath), 'r');
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}

async function writeEvidence() {
  await durableAtomicJSON(resultPath, evidence);
}

async function writeOwnership() {
  assert.ok(ownership, 'Ownership receipt is not initialized');
  await durableAtomicJSON(ownershipPath, ownership);
}

function operation(kind: OperationKind): OperationReceipt {
  assert.ok(ownership);
  const found = ownership.operations.find(item => item.kind === kind);
  assert.ok(found, `Missing ${kind} operation receipt`);
  return found;
}

async function setOperationPhase(
  item: OperationReceipt,
  phase: string,
  groupID?: string,
) {
  item.phase = phase;
  if (groupID) item.groupID = groupID;
  await writeOwnership();
}

async function rawRequest(
  route: string,
  init: RequestInit,
  options: { expectedStatus?: number; discardBody?: boolean } = {},
): Promise<{ status: number; text: string; json: unknown }> {
  const { expectedStatus = 200, discardBody = false } = options;
  const response = await fetch(`${serverURL}${route}`, init);
  const responseText = await response.text();
  if (response.status !== expectedStatus) {
    throw new Error(
      `Unexpected HTTP status ${response.status}; expected ${expectedStatus}; response=${redact(responseText)}`,
    );
  }
  if (discardBody) {
    return { status: response.status, text: '', json: null };
  }
  let json: unknown = null;
  if (responseText) {
    try {
      json = JSON.parse(responseText);
    } catch {
      json = null;
    }
  }
  return { status: response.status, text: responseText, json };
}

async function login(): Promise<string> {
  const response = await rawRequest('/account/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      loginMethod: 'password',
      password: serverPassword,
    }),
  });
  const body = response.json as {
    status?: string;
    data?: { token?: string };
  };
  assert.equal(body?.status, 'ok');
  assert.ok(body?.data?.token, 'Login returned no token');
  return body.data.token;
}

async function listRemoteFiles(): Promise<RemoteFile[]> {
  const response = await rawRequest('/sync/list-user-files', {
    method: 'GET',
    headers: { 'X-ACTUAL-TOKEN': token },
  });
  const body = response.json as { status?: string; data?: RemoteFile[] };
  assert.equal(body?.status, 'ok');
  assert.ok(Array.isArray(body?.data));
  return body.data;
}

async function uploadFile({
  item,
  bytes,
  encryptMeta,
  groupID,
  expectedStatus = 200,
  discardBody = false,
}: {
  item: OperationReceipt;
  bytes: Uint8Array;
  encryptMeta?: Record<string, string>;
  groupID?: string;
  expectedStatus?: number;
  discardBody?: boolean;
}) {
  const headers: Record<string, string> = {
    'Content-Length': String(bytes.byteLength),
    'Content-Type': 'application/encrypted-file',
    'X-ACTUAL-TOKEN': token,
    'X-ACTUAL-FILE-ID': item.fileID,
    'X-ACTUAL-NAME': encodeURIComponent(item.name),
    'X-ACTUAL-FORMAT': '2',
  };
  if (groupID) headers['X-ACTUAL-GROUP-ID'] = groupID;
  if (encryptMeta) {
    headers['X-ACTUAL-ENCRYPT-META'] = JSON.stringify(encryptMeta);
  }
  return rawRequest(
    '/sync/upload-user-file',
    { method: 'POST', headers, body: Buffer.from(bytes) },
    { expectedStatus, discardBody },
  );
}

async function createServerKey({
  item,
  keyID,
  salt,
  testContent,
}: {
  item: OperationReceipt;
  keyID: string;
  salt: string;
  testContent: string;
}) {
  const response = await rawRequest('/sync/user-create-key', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-ACTUAL-TOKEN': token,
    },
    body: JSON.stringify({
      fileId: item.fileID,
      keyId: keyID,
      keySalt: salt,
      testContent,
    }),
  });
  assert.equal((response.json as { status?: string })?.status, 'ok');
}

async function getServerKey(fileID: string) {
  const response = await rawRequest('/sync/user-get-key', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-ACTUAL-TOKEN': token,
    },
    body: JSON.stringify({ fileId: fileID }),
  });
  return (response.json as {
    status?: string;
    data?: { id?: string; salt?: string; test?: string };
  }).data;
}

async function getUserFileEncryptMeta(fileID: string) {
  const response = await rawRequest('/sync/get-user-file-info', {
    method: 'GET',
    headers: {
      'X-ACTUAL-TOKEN': token,
      'X-ACTUAL-FILE-ID': fileID,
    },
  });
  return (response.json as {
    status?: string;
    data?: { encryptMeta?: Record<string, string> | null };
  }).data?.encryptMeta;
}

async function deleteOwnedFile(fileID: string) {
  const response = await rawRequest('/sync/delete-user-file', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-ACTUAL-TOKEN': token,
    },
    body: JSON.stringify({ fileId: fileID }),
  });
  assert.equal((response.json as { status?: string })?.status, 'ok');
}

function encrypt(
  plaintext: Uint8Array,
  key: Buffer,
  keyID: string,
): { bytes: Buffer; meta: Record<string, string> } {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const bytes = Buffer.concat([
    cipher.update(Buffer.from(plaintext)),
    cipher.final(),
  ]);
  return {
    bytes,
    meta: {
      keyId: keyID,
      algorithm: 'aes-256-gcm',
      iv: iv.toString('base64'),
      authTag: cipher.getAuthTag().toString('base64'),
    },
  };
}

async function withAPIClient<T>(
  dataDirectory: string,
  server: boolean,
  body: (internal: Awaited<ReturnType<typeof api.init>>) => Promise<T>,
  reuse = false,
): Promise<T> {
  if (reuse) {
    const info = await fs.stat(dataDirectory);
    assert.ok(info.isDirectory(), 'Reusable API client path is not a directory');
  } else {
    await fs.mkdir(dataDirectory, { recursive: false, mode: 0o700 });
  }
  const internal = await api.init(
    server
      ? {
          dataDir: dataDirectory,
          serverURL,
          sessionToken: token,
          verbose: false,
        }
      : { dataDir: dataDirectory, verbose: false },
  );
  try {
    return await body(internal);
  } finally {
    await api.shutdown();
    globalThis.currentMonth = null;
  }
}

async function runCase(
  name: string,
  ownedOperation: OperationReceipt | null,
  body: (entry: EvidenceCase) => Promise<void>,
) {
  const entry: EvidenceCase = { name, status: 'running', assertions: [] };
  evidence.cases.push(entry);
  activeCase = entry;
  await writeEvidence();
  try {
    await body(entry);
    entry.status = 'passed';
    await writeEvidence();
  } catch (error) {
    entry.status = 'failed';
    entry.error = redact(error);
    if (ownedOperation) {
      ownedOperation.failure = entry.error;
      ownedOperation.phase = 'failed';
    }
    if (ownership) {
      ownership.failure = { case: name, error: entry.error };
      await writeOwnership();
    }
    await writeEvidence();
    throw error;
  } finally {
    activeCase = null;
  }
}

async function recoverGroupAndAssertSingular(item: OperationReceipt) {
  const live = (await listRemoteFiles()).filter(file => !file.deleted);
  const byID = live.filter(file => file.fileId === item.fileID);
  assert.equal(byID.length, 1, 'Expected one live row for the generated file ID');
  const recovered = byID[0];
  assert.ok(recovered.groupId, 'Recovered file has no group');
  await assertSingularRemote(item, recovered.groupId, live);
  await setOperationPhase(item, 'group-recovered-from-list', recovered.groupId);
  return recovered;
}

async function assertSingularRemote(
  item: OperationReceipt,
  groupID: string,
  files?: RemoteFile[],
) {
  const live = (files ?? (await listRemoteFiles())).filter(file => !file.deleted);
  const byID = live.filter(file => file.fileId === item.fileID);
  const byName = live.filter(file => file.name === item.name);
  const byGroup = live.filter(file => file.groupId === groupID);
  assert.equal(byID.length, 1, 'Generated file ID is not singular');
  assert.equal(byName.length, 1, 'Exact run name conflicts with another live ID');
  assert.equal(byGroup.length, 1, 'Recovered group conflicts with another live ID');
  assert.equal(byID[0].fileId, byName[0].fileId);
  assert.equal(byID[0].fileId, byGroup[0].fileId);
  assert.equal(byID[0].name, item.name);
  assert.equal(byID[0].groupId, groupID);
  return byID[0];
}

async function assertStarterShape() {
  const groups = (await api.getCategoryGroups()) as Array<{
    name: string;
    categories?: Array<{ name: string }>;
  }>;
  const categories = (await api.getCategories()) as Array<{ name: string }>;
  const projection: StarterProjection = {
    groups: groups.map(group => ({
      name: group.name,
      categories: (group.categories ?? []).map(category => category.name),
    })),
  };
  assert.deepEqual(
    groups.map(item => item.name).sort(),
    ['Income', 'Investments and Savings', 'Usual Expenses'].sort(),
  );
  assert.deepEqual(
    categories.map(item => item.name).sort(),
    [
      'Bills',
      'Bills (Flexible)',
      'Food',
      'General',
      'Income',
      'Savings',
      'Starting Balances',
    ].sort(),
  );
  assert.equal(
    projection.groups.reduce((count, group) => count + group.categories.length, 0),
    categories.length,
    'Starter categories must be attached to an actual starter group',
  );
  assert.deepEqual(
    projection.groups.flatMap(group => group.categories).sort(),
    categories.map(category => category.name).sort(),
    'Grouped starter category names must match the full category list',
  );
  if (evidence.starterProjection) {
    assert.deepEqual(projection, evidence.starterProjection);
  } else {
    evidence.starterProjection = projection;
  }
  await writeEvidence();
}

async function findSourceAccount(sourceAccountName: string) {
  const accounts = (await api.getAccounts()) as Array<{
    id: string;
    name: string;
  }>;
  const sourceAccount = accounts.find(item => item.name === sourceAccountName);
  assert.ok(sourceAccount, 'Downloaded source account is missing');
  return sourceAccount;
}

async function assertOfficialSourceDownload({
  label,
  groupID,
  password,
  sourceAccountName,
}: {
  label: string;
  groupID: string;
  password?: string;
  sourceAccountName: string;
}) {
  await withAPIClient(path.join(runRoot, label), true, async () => {
    await api.downloadBudget(groupID, password ? { password } : {});
    const sourceAccount = await findSourceAccount(sourceAccountName);
    assert.equal(await api.getAccountBalance(sourceAccount.id), 123);
  });
}

async function expectEncryptedDownloadFailure({
  label,
  groupID,
  password,
  expectedCode,
}: {
  label: string;
  groupID: string;
  password?: string;
  expectedCode: 'missing-key' | 'decrypt-failure';
}) {
  let observed = false;
  try {
    await withAPIClient(path.join(runRoot, label), true, async () => {
      await api.downloadBudget(groupID, password ? { password } : {});
    });
  } catch (error) {
    observed = true;
    assert.equal((error as { code?: string }).code, expectedCode);
  }
  assert.ok(observed, `Expected ${expectedCode} download failure`);
}

async function exchangePeerMutations({
  label,
  groupID,
  password,
  sourceAccountName,
}: {
  label: string;
  groupID: string;
  password?: string;
  sourceAccountName: string;
}) {
  const clientA = path.join(runRoot, `${label}-client-a`);
  const clientB = path.join(runRoot, `${label}-client-b`);
  const markerA = `${label}-peer-a-${runID}`;
  const markerB = `${label}-peer-b-${runID}`;

  await withAPIClient(clientA, true, async () => {
    await api.downloadBudget(groupID, password ? { password } : {});
    const sourceAccount = await findSourceAccount(sourceAccountName);
    await api.addTransactions(sourceAccount.id, [
      {
        date: '2026-09-27',
        amount: -101,
        notes: markerA,
        imported_id: markerA,
      },
    ]);
    await api.sync();
  });

  await withAPIClient(clientB, true, async () => {
    await api.downloadBudget(groupID, password ? { password } : {});
    const sourceAccount = await findSourceAccount(sourceAccountName);
    const rows = (await api.getTransactions(
      sourceAccount.id,
      '2026-09-27',
      '2026-09-27',
    )) as Array<{ notes?: string }>;
    assert.ok(rows.some(row => row.notes === markerA));
    await api.addTransactions(sourceAccount.id, [
      {
        date: '2026-09-27',
        amount: -202,
        notes: markerB,
        imported_id: markerB,
      },
    ]);
    await api.sync();
  });

  await withAPIClient(
    clientA,
    true,
    async () => {
      await api.downloadBudget(groupID, password ? { password } : {});
      const sourceAccount = await findSourceAccount(sourceAccountName);
      const rows = (await api.getTransactions(
        sourceAccount.id,
        '2026-09-27',
        '2026-09-27',
      )) as Array<{ notes?: string }>;
      assert.ok(rows.some(row => row.notes === markerB));
    },
    true,
  );
}

async function cleanupOwnedBudgets() {
  const cleanup = { attempted: 0, confirmedDeleted: 0, ambiguous: 0 };
  evidence.cleanup = cleanup;
  if (!cleanupEnabled || !token || !ownership) return;

  for (const item of ownership.operations) {
    if (baselineFileIDs.has(item.fileID)) {
      item.cleanup = 'ambiguous';
      cleanup.ambiguous += 1;
      ownership.ambiguities.push({
        operation: item.kind,
        reason: 'generated ID unexpectedly existed in the durable baseline',
      });
      await writeOwnership();
      continue;
    }

    const live = (await listRemoteFiles()).filter(file => !file.deleted);
    const byID = live.filter(file => file.fileId === item.fileID);
    if (byID.length === 0) {
      item.cleanup = 'not-found';
      await writeOwnership();
      continue;
    }

    const exact = byID.length === 1 ? byID[0] : null;
    const nameConflicts = live.filter(file => file.name === item.name);
    const groupConflicts = item.groupID
      ? live.filter(file => file.groupId === item.groupID)
      : [];
    const ambiguous =
      exact == null ||
      exact.name !== item.name ||
      nameConflicts.length !== 1 ||
      (item.groupID != null &&
        (exact.groupId !== item.groupID || groupConflicts.length !== 1));
    if (ambiguous) {
      item.cleanup = 'ambiguous';
      cleanup.ambiguous += 1;
      ownership.ambiguities.push({
        operation: item.kind,
        reason: 'known ID conflicts with exact name or recovered group; left untouched',
      });
      await writeOwnership();
      continue;
    }

    cleanup.attempted += 1;
    item.phase = 'cleanup-started';
    await writeOwnership();
    try {
      await deleteOwnedFile(item.fileID);
      // delete-user-file soft-deletes, and list-user-files omits deleted rows.
      // Absence of the exact owned ID is the confirmation that endpoint can give.
      const after = await listRemoteFiles();
      assert.ok(
        !after.some(file => file.fileId === item.fileID),
        'Owned file deletion was not confirmed',
      );
      cleanup.confirmedDeleted += 1;
      item.cleanup = 'deleted';
      item.phase = 'cleanup-confirmed';
      await writeOwnership();
    } catch (error) {
      item.cleanup = 'failed';
      item.failure = redact(error);
      await writeOwnership();
      throw error;
    }
  }

  if (cleanup.ambiguous > 0) {
    throw new Error('Cleanup ambiguity recorded; conflicting identities left untouched');
  }
}

function nextNewFileID() {
  let candidate = crypto.randomUUID();
  while (baselineFileIDs.has(candidate)) candidate = crypto.randomUUID();
  return candidate;
}

test('coordinated ZIP registration oracle', async () => {
  await fs.mkdir(evidenceParent, { recursive: true, mode: 0o700 });
  await fs.mkdir(runRoot, { recursive: false, mode: 0o700 });
  await writeEvidence();

  let primaryError: unknown = null;
  let sourceArchive = new Uint8Array();
  const sourceAccountName = `Synthetic Source ${runID}`;

  try {
    token = await login();
    baselineFileIDs = new Set((await listRemoteFiles()).map(file => file.fileId));
    ownership = {
      schema: 1,
      upstreamRevision,
      runID,
      baselineCapturedAt: new Date().toISOString(),
      baselineFileIDs: [...baselineFileIDs].sort(),
      operations: [
        {
          kind: 'unencrypted',
          name: `Actualist-D0-${runID}-unencrypted`,
          fileID: nextNewFileID(),
          phase: 'planned',
        },
        {
          kind: 'encrypted',
          name: `Actualist-D0-${runID}-encrypted`,
          fileID: nextNewFileID(),
          phase: 'planned',
        },
        {
          kind: 'starter',
          name: `Actualist-D0-${runID}-starter`,
          fileID: nextNewFileID(),
          phase: 'planned',
        },
      ],
      ambiguities: [],
    };
    assert.equal(new Set(ownership.operations.map(item => item.fileID)).size, 3);
    await writeOwnership();

    await runCase('synthetic starter archive and first write', null, async entry => {
      sourceArchive = await withAPIClient(
        path.join(runRoot, 'source-client'),
        false,
        async internal => {
          await internal.send('create-budget', {
            budgetName: `Actualist-D0-${runID}-source`,
            avoidUpload: true,
          });
          await assertStarterShape();
          assert.equal((await api.getAccounts()).length, 0);
          const accountID = await api.createAccount(
            { name: sourceAccountName, offbudget: false },
            0,
          );
          await api.addTransactions(accountID, [
            {
              date: '2026-09-27',
              amount: 123,
              notes: `source-${runID}`,
              imported_id: `source-${runID}`,
            },
          ]);
          assert.equal(await api.getAccountBalance(accountID), 123);
          return api.exportBudget();
        },
      );
      assert.ok(sourceArchive.byteLength > 0);
      const sourceArchivePath = path.join(runRoot, 'synthetic-source.zip');
      const archiveHandle = await fs.open(sourceArchivePath, 'wx', 0o600);
      try {
        await archiveHandle.writeFile(sourceArchive);
        await archiveHandle.sync();
      } finally {
        await archiveHandle.close();
      }
      evidence.sourceArchive = {
        sha256: sha256(sourceArchive),
        byteCount: sourceArchive.byteLength,
      };
      entry.assertions.push(
        'Pinned starter groups/categories, zero initial accounts, first account/transaction, and durable synthetic export succeeded.',
      );
    });

    const unencrypted = operation('unencrypted');
    await runCase(
      'unencrypted new identity and lost-response reconciliation',
      unencrypted,
      async entry => {
        await setOperationPhase(unencrypted, 'upload-started');
        await uploadFile({
          item: unencrypted,
          bytes: sourceArchive,
          discardBody: true,
        });
        await setOperationPhase(unencrypted, 'upload-response-intentionally-discarded');

        const noGroupRetry = await uploadFile({
          item: unencrypted,
          bytes: sourceArchive,
          expectedStatus: 400,
        });
        assert.equal(noGroupRetry.text, 'file-has-reset');

        const recovered = await recoverGroupAndAssertSingular(unencrypted);
        assert.equal(recovered.encryptKeyId, null);
        const recoveredRetry = await uploadFile({
          item: unencrypted,
          groupID: unencrypted.groupID,
          bytes: sourceArchive,
        });
        assert.equal(
          (recoveredRetry.json as { groupId?: string })?.groupId,
          unencrypted.groupID,
        );
        await assertSingularRemote(unencrypted, unencrypted.groupID!);
        await setOperationPhase(unencrypted, 'official-peer-exchange');
        await exchangePeerMutations({
          label: 'unencrypted',
          groupID: unencrypted.groupID!,
          sourceAccountName,
        });
        await setOperationPhase(unencrypted, 'passed');
        entry.assertions.push(
          'First response body was intentionally discarded; groupless same-ID retry was rejected; group recovery used only listing by the receipted ID; ID/name/group were independently singular; two official peers exchanged writes.',
        );
      },
    );

    const encrypted = operation('encrypted');
    await runCase('direct encrypted new identity', encrypted, async entry => {
      const keyID = crypto.randomUUID();
      const salt = crypto.randomBytes(32).toString('base64');
      const key = crypto.pbkdf2Sync(
        encryptionPassword,
        salt,
        10_000,
        32,
        'sha512',
      );
      const encryptedArchive = encrypt(sourceArchive, key, keyID);
      const encryptedTest = encrypt(
        Buffer.from('actualist-d0-key-test', 'utf8'),
        key,
        keyID,
      );
      // Actual keyMake stores encrypt()'s return value with the ciphertext
      // base64-encoded. key-test then reads test.meta, not a flattened object.
      const testContent = JSON.stringify({
        value: encryptedTest.bytes.toString('base64'),
        meta: encryptedTest.meta,
      });
      const ciphertextPath = path.join(runRoot, 'encrypted-source.bin');
      const ciphertextHandle = await fs.open(ciphertextPath, 'wx', 0o600);
      try {
        await ciphertextHandle.writeFile(encryptedArchive.bytes);
        await ciphertextHandle.sync();
      } finally {
        await ciphertextHandle.close();
      }
      encrypted.encryption = {
        keyID,
        salt,
        testContent,
        uploadMeta: encryptedArchive.meta,
        ciphertextPath,
        ciphertextSHA256: sha256(encryptedArchive.bytes),
      };
      await setOperationPhase(encrypted, 'encrypted-inputs-durable');

      await setOperationPhase(encrypted, 'upload-started');
      await uploadFile({
        item: encrypted,
        bytes: encryptedArchive.bytes,
        encryptMeta: encryptedArchive.meta,
        discardBody: true,
      });
      await setOperationPhase(encrypted, 'upload-response-intentionally-discarded');
      const noGroupRetry = await uploadFile({
        item: encrypted,
        bytes: encryptedArchive.bytes,
        encryptMeta: encryptedArchive.meta,
        expectedStatus: 400,
      });
      assert.equal(noGroupRetry.text, 'file-has-reset');

      const beforeKey = await recoverGroupAndAssertSingular(encrypted);
      assert.equal(
        beforeKey.encryptKeyId,
        null,
        'Upload metadata alone must not masquerade as a registered key',
      );
      assert.deepEqual(
        await getUserFileEncryptMeta(encrypted.fileID),
        encryptedArchive.meta,
      );

      await setOperationPhase(encrypted, 'key-registration-started');
      await createServerKey({ item: encrypted, keyID, salt, testContent });
      await setOperationPhase(encrypted, 'key-registered');
      const registeredKey = await getServerKey(encrypted.fileID);
      assert.equal(registeredKey?.id, keyID);
      assert.equal(registeredKey?.salt, salt);
      assert.equal(registeredKey?.test, testContent);
      assert.deepEqual(
        await getUserFileEncryptMeta(encrypted.fileID),
        encryptedArchive.meta,
      );
      assert.equal(
        (await assertSingularRemote(encrypted, encrypted.groupID!)).encryptKeyId,
        keyID,
      );

      await expectEncryptedDownloadFailure({
        label: 'encrypted-missing-password',
        groupID: encrypted.groupID!,
        expectedCode: 'missing-key',
      });
      await expectEncryptedDownloadFailure({
        label: 'encrypted-wrong-password',
        groupID: encrypted.groupID!,
        password: `wrong-${runID}`,
        expectedCode: 'decrypt-failure',
      });
      await setOperationPhase(encrypted, 'pre-reupload-official-unlock');
      await assertOfficialSourceDownload({
        label: 'encrypted-initial-positive',
        groupID: encrypted.groupID!,
        password: encryptionPassword,
        sourceAccountName,
      });
      await setOperationPhase(encrypted, 'pre-reupload-official-unlock-passed');

      const recoveredRetry = await uploadFile({
        item: encrypted,
        groupID: encrypted.groupID,
        bytes: encryptedArchive.bytes,
        encryptMeta: encryptedArchive.meta,
      });
      assert.equal(
        (recoveredRetry.json as { groupId?: string })?.groupId,
        encrypted.groupID,
      );
      await assertSingularRemote(encrypted, encrypted.groupID!);
      await setOperationPhase(encrypted, 'official-peer-exchange');
      await exchangePeerMutations({
        label: 'encrypted',
        groupID: encrypted.groupID!,
        password: encryptionPassword,
        sourceAccountName,
      });
      await setOperationPhase(encrypted, 'passed');
      entry.assertions.push(
        'Whole-file crypto metadata matched before/after blind key registration; fresh missing/wrong-password clients failed; correct official unlock/download succeeded before any same-ID/group re-upload; singular identity and bidirectional official peer writes then passed.',
      );
    });

    const starter = operation('starter');
    await runCase(
      'official fresh starter with preseeded cloud identity',
      starter,
      async entry => {
        const starterClient = path.join(runRoot, 'starter-client-a');
        let localID = '';
        await withAPIClient(starterClient, false, async internal => {
          await internal.send('create-budget', {
            budgetName: starter.name,
            avoidUpload: true,
          });
          await assertStarterShape();
          assert.equal((await api.getAccounts()).length, 0);
          const budgets = (await api.getBudgets()) as Array<{
            id?: string;
            name: string;
            cloudFileId?: string;
          }>;
          const local = budgets.find(item => item.id && item.name === starter.name);
          assert.ok(local?.id);
          assert.equal(local.cloudFileId, undefined);
          localID = local.id;
        });

        const metadataPath = path.join(starterClient, localID, 'metadata.json');
        const metadata = JSON.parse(await fs.readFile(metadataPath, 'utf8')) as {
          cloudFileId?: string;
          groupId?: string;
          lastUploaded?: string;
          [key: string]: unknown;
        };
        metadata.cloudFileId = starter.fileID;
        delete metadata.groupId;
        delete metadata.lastUploaded;
        await durableAtomicJSON(metadataPath, metadata);
        await setOperationPhase(starter, 'offline-starter-cloud-id-preseeded');

        // Vitest sets NODE_ENV=test even when the runner clears it. Actual
        // writes the upload groupId to metadata.json only outside test mode,
        // and getBudgets reads that file. Hold production mode for this
        // official upload, sync, and peer download only.
        const previousNodeEnv = process.env.NODE_ENV;
        process.env.NODE_ENV = 'production';
        try {
        await withAPIClient(
          starterClient,
          true,
          async internal => {
            await api.loadBudget(localID);
            await assertStarterShape();
            assert.equal((await api.getAccounts()).length, 0);
            await setOperationPhase(starter, 'official-upload-started');
            const uploadResult = (await internal.send('upload-budget', {})) as {
              error?: { reason?: string };
            };
            assert.equal(uploadResult.error, undefined);
            const budgets = (await api.getBudgets()) as Array<{
              id?: string;
              name: string;
              cloudFileId?: string;
              groupId?: string;
            }>;
            const local = budgets.find(item => item.id === localID);
            assert.equal(local?.cloudFileId, starter.fileID);
            assert.ok(local?.groupId);
            await setOperationPhase(
              starter,
              'official-upload-confirmed',
              local.groupId,
            );
            await assertSingularRemote(starter, starter.groupID!);
            const accountName = `Starter Account ${runID}`;
            await api.createAccount(
              { name: accountName, offbudget: false },
              321,
            );
            await api.sync();
          },
          true,
        );

        const accountName = `Starter Account ${runID}`;
        await withAPIClient(
          path.join(runRoot, 'starter-client-b'),
          true,
          async () => {
            await api.downloadBudget(starter.groupID!);
            await assertStarterShape();
            const accounts = (await api.getAccounts()) as Array<{
              id: string;
              name: string;
            }>;
            const account = accounts.find(item => item.name === accountName);
            assert.ok(account);
            assert.equal(await api.getAccountBalance(account.id), 321);
          },
        );
        } finally {
          if (previousNodeEnv === undefined) delete process.env.NODE_ENV;
          else process.env.NODE_ENV = previousNodeEnv;
        }
        await setOperationPhase(starter, 'passed');
        entry.assertions.push(
          'Official starter was created offline; its generated cloud ID was atomically preseeded and receipted before the official upload handler; ID/name/group were singular; a fresh official peer observed the first account/starting-balance write.',
        );
      },
    );

    evidence.outcome = 'passed';
    await writeEvidence();
  } catch (error) {
    primaryError = error;
    evidence.outcome = 'failed';
    if (activeCase) {
      activeCase.status = 'failed';
      activeCase.error = redact(error);
    }
    if (ownership && !ownership.failure) {
      ownership.failure = {
        case: activeCase?.name ?? 'pre-case',
        error: redact(error),
      };
      await writeOwnership();
    }
    await writeEvidence();
  } finally {
    globalThis.ACTUAL_ORACLE_FETCH_PHASE = 'cleanup';
    try {
      await cleanupOwnedBudgets();
    } catch (cleanupError) {
      evidence.cleanup = {
        attempted: evidence.cleanup?.attempted ?? 0,
        confirmedDeleted: evidence.cleanup?.confirmedDeleted ?? 0,
        ambiguous: evidence.cleanup?.ambiguous ?? 0,
        error: redact(cleanupError),
      };
      if (!primaryError) {
        primaryError = cleanupError;
        evidence.outcome = 'failed';
      }
    }
    evidence.completedAt = new Date().toISOString();
    await writeEvidence();
  }

  if (primaryError) {
    throw new Error(`Oracle stopped at first failed condition: ${redact(primaryError)}`);
  }
});
