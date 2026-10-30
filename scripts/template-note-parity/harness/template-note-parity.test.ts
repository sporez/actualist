// @ts-strict-ignore
// Copied into the pinned Actual checkout for one generator run and removed afterwards.
// The generator writes the case specs to ACTUALIST_TEMPLATE_NOTE_SPEC and reads the
// recorded results from ACTUALIST_TEMPLATE_NOTE_OUTPUT.
import { readFileSync, writeFileSync } from 'node:fs';
import { test } from 'vitest';

import { storeNoteTemplates } from '#server/budget/template-notes';
import * as db from '#server/db';
import * as sheet from '#server/sheet';
import { setSyncingMode } from '#server/sync';

const spec = JSON.parse(readFileSync(process.env.ACTUALIST_TEMPLATE_NOTE_SPEC, 'utf8'));
const outputPath = process.env.ACTUALIST_TEMPLATE_NOTE_OUTPUT;
const CATEGORY = 'cat-notes';

async function storedDefinition(note) {
  if (sheet.get()) {
    await sheet.waitOnSpreadsheet();
    sheet.unloadSpreadsheet();
  }
  setSyncingMode('disabled');
  await global.emptyDatabase()();
  await db.insertCategoryGroup({ id: 'group-notes', name: 'Notes' });
  await db.insertCategory({ id: CATEGORY, name: 'Notes', cat_group: 'group-notes' });
  await db.insert('notes', { id: CATEGORY, note });
  await storeNoteTemplates();
  const row = await db.first('SELECT goal_def FROM categories WHERE id = ?', [CATEGORY]);
  return row.goal_def ?? null;
}

// What the stored definition does when applied. A description is display text,
// and an error entry never applies, so its line and message do not count.
function behavior(goalDef) {
  const entries = JSON.parse(goalDef ?? '[]');
  return JSON.stringify(entries.map(entry => {
    if (entry.type === 'error') return { type: 'error' };
    const { description, ...rest } = entry;
    return Object.fromEntries(Object.entries(rest).sort(([a], [b]) => a.localeCompare(b)));
  }));
}

test('records what Actual stores for each note', async () => {
  const cases = [];
  for (const testCase of spec.cases) {
    const goalDef = await storedDefinition(testCase.storedNote ?? testCase.note);
    const regenerated = testCase.storedNote === undefined ? goalDef : await storedDefinition(testCase.note);
    cases.push({
      id: testCase.id,
      group: testCase.group,
      note: testCase.note,
      goalDef,
      regeneratedGoalDef: regenerated,
      stale: behavior(goalDef) !== behavior(regenerated),
    });
  }
  writeFileSync(outputPath, JSON.stringify({ cases }));
}, 300_000);
