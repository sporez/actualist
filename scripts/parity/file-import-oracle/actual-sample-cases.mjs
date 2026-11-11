// pipeline/actual-sample/<file>[/<variant>]: Actual's own sample CSV files, as raw bytes, through
// the modal's CSV import for one account.
//
// The pinned checkout ships these files as public test data; the bytes are read from it when the
// generator runs and recorded in the fixture (`bytesBase64`). They are synthetic: invented payees
// (a cafe, a bakery), a masked account number (`11600006-XXXXXXXX-XXXXXXXX`), a placeholder
// tariff name, round amounts. Their sha256 is in FROZEN_SOURCES, so a re-pin that changes one
// fails the hash check. Without a checkout (verify.mjs) the bytes come from the committed
// contract and are checked against the same hash.
//
// Variants mirror the options Actual's own tests pass for the file (parse-file.test.ts):
// a manual windows-1252 or iso-8859-1 encoding, an explicit auto encoding, an unknown encoding,
// and skipping the first line of a headerless read. Expected outputs are never written here.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pinnedFixtureDirectory } from '../lib/oracle-pin.mjs';
import { ACCOUNT_ID, PIPELINE_CATEGORIES, PREF } from './saved-settings-cases.mjs';

const E2E = 'packages/desktop-client/e2e/data';
const MOCKS = 'packages/loot-core/src/mocks/files';

// sha256 of each file in the pinned checkout (also listed in FROZEN_SOURCES).
export const SAMPLE_FILES = [
  { path: `${E2E}/test.csv`, sha256: '89b9c8407d00496b23c98fc5ac1e4aef264c64cebd5d35fcfbfa3e061a291952' },
  { path: `${MOCKS}/windows-1252.csv`, sha256: '6442e42b63036de26d42cde170de41d50d363a8f8a5eb18f28a8562ada7f63aa' },
  { path: `${MOCKS}/windows-1252-euro.csv`, sha256: 'a741ae5f56ccba5f6b2533099ed5321188d7f8b543ff6879686e66844f49e9ae' },
  { path: `${MOCKS}/utf-8-bom.csv`, sha256: '78d4d846138083677e3269b8b54ab208682c1b00077f872d7cddd4d14387c370' },
  { path: `${MOCKS}/utf-16be.csv`, sha256: '40694c27e65fef069ce0c59d1f4b9dd10eec757b639d480aad5dd1679916f999' },
  { path: `${MOCKS}/utf-16le.csv`, sha256: 'a01618ef337c254a2bd6019e4acdbba07ea56a6c2b8d0f9a7860116ae5342089' },
];

const name = path => path.slice(path.lastIndexOf('/') + 1);
const pref = (key, value) => [PREF[key], value];

// Variants per file: [variant id (or null for the default), prefs, description].
const VARIANTS = {
  'test.csv': [[null, [], 'the end-to-end test import file with default settings']],
  'windows-1252.csv': [
    [null, [], 'Windows-1252 bytes under the default auto encoding'],
    ['encoding-windows-1252', [pref('encoding', 'windows-1252')], 'Windows-1252 bytes with the encoding set to windows-1252 (parse-file.test.ts manual override)'],
  ],
  'windows-1252-euro.csv': [
    [null, [], 'a Windows-1252 euro sign (byte 0x80) under the default auto encoding'],
    ['encoding-windows-1252', [pref('encoding', 'windows-1252')], 'the euro sign with the encoding set to windows-1252'],
    ['encoding-iso-8859-1', [pref('encoding', 'iso-8859-1')], 'the euro sign with the iso-8859-1 label, a windows-1252 alias (parse-file.test.ts)'],
  ],
  'utf-8-bom.csv': [
    [null, [], 'a UTF-8 file with a byte order mark and a wide Hungarian bank header'],
    ['encoding-auto', [pref('encoding', 'auto')], 'an explicit auto encoding'],
    ['encoding-invalid', [pref('encoding', 'not-an-encoding')], 'an encoding label the decoder refuses (parse-file.test.ts)'],
  ],
  'utf-16be.csv': [[null, [], 'UTF-16BE with a byte order mark, the same content as utf-8-bom.csv']],
  'utf-16le.csv': [
    [null, [], 'UTF-16LE with a byte order mark, the same content as utf-8-bom.csv'],
    ['encoding-auto', [pref('encoding', 'auto')], 'an explicit auto encoding (parse-file.test.ts)'],
    ['headerless-skip-start-1', [pref('header', 'false'), pref('skipStart', '1')], 'no header row and the first line skipped (parse-file.test.ts)'],
  ],
};

let committedContract;
function committedSampleBytes(file) {
  if (committedContract === undefined) {
    const path = join(pinnedFixtureDirectory('FileImport'), 'file-import-contract.json');
    committedContract = existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')).cases : [];
  }
  const prefix = `pipeline/actual-sample/${name(file.path)}`;
  const record = committedContract.find(entry => entry.id === prefix);
  if (!record) throw new Error(`No oracle checkout and no committed bytes for ${file.path}`);
  return Buffer.from(record.input.bytesBase64, 'base64');
}

function sampleBytes(file) {
  const root = process.env.ACTUALIST_PARITY_ORACLE_ROOT;
  const bytes = root && existsSync(join(root, file.path)) ? readFileSync(join(root, file.path)) : committedSampleBytes(file);
  const hash = createHash('sha256').update(bytes).digest('hex');
  if (hash !== file.sha256) throw new Error(`Sample file ${file.path} does not match its frozen hash (${hash})`);
  return bytes;
}

export function actualSampleCases() {
  const cases = [];
  for (const file of SAMPLE_FILES) {
    const bytesBase64 = sampleBytes(file).toString('base64');
    for (const [variant, prefs, description] of VARIANTS[name(file.path)]) {
      cases.push({
        id: `pipeline/actual-sample/${name(file.path)}${variant === null ? '' : `/${variant}`}`,
        source: 'named',
        description: `${file.path} (Actual's public test data, synthetic): ${description}`,
        input: { accountId: ACCOUNT_ID, fileName: name(file.path), prefs, bytesBase64, categories: PIPELINE_CATEGORIES },
      });
    }
  }
  return cases;
}
