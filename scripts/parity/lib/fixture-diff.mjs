// Shared --check comparison for parity generators: compares each regenerated
// fixture byte-for-byte with the committed one and names the first differing
// JSON path. Used only by --check, so it does not affect generated output.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export function compareWithCommitted(committedDirectory, generatedDirectory, names) {
  const failures = [];
  for (const name of names) {
    let committed;
    try {
      committed = readFileSync(join(committedDirectory, name));
    } catch {
      failures.push(`${name}: committed fixture is missing`);
      continue;
    }
    const regenerated = readFileSync(join(generatedDirectory, name));
    if (committed.equals(regenerated)) continue;
    let detail = 'bytes differ';
    if (name.endsWith('.json')) {
      try {
        detail = firstDifference(JSON.parse(committed.toString('utf8')), JSON.parse(regenerated.toString('utf8')))
          ?? 'formatting differs';
      } catch {
        // Unparseable JSON keeps the byte-level detail.
      }
    }
    failures.push(`${name}: ${detail}`);
  }
  return failures;
}

export function firstDifference(expected, actual, path = '$') {
  if (Object.is(expected, actual)) return null;
  if (
    typeof expected !== 'object' || typeof actual !== 'object'
    || expected === null || actual === null
    || Array.isArray(expected) !== Array.isArray(actual)
  ) {
    return `${path}: ${JSON.stringify(expected)} != ${JSON.stringify(actual)}`;
  }
  for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
    const childPath = Array.isArray(expected) ? `${path}[${key}]` : `${path}.${key}`;
    if (!(key in expected) || !(key in actual)) return `${childPath}: present on one side only`;
    const difference = firstDifference(expected[key], actual[key], childPath);
    if (difference) return difference;
  }
  return null;
}
