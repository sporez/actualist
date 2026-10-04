// Headless interop check: load a db.sqlite through upstream loot-core the way
// Actual's loadBudget does (applied-migrations check, loadClock, updateViews),
// then try schedule create, preference write and saved-filter create.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import * as api from '@harness/api';

const dbPath = process.env.CHECK_DB;
const metaPath = process.env.CHECK_META || '';
const resultPath = process.env.CHECK_RESULT;

test('interop check', async () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'newbudget-check-'));
  const meta = metaPath
    ? JSON.parse(fs.readFileSync(metaPath, 'utf8'))
    : { id: 'Interop-Check', budgetName: 'Interop Check' };
  const budgetDir = path.join(dataDir, meta.id);
  fs.mkdirSync(budgetDir);
  fs.copyFileSync(dbPath, path.join(budgetDir, 'db.sqlite'));
  fs.writeFileSync(path.join(budgetDir, 'metadata.json'), JSON.stringify(meta));

  const steps = [];
  const run = async (name, fn) => {
    try {
      const detail = await fn();
      steps.push({ step: name, pass: true, detail: detail ?? null });
    } catch (e) {
      steps.push({ step: name, pass: false, error: String(e?.message ?? e) });
    }
  };

  await api.init({ dataDir });
  await run('load-budget', async () => {
    const { error } = await api.internal.send('load-budget', { id: meta.id });
    if (error) throw new Error(`load-budget returned error: ${error}`);
  });
  const loaded = steps[0].pass;
  const guarded = async (name, fn) => {
    if (loaded) await run(name, fn);
    else steps.push({ step: name, pass: false, error: 'skipped: load-budget failed' });
  };

  await guarded('schedule-create', async () => {
    const id = await api.createSchedule({
      name: 'interop schedule',
      posts_transaction: true,
      amountOp: 'is',
      date: {
        frequency: 'monthly', interval: 1, start: '2026-01-15', patterns: [],
        skipWeekend: false, weekendSolveMode: 'after', endMode: 'never',
      },
    });
    return { id };
  });
  await guarded('preference-write', async () => {
    await api.internal.send('preferences/save', { id: 'budgetType', value: 'envelope' });
    const prefs = await api.getPreferences();
    if (prefs.budgetType !== 'envelope') throw new Error('budgetType not read back');
  });
  await guarded('saved-filter-create', async () => {
    const id = await api.internal.send('filter-create', {
      state: {
        name: 'interop filter',
        conditionsOp: 'and',
        conditions: [{ field: 'notes', op: 'contains', value: 'x', type: 'string' }],
      },
      filters: [],
    });
    return { id };
  });

  try { await api.internal.send('close-budget'); await api.shutdown(); } catch {}
  fs.rmSync(dataDir, { recursive: true, force: true });
  fs.writeFileSync(resultPath, JSON.stringify({ db: path.basename(dbPath), steps }, null, 2) + '\n');
  expect(steps.filter(s => !s.pass)).toEqual([]);
});
