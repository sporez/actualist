#!/usr/bin/env node
// Records what Actual stores for each note form. The staleness guard in
// BudgetTemplateNoteParser.swift must agree: a note matches the definition
// Actual stores for it, and a note changed since then does not.

import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  assertPinnedOracle,
  hasOracleRoot,
  oraclePin,
  ORACLE_ROOT_VARIABLE,
  pinnedFixtureDirectory,
  pinnedOracleRoot,
} from '../parity/lib/oracle-pin.mjs';
import { compareWithCommitted } from '../parity/lib/fixture-diff.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const harnessPath = 'scripts/template-note-parity/harness/template-note-parity.test.ts';
const helperPaths = ['scripts/parity/lib/oracle-pin.mjs', 'scripts/parity/lib/fixture-diff.mjs'];
const upstreamPaths = [
  'packages/loot-core/src/server/budget/goal-template.pegjs',
  'packages/loot-core/src/server/budget/template-notes.ts',
  'packages/loot-core/src/server/budget/goal-template.ts',
];
const contractName = 'template-note-contract.json';
const manifestName = 'template-note-manifest.json';

// A note on its own: the guard must accept the definition Actual stores for it.
const FORMS = {
  simple: [
    '#template 500', '#template 500.5', '#template 8.40', '#template 5.', '#template -50',
    '#template $500', '#template € 12.34', '#template-2 500', '#template-0 500', '#template500',
    '   #template 500', 'Text before #template 500',
    '#template 500 up to 1000', '#template 500 UP TO 1000', '#template 500 up to 1000 hold',
    '#template 50 up to 20 per day', '#template 50 up to 20 per day hold',
    '#template 50 up to 100 per week starting 2026-10-05',
    '#template 50 up to 100 per week starting 2026-10-05 hold',
    '#template up to 1000', '#template up to 20 per day hold', '#template 0 up to 300',
  ],
  by: [
    '#template 600 by 2027-01', '#template $600 by 2027-01', '#template-2 600 by 2027-01',
    '#template 600 BY 2027-01', '#template 600 by 2027-01 repeat every year',
    '#template 600 by 2027-01 repeat every 2 years', '#template 600 by 2027-01 repeat every month',
    '#template 600 by 2027-01 repeat every 3 months',
  ],
  spend: [
    '#template 500 by 2027-06 spend from 2026-07',
    '#template 500 by 2027-06 spend from 2026-07 repeat every month',
    '#template 500 by 2027-06 spend from 2026-07 repeat every year',
    '#template 500 by 2027-06 spend from 2026-07 repeat every 2 years',
    '#template-1 500 by 2027-06 spend from 2026-07',
  ],
  periodic: [
    '#template 100 repeat every week starting 2026-10-05',
    '#template 100 repeat every 2 weeks starting 2026-10-05',
    '#template 100 repeat every day starting 2026-10-05',
    '#template 100 repeat every 3 days starting 2026-10-05',
    '#template 100 repeat every 3 months starting 2026-10-05',
    '#template 100 repeat every year starting 2026-10-05',
    '#template 100 repeat every 2 years starting 2026-10-05',
    '#template 100 repeat every week starting 2026-10-05 up to 500',
    '#template-1 100 repeat every week starting 2026-10-05',
  ],
  percentage: [
    '#template 10% of all income', '#template 10 % of income', '#template 12.5% of available funds',
    '#template 10% of previous all income', '#template 10% of Salary',
    '#template 10% of Side Hustle Pay', '#template-1 5% of Salary',
  ],
  schedule: [
    '#template schedule Rent', '#template schedule Car Insurance', '#template schedule full Rent',
    '#template schedule full Car Insurance', '#template schedule Rent [increase 10%]',
    '#template schedule Rent [decrease 5%]', '#template schedule Rent [increase 25]',
    '#template schedule Car Insurance [increase 2.5%]', '#template-1 schedule Rent',
    '#template schedule Fullerton Water', '#template schedule 50% Rent',
    '#template schedule Rent [increase 2000%]', '#template schedule Rent [decrease 100%]',
  ],
  remainder: [
    '#template remainder', '#template remainder 3', '#template remainder up to 500',
    '#template remainder 2 up to 500', '#template-3 remainder',
  ],
  average: [
    '#template average 3 months', '#template average 6', '#template average 3 months [increase 10%]',
    '#template average 3 months [decrease 20]', '#template average 3 [increase 2000%]',
  ],
  copy: [
    '#template copy from 1 months ago', '#template copy from 3 months ago',
    '#template copy from 3 months ago up to 100',
  ],
  goal: ['#goal 500', '#goal 1000.50', '#goal $500'],
  multiple: [
    '#template 100\n#template 200', 'Keep this.\n#template 100', '#template 100\n#goal 500',
    '#template 100\n\nText\n#template-2 200', '#template 100\r\n#template 200',
  ],
  malformed: [
    '#template', '#template bad', '#templates 100', '#template 500 monthly', '#template by 2026-12 200',
    '#template spend 300 from 2026-07 to 2026-09', '#template 500 by 2026-1', '#template 1,000',
    '#goal', '#goals 5', '#goal 500 by 2026-12', '#template 1.234', '#template 100 repeat every week',
    '#template 100 repeat every month starting 2026-01-01', '#template-x 100', '#template copy',
    '#template 500 up to', '#template 100 by 2027-01 repeat every',
  ],
  'no-directive': ['Plain note', '# not a directive', '#cleanup source'],
};

