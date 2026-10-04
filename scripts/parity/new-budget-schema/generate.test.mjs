// Creates a fresh budget exactly as upstream `createBudget` does: copy
// default-db.sqlite, write default metadata.json, then _loadBudget ->
// updateVersion -> migrate() (SQL and JS migrations). No server, no network.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import * as api from '@harness/api';

const outDir = process.env.NEWBUDGET_OUT_DIR;

test('create a fresh budget through upstream createBudget', async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'newbudget-gen-'));
  await api.init({ dataDir });
  const result = await api.internal.send('create-budget', {
    budgetName: 'Fresh Budget',
    avoidUpload: true,
  });
  expect(result).toEqual({});
  await api.internal.send('close-budget');
  await api.shutdown();

  const budgetDirs = fs.readdirSync(dataDir).filter(n =>
    fs.existsSync(path.join(dataDir, n, 'db.sqlite')),
  );
  expect(budgetDirs).toHaveLength(1);
  const src = path.join(dataDir, budgetDirs[0]);
  fs.mkdirSync(path.join(outDir, 'fresh-budget'), { recursive: true });
  for (const f of ['db.sqlite', 'metadata.json']) {
    fs.copyFileSync(path.join(src, f), path.join(outDir, 'fresh-budget', f));
  }
  fs.rmSync(dataDir, { recursive: true, force: true });
});
