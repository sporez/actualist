#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const folder = pinnedFixtureDirectory('Templates');
const hash = value => createHash('sha256').update(value).digest('hex');
const manifest = JSON.parse(readFileSync(resolve(folder, 'template-editor-manifest.json')));
const bytes = readFileSync(resolve(folder, 'editor-cases.json'));
const fixture = JSON.parse(bytes);
if (manifest.tag !== oraclePin.tag || manifest.commit !== oraclePin.commit || manifest.packageVersion !== oraclePin.packageVersion) throw new Error('Template oracle pin changed');
if (manifest.seed !== null) throw new Error('Template oracle manifest seed must be null');
if (hash(bytes) !== manifest.fixtureSHA256) throw new Error('Template oracle fixtures changed without regeneration');
if (hash(readFileSync(resolve(root, 'scripts/template-parity/generate.mjs'))) !== manifest.generatorSHA256) throw new Error('Template oracle generator changed without regeneration');
for (const helper of manifest.helpers ?? []) {
  if (hash(readFileSync(resolve(root, helper.path))) !== helper.sha256) throw new Error(`Template oracle helper changed without regeneration: ${helper.path}`);
}
if (!manifest.helpers?.length) throw new Error('Template oracle manifest does not record its helper script');
const cases = [...fixture.normalizations, ...fixture.transitions, ...fixture.validations];
if (cases.length !== manifest.caseCount || cases.length < 44 || new Set(cases.map(c => c.id)).size !== cases.length) throw new Error('Template oracle coverage is incomplete');
for (const id of ['simple-zero-cap-plus-fixed', 'refill-with-limit', 'copy-inert-cap', 'spend-repeat', 'schedule-full-signed-fixed', 'average-signed-percent']) {
  if (!cases.some(c => c.id === id)) throw new Error(`Missing required template oracle: ${id}`);
}
if (manifest.sourceFiles.length !== 6 || manifest.sourceFiles.some(s => !/^[a-f0-9]{64}$/.test(s.sha256))) throw new Error('Template source provenance incomplete');
console.log(`Template editor parity fixtures verified (${manifest.tag}, ${cases.length} cases).`);
