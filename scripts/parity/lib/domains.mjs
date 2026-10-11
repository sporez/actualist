// Loads config/parity/domains.json and answers which parity domains a set of
// changed files touches. Globs support `**` (any path depth), `*` (within one
// path segment) and `?`.
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { repositoryRoot } from './oracle-pin.mjs';

export const domainsPath = join(repositoryRoot, 'config/parity/domains.json');
export const STATUSES = ['covered', 'partial', 'uncovered'];

export function loadDomains() {
  const map = JSON.parse(readFileSync(domainsPath, 'utf8'));
  if (!Array.isArray(map.domains)) {
    throw new Error(`${domainsPath}: missing domains array`);
  }
  return map.domains;
}

export function globToRegExp(glob) {
  let pattern = '';
  for (let index = 0; index < glob.length; index += 1) {
    const character = glob[index];
    if (character === '*' && glob[index + 1] === '*') {
      index += 1;
      if (glob[index + 1] === '/') {
        index += 1;
        pattern += '(?:.*/)?';
      } else {
        pattern += '.*';
      }
    } else if (character === '*') {
      pattern += '[^/]*';
    } else if (character === '?') {
      pattern += '[^/]';
    } else {
      pattern += character.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${pattern}$`);
}

function git(args) {
  const result = spawnSync('git', ['-C', repositoryRoot, ...args], { encoding: 'utf8' });
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed: ${(result.stderr ?? '').trim()}`);
  }
  return result.stdout.split('\n').filter(Boolean);
}

export function trackedFiles() {
  return git(['ls-files', '--cached', '--others', '--exclude-standard']);
}

// Files changed in a commit range, or in the working tree (staged, unstaged and
// untracked) when no range is given.
export function changedFiles(range) {
  if (range) {
    return [...new Set(git(['diff', '--name-only', range]))].sort();
  }
  return [
    ...new Set([
      ...git(['diff', '--name-only', 'HEAD']),
      ...git(['diff', '--cached', '--name-only']),
      ...git(['ls-files', '--others', '--exclude-standard']),
    ]),
  ].sort();
}

export function domainMatches(domain, files) {
  const patterns = (domain.paths ?? []).map(globToRegExp);
  return files.filter((file) => patterns.some((pattern) => pattern.test(file)));
}

export function touchedDomains(domains, files) {
  return domains
    .map((domain) => ({ domain, files: domainMatches(domain, files) }))
    .filter((entry) => entry.files.length > 0);
}

// Map errors: unknown status, duplicate id, and globs that match no file.
export function validateDomains(domains, files = trackedFiles()) {
  const errors = [];
  const seen = new Set();
  for (const domain of domains) {
    if (!domain.id || seen.has(domain.id)) errors.push(`duplicate or missing domain id: ${domain.id}`);
    seen.add(domain.id);
    if (!STATUSES.includes(domain.status)) errors.push(`${domain.id}: unknown status ${domain.status}`);
    if (!Array.isArray(domain.paths) || domain.paths.length === 0) errors.push(`${domain.id}: no paths`);
    for (const glob of domain.paths ?? []) {
      const pattern = globToRegExp(glob);
      if (!files.some((file) => pattern.test(file))) errors.push(`${domain.id}: glob matches nothing: ${glob}`);
    }
    if (domain.status === 'covered' && !(domain.oracleSuites ?? []).length) {
      errors.push(`${domain.id}: covered but lists no oracle suites`);
    }
    for (const step of ['generate', 'verify', 'check']) {
      const command = domain.harness?.[step];
      if (!command) continue;
      const script = command.split(/\s+/).find((token) => token.startsWith('scripts/'));
      if (!script || !existsSync(join(repositoryRoot, script))) {
        errors.push(`${domain.id}: harness ${step} script missing: ${command}`);
      }
    }
    for (const suite of domain.oracleSuites ?? []) {
      if (!testTypeNames().has(suite)) errors.push(`${domain.id}: no test type named ${suite} in ActualistTests`);
    }
  }
  return errors;
}

let cachedTestTypes = null;
function testTypeNames() {
  if (cachedTestTypes) return cachedTestTypes;
  cachedTestTypes = new Set();
  const visit = (directory) => {
    for (const name of readdirSync(directory)) {
      const path = join(directory, name);
      if (statSync(path).isDirectory()) visit(path);
      else if (name.endsWith('.swift')) {
        for (const match of readFileSync(path, 'utf8').matchAll(/^(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?(?:struct|class)\s+(\w+)/gm)) {
          cachedTestTypes.add(match[1]);
        }
      }
    }
  };
  visit(join(repositoryRoot, 'ActualistTests'));
  return cachedTestTypes;
}
