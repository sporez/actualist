#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const folder = resolve(root, 'ActualistTests/Fixtures/ActualCore26_8_1/Templates');
const hash = value => createHash('sha256').update(value).digest('hex');
const manifest = JSON.parse(readFileSync(resolve(folder, 'template-editor-manifest.json')));
const bytes = readFileSync(resolve(folder, 'editor-cases.json'));
const fixture = JSON.parse(bytes);
if (manifest.tag !== 'v26.8.1' || manifest.commit !== '063df03763ca772b51f6264752b88ddec22cfb8a') throw new Error('Template oracle pin changed');
if (hash(bytes) !== manifest.fixtureSHA256) throw new Error('Template oracle fixtures changed without regeneration');
if (hash(readFileSync(resolve(root, 'scripts/template-parity/generate.mjs'))) !== manifest.generatorSHA256) throw new Error('Template oracle generator changed without regeneration');
const cases = [...fixture.normalizations, ...fixture.transitions, ...fixture.validations];
if (cases.length !== manifest.caseCount || cases.length < 44 || new Set(cases.map(c => c.id)).size !== cases.length) throw new Error('Template oracle coverage is incomplete');
for (const id of ['simple-zero-cap-plus-fixed', 'refill-with-limit', 'copy-inert-cap', 'spend-repeat', 'schedule-full-signed-fixed', 'average-signed-percent']) {
  if (!cases.some(c => c.id === id)) throw new Error(`Missing required template oracle: ${id}`);
}
if (manifest.sourceFiles.length !== 6 || manifest.sourceFiles.some(s => !/^[a-f0-9]{64}$/.test(s.sha256))) throw new Error('Template source provenance incomplete');
console.log(`Template editor parity fixtures verified (${manifest.tag}, ${cases.length} cases).`);
