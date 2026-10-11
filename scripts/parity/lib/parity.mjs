// Implementation of scripts/parity.sh. See `scripts/parity.sh help`.
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot, hasOracleRoot, ORACLE_ROOT_VARIABLE, oraclePin, pinnedFixtureDirectory } from './oracle-pin.mjs';
import { changedFiles, loadDomains, touchedDomains, validateDomains } from './domains.mjs';
import { isOpen, lint, loadRegistry } from './known-divergences.mjs';

const USAGE = `Usage: scripts/parity.sh [--dry-run] <command>

  status                 Print every parity domain with its coverage and open
                         divergences. Fails on map errors (a glob that matches
                         nothing, a covered domain without suites).
  touched [<range>]      List domains whose paths match the working tree, or a
                         commit range such as main..HEAD, and the commands to run.
  verify <domain>        Run the domain's fixture hash check, its regenerate-and-diff
                         check when ${ORACLE_ROOT_VARIABLE} is set, then its Swift
                         oracle suites through scripts/test.sh.
  verify-hashes          Run every harness's hash check (no oracle, no Xcode).
  divergences            Lint the known-divergence registry and list open entries.
  gate [<range>] [--ack OP-01,OP-02]
                         Fail while an open divergence sits in a domain the range
                         touches (every open entry when no range is given), unless
                         each one is acknowledged by ID.

--dry-run prints the commands verify would run without running them.`;

function run(command, { dryRun }) {
  console.log(`$ ${command}`);
  if (dryRun) return 0;
  const result = spawnSync('bash', ['-c', command], { cwd: repositoryRoot, stdio: 'inherit' });
  return result.status ?? 1;
}

function openByDomain() {
  const map = new Map();
  for (const entry of loadRegistry()) {
    if (!map.has(entry.domain)) map.set(entry.domain, []);
    map.get(entry.domain).push(entry);
  }
  return map;
}

function quoteSuites(suites) {
  return suites.map((suite) => `'${suite.replaceAll("'", "'\\''")}'`).join(' ');
}

function testCommand(domain) {
  return `scripts/test.sh unit ${quoteSuites(domain.oracleSuites)}`;
}

function status() {
  const domains = loadDomains();
  const open = openByDomain();
  console.log(`Oracle pin: Actual ${oraclePin.tag} (${oraclePin.commit})`);
  for (const domain of domains) {
    const entries = open.get(domain.id) ?? [];
    const divergences = entries.filter(isOpen).map((entry) => entry.id);
    const intended = entries.filter((entry) => !isOpen(entry)).map((entry) => entry.id);
    const harness = domain.harness?.dir ?? 'no harness';
    const suites = (domain.oracleSuites ?? []).length;
    console.log(
      `${domain.status.padEnd(9)} ${domain.id.padEnd(22)} ${harness}; ${suites} oracle suite(s)` +
        (divergences.length ? `; open: ${divergences.join(', ')}` : '') +
        (intended.length ? `; intended: ${intended.join(', ')}` : ''),
    );
  }
  const errors = validateDomains(domains);
  for (const error of errors) console.error(`error: ${error}`);
  return errors.length ? 1 : 0;
}

function touched(range) {
  const files = changedFiles(range);
  const hits = touchedDomains(loadDomains(), files);
  const open = openByDomain();
  const scope = range ? `range ${range}` : 'working tree';
  if (hits.length === 0) {
    console.log(`No parity domain touched (${scope}, ${files.length} changed file(s)).`);
    return 0;
  }
  console.log(`Parity domains touched (${scope}):`);
  for (const { domain, files: matched } of hits) {
    console.log(`- ${domain.id} [${domain.status}]: ${matched.length} file(s)`);
    for (const file of matched) console.log(`    ${file}`);
    if (domain.status === 'uncovered') {
      console.log('    no oracle harness: name this domain as unverified against Actual in the handoff');
    } else {
      console.log(`    run: scripts/parity.sh verify ${domain.id}`);
    }
    for (const entry of open.get(domain.id) ?? []) {
      console.log(`    ${isOpen(entry) ? 'open divergence' : 'intended difference'} ${entry.id}: ${entry.summary}`);
    }
  }
  return 0;
}

function verify(id, { dryRun }) {
  const domain = loadDomains().find((candidate) => candidate.id === id);
  if (!domain) {
    console.error(`Unknown domain: ${id}. See scripts/parity.sh status.`);
    return 2;
  }
  const steps = [];
  let failed = false;
  const harness = domain.harness ?? {};

  if (harness.verify) {
    const code = run(harness.verify, { dryRun });
    steps.push(`hash check: ${dryRun ? 'dry run' : code === 0 ? 'passed' : 'FAILED'}`);
    failed ||= code !== 0;
  } else {
    steps.push('hash check: none (no committed fixture)');
  }

  if (harness.check && hasOracleRoot()) {
    const code = run(harness.check, { dryRun });
    steps.push(`regenerate-and-diff against ${oraclePin.tag}: ${dryRun ? 'dry run' : code === 0 ? 'passed' : 'FAILED'}`);
    failed ||= code !== 0;
  } else if (harness.check) {
    steps.push(`regenerate-and-diff: SKIPPED (${ORACLE_ROOT_VARIABLE} not set); this is not a fresh-oracle pass`);
  } else {
    steps.push('regenerate-and-diff: none for this harness');
  }

  if ((domain.oracleSuites ?? []).length) {
    if (failed && !dryRun) {
      steps.push('Swift oracle suites: not run because an earlier step failed');
    } else {
      const code = run(testCommand(domain), { dryRun });
      steps.push(`Swift oracle suites: ${dryRun ? 'dry run' : code === 0 ? 'passed' : 'FAILED'}`);
      failed ||= code !== 0;
    }
  } else {
    steps.push(`Swift oracle suites: none; ${domain.id} is ${domain.status} and unverified against Actual by Swift replay`);
  }

  console.log(`\nparity verify ${domain.id}:`);
  for (const step of steps) console.log(`- ${step}`);
  for (const entry of openByDomain().get(domain.id) ?? []) {
    const label = isOpen(entry)
      ? `open divergence ${entry.id} (expected failure, review by ${entry.reviewBy})`
      : `intended difference ${entry.id} (expected failure, decided ${entry.decided})`;
    console.log(`- ${label}: ${entry.summary}`);
  }
  return failed ? 1 : 0;
}

