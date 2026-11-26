#!/usr/bin/env node

// Checks the committed Enable Banking server fixture without an oracle:
// manifest pins, generator and helper hashes, scenario identity against the
// plan, the recorded inputs, the body text against its parsed copy, and the
// author's structural expectations. Regeneration is generate.mjs.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { oraclePin, pinnedFixtureDirectory } from '../parity/lib/oracle-pin.mjs';
import { buildScenarios, SCHEMA_VERSION, TODAY } from './scenarios.mjs';
import { contractName, expectationFailures, helperPaths, manifestName, sourceHashes } from './shape.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = resolve(dirname(scriptPath), '..', '..');
const fixtureDirectory = pinnedFixtureDirectory('EnableBankingServer');
const failures = [];
const note = message => failures.push(message);
const sha256 = data => createHash('sha256').update(data).digest('hex');
const sameJSON = (left, right) => JSON.stringify(left) === JSON.stringify(right);
const pin = { tag: oraclePin.tag, commit: oraclePin.commit, packageVersion: oraclePin.packageVersion };

const scenarios = buildScenarios();
if (new Set(scenarios.map(scenario => scenario.id)).size !== scenarios.length) note('scenario IDs are not unique');

const contractBytes = readFileSync(join(fixtureDirectory, contractName));
const contract = JSON.parse(contractBytes.toString('utf8'));
const manifest = JSON.parse(readFileSync(join(fixtureDirectory, manifestName), 'utf8'));

if (manifest.schemaVersion !== SCHEMA_VERSION) note(`manifest schemaVersion is ${manifest.schemaVersion}`);
if (!sameJSON(manifest.actual, pin)) note('manifest actual pin does not match config/parity/oracle-pin.json');
const generatorPath = join(dirname(scriptPath), 'generate.mjs');
if (manifest.generator?.sha256 !== sha256(readFileSync(generatorPath))) note('generate.mjs changed since the manifest was written');
if (!sameJSON(helperPaths, (manifest.helpers ?? []).map(helper => helper.path))) note('manifest helper list does not match shape.mjs');
for (const helper of manifest.helpers ?? []) {
  if (sha256(readFileSync(join(repositoryRoot, helper.path))) !== helper.sha256) {
    note(`helper ${helper.path} changed since the manifest was written`);
  }
}
if (!sameJSON(manifest.sourceFiles, Object.entries(sourceHashes).map(([path, hash]) => ({ path, sha256: hash })))) {
  note('manifest source hashes do not match shape.mjs');
}
if (manifest.today !== TODAY) note(`manifest today ${manifest.today} does not match ${TODAY}`);
if (manifest.scenarioCount !== scenarios.length) note(`manifest scenarioCount ${manifest.scenarioCount}, plan ${scenarios.length}`);
const fixture = manifest.fixtures?.[0];
const expectedPath = relative(repositoryRoot, join(fixtureDirectory, contractName));
if (manifest.fixtures?.length !== 1 || fixture.path !== expectedPath) note(`manifest fixture entry is not ${expectedPath}`);
if (fixture?.sha256 !== sha256(contractBytes)) note('contract bytes do not match the manifest fixture hash');
if (!sameJSON(fixture?.caseIDs, scenarios.map(scenario => scenario.id))) note('manifest caseIDs do not match the plan in order');

if (contract.schemaVersion !== SCHEMA_VERSION) note(`contract schemaVersion is ${contract.schemaVersion}`);
if (!sameJSON(contract.oracle, pin)) note('contract oracle pin does not match config/parity/oracle-pin.json');
if (!sameJSON(contract.syntheticData, { only: true })) note('contract is not marked synthetic');
if (!sameJSON(contract.environment, { today: TODAY })) note('contract environment does not match the plan');
if (!Array.isArray(contract.scenarios) || contract.scenarios.length !== scenarios.length) {
  note(`contract has ${contract.scenarios?.length} scenarios, plan has ${scenarios.length}`);
} else {
  contract.scenarios.forEach((record, index) => {
    const planned = scenarios[index];
    if (record.id !== planned.id) {
      note(`scenario ${index} is ${record.id}, plan says ${planned.id}`);
      return;
    }
    for (const field of ['description', 'configured', 'request', 'provider']) {
      if (!sameJSON(record[field], planned[field])) note(`${record.id}: ${field} differs from the plan`);
    }
    if (record.mountRoutes !== (planned.mountRoutes !== false)) note(`${record.id}: mountRoutes differs from the plan`);
    const { body, bodyText, contentType } = record.response ?? {};
    if (typeof bodyText !== 'string') note(`${record.id}: response.bodyText is missing`);
    else if (contentType === 'application/json' && !sameJSON(JSON.parse(bodyText), body)) {
      note(`${record.id}: response.body is not the parsed bodyText`);
    }
    for (const failure of expectationFailures(record)) note(`${record.id}: ${failure}`);
  });
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`enable banking verify: ${failure}`);
  console.error(`enable banking verify failed: ${failures.length} problem(s).`);
  process.exit(1);
}
console.log(`Enable Banking server fixture verified: ${scenarios.length} scenarios.`);
