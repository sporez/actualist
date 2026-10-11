// The single record of which Actual release the parity harnesses run against,
// and the one way a harness locates and checks its oracle checkout.
//
// Generators, verifiers and run scripts read config/parity/oracle-pin.json
// through this module instead of carrying their own copy of the tag or commit.
// The oracle checkout comes only from ACTUALIST_PARITY_ORACLE_ROOT.
//
// Shell usage:
//   node scripts/parity/lib/oracle-pin.mjs <tag|commit|packageVersion|fixtureDirectory>
//   node scripts/parity/lib/oracle-pin.mjs oracle-root   prints the checked oracle root, or fails
//   node scripts/parity/lib/oracle-pin.mjs has-oracle    exit 0 when ACTUALIST_PARITY_ORACLE_ROOT is set
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
export const oraclePinPath = join(repositoryRoot, 'config/parity/oracle-pin.json');
export const ORACLE_ROOT_VARIABLE = 'ACTUALIST_PARITY_ORACLE_ROOT';

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

export function hasOracleRoot() {
  return Boolean(process.env[ORACLE_ROOT_VARIABLE]);
}

function git(root, args) {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed in ${root}: ${(result.stderr ?? '').trim()}`);
  }
  return result.stdout.trim();
}

// Throws unless `root` is a git checkout at the pinned commit and tag with a
// clean tree (untracked files included; node_modules is ignored upstream).
export function assertPinnedOracle(root, when = 'before generating') {
  if (!existsSync(join(root, '.git'))) {
    throw new Error(`${ORACLE_ROOT_VARIABLE} is not a git checkout: ${root}`);
  }
  const head = git(root, ['rev-parse', 'HEAD']);
  if (head !== oraclePin.commit) {
    throw new Error(`Oracle ${when}: HEAD is ${head}, pin is ${oraclePin.tag} ${oraclePin.commit}`);
  }
  const tags = git(root, ['tag', '--points-at', 'HEAD']).split('\n').filter(Boolean);
  if (!tags.includes(oraclePin.tag)) {
    throw new Error(`Oracle ${when}: HEAD is not tagged ${oraclePin.tag}`);
  }
  const status = git(root, ['status', '--porcelain', '--untracked-files=all']);
  if (status !== '') {
    throw new Error(`Oracle ${when}: checkout is not clean:\n${status}`);
  }
  return root;
}

// The checked oracle root from ACTUALIST_PARITY_ORACLE_ROOT. Generators call
// this before running and assertPinnedOracle(root, 'after generating') after.
export function pinnedOracleRoot() {
  const value = process.env[ORACLE_ROOT_VARIABLE];
  if (!value) {
    throw new Error(
      `Set ${ORACLE_ROOT_VARIABLE} to a clean checkout of Actual ${oraclePin.tag} (${oraclePin.commit}) with yarn install done.`,
    );
  }
  return assertPinnedOracle(resolve(value));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const field = process.argv[2];
  try {
    if (field === 'oracle-root') {
      console.log(pinnedOracleRoot());
    } else if (field === 'has-oracle') {
      process.exit(hasOracleRoot() ? 0 : 1);
    } else if (field && typeof oraclePin[field] === 'string') {
      console.log(oraclePin[field]);
    } else {
      console.error(
        'Usage: node scripts/parity/lib/oracle-pin.mjs <tag|commit|packageVersion|fixtureDirectory|oracle-root|has-oracle>',
      );
      process.exit(2);
    }
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}
