// The single record of which Actual release the parity harnesses run against.
// Generators, verifiers and run scripts read config/parity/oracle-pin.json
// through this module (shell scripts through `node scripts/parity/lib/oracle-pin.mjs <field>`)
// instead of carrying their own copy of the tag or commit.
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
export const oraclePinPath = join(repositoryRoot, 'config/parity/oracle-pin.json');

export function readOraclePin() {
  const pin = JSON.parse(readFileSync(oraclePinPath, 'utf8'));
  for (const field of ['tag', 'commit', 'packageVersion', 'fixtureDirectory']) {
    if (typeof pin[field] !== 'string' || pin[field] === '') {
      throw new Error(`${oraclePinPath}: missing ${field}`);
    }
  }
  if (!/^[0-9a-f]{40}$/.test(pin.commit)) {
    throw new Error(`${oraclePinPath}: commit must be a full 40-character sha`);
  }
  return pin;
}

export const oraclePin = readOraclePin();

// Absolute path of a domain folder inside the pinned fixture directory.
export function pinnedFixtureDirectory(domain) {
  return join(repositoryRoot, oraclePin.fixtureDirectory, domain);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const field = process.argv[2];
  if (!field || !(field in oraclePin)) {
    console.error('Usage: node scripts/parity/lib/oracle-pin.mjs <tag|commit|packageVersion|fixtureDirectory>');
    process.exit(2);
  }
  console.log(oraclePin[field]);
}