// [stored note, current note]: the definition was stored from the first and the
// note now reads the second. Actual decides below whether that changes anything.
const CHANGES = {
  amount: [
    ['#template 8.40', '#template 8.41'], ['#template 500', '#template 501'],
    ['#template 600 by 2027-01', '#template 601 by 2027-01'],
  ],
  priority: [
    ['#template 500', '#template-2 500'], ['#template-2 500', '#template-3 500'],
    ['#template 600 by 2027-01', '#template-2 600 by 2027-01'],
    ['#template schedule Rent', '#template-2 schedule Rent'],
  ],
  target: [
    ['#template 600 by 2027-01', '#template 600 by 2027-02'],
    ['#template 600 by 2027-01', '#template 600 by 2027-01 repeat every year'],
    ['#template 600 by 2027-01 repeat every 2 years', '#template 600 by 2027-01 repeat every 3 years'],
    ['#template 600 by 2027-01 repeat every 2 months', '#template 600 by 2027-01 repeat every 3 months'],
    ['#template 600 by 2027-01 repeat every month', '#template 600 by 2027-01 repeat every year'],
  ],
  spend: [
    ['#template 500 by 2027-06 spend from 2026-07', '#template 500 by 2027-06 spend from 2026-08'],
    ['#template 500 by 2027-06 spend from 2026-07', '#template 500 by 2027-06'],
    ['#template 500 by 2027-06 spend from 2026-07', '#template 500 by 2027-06 spend from 2026-07 repeat every year'],
  ],
  periodic: [
    ['#template 100 repeat every week starting 2026-10-05', '#template 100 repeat every week starting 2026-10-12'],
    ['#template 100 repeat every week starting 2026-10-05', '#template 100 repeat every 2 weeks starting 2026-10-05'],
    ['#template 100 repeat every 3 days starting 2026-10-05', '#template 100 repeat every 3 months starting 2026-10-05'],
  ],
  percentage: [
    ['#template 10% of all income', '#template 11% of all income'],
    ['#template 10% of all income', '#template 10% of previous all income'],
    ['#template 10% of Salary', '#template 10% of Bonus'],
    ['#template 10% of income', '#template 10% of all income'],
  ],
  schedule: [
    ['#template schedule Rent', '#template schedule Mortgage'],
    ['#template schedule Car Insurance', '#template schedule Car Payment'],
    ['#template schedule Rent', '#template schedule full Rent'],
    ['#template schedule Rent [increase 10%]', '#template schedule Rent [increase 20%]'],
    ['#template schedule Rent [increase 10%]', '#template schedule Rent [decrease 10%]'],
    ['#template schedule Rent [increase 10%]', '#template schedule Rent [increase 10]'],
    ['#template schedule Rent [increase 10%]', '#template schedule Rent'],
  ],
  limit: [
    ['#template 500', '#template 500 up to 1000'], ['#template 500 up to 1000', '#template 500'],
    ['#template 500 up to 1000', '#template 500 up to 2000'],
    ['#template 500 up to 1000', '#template 500 up to 1000 hold'],
    ['#template 50 up to 20 per day', '#template 50 up to 20'],
    ['#template 50 up to 100 per week starting 2026-10-05', '#template 50 up to 100 per week starting 2026-10-12'],
    ['#template remainder', '#template remainder up to 500'],
    ['#template 100 repeat every week starting 2026-10-05', '#template 100 repeat every week starting 2026-10-05 up to 500'],
  ],
  other: [
    ['#template remainder', '#template remainder 2'], ['#template average 3 months', '#template average 6 months'],
    ['#template average 3 months', '#template average 3 months [increase 10%]'],
    ['#template copy from 1 months ago', '#template copy from 2 months ago'],
    ['#goal 500', '#goal 600'], ['#template 500', '#goal 500'],
    ['#template 500', '#template remainder'], ['#template 500', '#template 500 by 2027-01'],
  ],
  lines: [
    ['#template 100', '#template 100\n#template 200'], ['#template 100\n#template 200', '#template 100'],
    ['#template 100\n#template 200', '#template 200\n#template 100'],
    ['#template 100', 'Plain note'], ['#template 100', '#template bad'], ['#template bad', '#template 100'],
  ],
  // Not stale: Actual stores the same behavior for both.
  equivalent: [
    ['Old text\n#template 100', 'New text\n#template 100'], ['#template bad', '#template worse'],
    ['#template 100', '   #template 100'], ['#template $500', '#template 500'],
    ['#template 600 by 2027-01', '#template 600 BY 2027-01'],
  ],
};