function verifyHashes({ dryRun }) {
  let failed = false;
  for (const domain of loadDomains()) {
    if (!domain.harness?.verify) continue;
    failed ||= run(domain.harness.verify, { dryRun }) !== 0;
  }
  return failed ? 1 : 0;
}

// Every string value in a domain's fixture JSON, so registry fixtureCases can be
// checked against real case IDs.
function fixtureStrings(domains) {
  const cache = new Map();
  return (domainId) => {
    if (cache.has(domainId)) return cache.get(domainId);
    const domain = domains.find((candidate) => candidate.id === domainId);
    const directory = domain?.fixture ? pinnedFixtureDirectory(domain.fixture) : null;
    let strings = null;
    if (directory && existsSync(directory)) {
      strings = new Set();
      const collect = (value) => {
        if (typeof value === 'string') strings.add(value);
        else if (value && typeof value === 'object') Object.values(value).forEach(collect);
      };
      for (const name of readdirSync(directory).filter((file) => file.endsWith('.json'))) {
        collect(JSON.parse(readFileSync(join(directory, name), 'utf8')));
      }
    }
    cache.set(domainId, strings);
    return strings;
  };
}

function divergences() {
  const domains = loadDomains();
  const domainIds = new Set(domains.map((domain) => domain.id));
  const { registry, errors, warnings } = lint({ domainIds, fixtureCaseIds: fixtureStrings(domains) });
  for (const error of errors) console.error(`error: ${error}`);
  const openEntries = registry.filter(isOpen);
  const intendedEntries = registry.filter((entry) => !isOpen(entry));
  console.log(
    `Open known divergences: ${openEntries.length}` +
      (openEntries.length ? ` (${openEntries.map((entry) => entry.id).join(', ')})` : ''),
  );
  console.log(
    `Intended differences: ${intendedEntries.length}` +
      (intendedEntries.length ? ` (${intendedEntries.map((entry) => entry.id).join(', ')})` : ''),
  );
  for (const warning of warnings) console.log(`warning: ${warning}`);
  return errors.length ? 1 : 0;
}

function gate(args) {
  let range = null;
  const acknowledged = new Set();
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === '--ack') {
      for (const id of (args[++index] ?? '').split(',').filter(Boolean)) acknowledged.add(id.trim());
    } else if (!range) {
      range = args[index];
    } else {
      console.error(USAGE);
      return 2;
    }
  }
  const registry = loadRegistry().filter(isOpen);
  const touchedIds = range
    ? new Set(touchedDomains(loadDomains(), changedFiles(range)).map(({ domain }) => domain.id))
    : null;
  const relevant = registry.filter((entry) => !touchedIds || touchedIds.has(entry.domain));
  const blocking = relevant.filter((entry) => !acknowledged.has(entry.id));
  const scope = range ? `domains touched by ${range}` : 'all domains';
  if (relevant.length === 0) {
    console.log(`Parity gate: no open divergence in ${scope}.`);
    return 0;
  }
  console.log(`Parity gate: open divergences in ${scope}:`);
  for (const entry of relevant) {
    const state = acknowledged.has(entry.id) ? 'acknowledged' : 'BLOCKING';
    console.log(`- ${entry.id} [${entry.domain}] ${state}: ${entry.summary}`);
  }
  if (blocking.length) {
    console.log(`Acknowledge each by name to proceed: --ack ${blocking.map((entry) => entry.id).join(',')}`);
    return 1;
  }
  return 0;
}

const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const positional = args.filter((arg) => arg !== '--dry-run');
const [command, ...rest] = positional;

let code;
try {
  switch (command) {
    case 'status':
      code = status();
      break;
    case 'touched':
      code = touched(rest[0]);
      break;
    case 'verify':
      code = rest[0] ? verify(rest[0], { dryRun }) : 2;
      if (!rest[0]) console.error(USAGE);
      break;
    case 'verify-hashes':
      code = verifyHashes({ dryRun });
      break;
    case 'divergences':
      code = divergences();
      break;
    case 'gate':
      code = gate(rest);
      break;
    case 'help':
    case undefined:
      console.log(USAGE);
      code = command ? 0 : 2;
      break;
    default:
      console.error(USAGE);
      code = 2;
  }
} catch (error) {
  console.error(`parity: ${error.message}`);
  code = 1;
}
process.exit(code);