const slug = text => text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48);
const cases = [];
const seen = new Map();
function addCase(prefix, entry) {
  const base = `${prefix}-${slug(entry.note) || 'empty'}`;
  const count = (seen.get(base) ?? 0) + 1;
  seen.set(base, count);
  cases.push({ id: count === 1 ? base : `${base}-${count}`, group: prefix, ...entry });
}
for (const [group, notes] of Object.entries(FORMS)) {
  for (const note of notes) addCase(`form-${group}`, { note });
}
for (const [group, pairs] of Object.entries(CHANGES)) {
  for (const [storedNote, note] of pairs) addCase(`change-${group}`, { storedNote, note });
}

const sha256 = data => createHash('sha256').update(data).digest('hex');
const checking = process.argv.includes('--check');
if (!hasOracleRoot()) {
  console.error(`Oracle required: set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag}.`);
  process.exit(2);
}
const checkout = pinnedOracleRoot();
const defaultOutput = pinnedFixtureDirectory('TemplateNotes');
const outputRoot = checking ? mkdtempSync(join(tmpdir(), 'actualist-template-note-check-')) : defaultOutput;
mkdirSync(outputRoot, { recursive: true });

const runnerRelative = 'packages/loot-core/src/server/budget/__actualist_template_note_oracle.test.ts';
const runnerPath = join(checkout, runnerRelative);
const specPath = join(checkout, '.actualist-template-note-spec.json');
const outputFile = join(checkout, '.actualist-template-note-output.json');
const dataDirectory = join(checkout, '.actualist-template-note-data');
for (const path of [runnerPath, specPath, outputFile]) {
  if (existsSync(path)) throw new Error(`Refusing to overwrite ${relative(checkout, path)}`);
}

let recorded;
try {
  mkdirSync(dataDirectory, { recursive: true });
  writeFileSync(runnerPath, readFileSync(join(repositoryRoot, harnessPath)));
  writeFileSync(specPath, JSON.stringify({ cases }, null, 2) + '\n');
  const result = spawnSync(
    'node',
    ['.yarn/releases/yarn-4.17.1.cjs', 'workspace', '@actual-app/core', 'vitest', '--run', runnerRelative.replace('packages/loot-core/', '')],
    {
      cwd: checkout,
      encoding: 'utf8',
      env: {
        ...process.env,
        ACTUAL_DATA_DIR: dataDirectory,
        ACTUALIST_TEMPLATE_NOTE_SPEC: specPath,
        ACTUALIST_TEMPLATE_NOTE_OUTPUT: outputFile,
      },
    },
  );
  if (result.status !== 0) {
    process.stderr.write(result.stdout ?? '');
    process.stderr.write(result.stderr ?? '');
    throw new Error(`The oracle run failed with status ${result.status}`);
  }
  recorded = JSON.parse(readFileSync(outputFile, 'utf8'));
} finally {
  rmSync(runnerPath, { force: true });
  rmSync(specPath, { force: true });
  rmSync(outputFile, { force: true });
  rmSync(dataDirectory, { force: true, recursive: true });
}
assertPinnedOracle(checkout, 'after generating');

const contractData = Buffer.from(JSON.stringify({
  schemaVersion: 1,
  oracle: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  syntheticData: { only: true },
  cases: recorded.cases,
}, null, 2) + '\n');
writeFileSync(join(outputRoot, contractName), contractData);

const logicalPath = name => relative(repositoryRoot, join(defaultOutput, name));
const fileHash = path => sha256(readFileSync(join(repositoryRoot, path)));
const manifestText = JSON.stringify({
  schemaVersion: 1,
  actual: { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion },
  generator: {
    command: `${ORACLE_ROOT_VARIABLE}=<pinned-actual> node scripts/template-note-parity/generate.mjs`,
    sha256: sha256(readFileSync(scriptPath)),
  },
  harness: { path: harnessPath, sha256: fileHash(harnessPath) },
  helpers: helperPaths.map(path => ({ path, sha256: fileHash(path) })),
  seed: null,
  caseCount: recorded.cases.length,
  sourceFiles: upstreamPaths.map(path => ({ path, sha256: sha256(readFileSync(join(checkout, path))) })),
  fixtures: [{ path: logicalPath(contractName), sha256: sha256(contractData), caseCount: recorded.cases.length }],
}, null, 2) + '\n';
writeFileSync(join(outputRoot, manifestName), manifestText);

if (checking) {
  const failures = compareWithCommitted(defaultOutput, outputRoot, [contractName, manifestName]);
  rmSync(outputRoot, { recursive: true, force: true });
  if (failures.length > 0) {
    for (const failure of failures) console.error(`template note parity drift: ${failure}`);
    process.exit(1);
  }
  console.log(`Template note parity fixtures match a fresh generation (${recorded.cases.length} cases).`);
} else {
  console.log(`Generated ${recorded.cases.length} template note cases`);
}
