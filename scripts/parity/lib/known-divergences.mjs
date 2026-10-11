// The known-divergence registry (config/parity/known-divergences.json) and its
// lint. A divergence from the pinned Actual may keep a test green only through
// `withKnownIssue("OP-nn: ...")` around that case's comparison, registered here.
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { repositoryRoot } from './oracle-pin.mjs';

export const registryPath = join(repositoryRoot, 'config/parity/known-divergences.json');
const testsRoot = join(repositoryRoot, 'ActualistTests');
const ID_PATTERN = /^OP-\d{2,}$/;
const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

export function loadRegistry() {
  const registry = JSON.parse(readFileSync(registryPath, 'utf8'));
  if (!Array.isArray(registry.divergences)) {
    throw new Error(`${registryPath}: missing divergences array`);
  }
  return registry.divergences;
}

function swiftFiles(directory) {
  const files = [];
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) files.push(...swiftFiles(path));
    else if (name.endsWith('.swift')) files.push(path);
  }
  return files;
}

// Replaces comments and string contents with spaces so brace matching and
// keyword searches see only code. Offsets are preserved.
function codeOnly(source) {
  const out = source.split('');
  let index = 0;
  const blank = (from, to) => {
    for (let position = from; position < to; position += 1) {
      if (out[position] !== '\n') out[position] = ' ';
    }
  };
  while (index < source.length) {
    if (source.startsWith('//', index)) {
      const end = source.indexOf('\n', index);
      const stop = end === -1 ? source.length : end;
      blank(index, stop);
      index = stop;
    } else if (source.startsWith('/*', index)) {
      const end = source.indexOf('*/', index + 2);
      const stop = end === -1 ? source.length : end + 2;
      blank(index, stop);
      index = stop;
    } else if (source.startsWith('"""', index)) {
      const end = source.indexOf('"""', index + 3);
      const stop = end === -1 ? source.length : end + 3;
      blank(index + 3, stop - 3);
      index = stop;
    } else if (source[index] === '"') {
      let position = index + 1;
      while (position < source.length && source[position] !== '"' && source[position] !== '\n') {
        position += source[position] === '\\' ? 2 : 1;
      }
      blank(index + 1, position);
      index = position + 1;
    } else {
      index += 1;
    }
  }
  return out.join('');
}

// Every withKnownIssue call with its enclosing type, test function, marker ID
// and closure body.
export function findMarkers() {
  const markers = [];
  const problems = [];
  for (const path of swiftFiles(testsRoot)) {
    const source = readFileSync(path, 'utf8');
    const code = codeOnly(source);
    const file = relative(repositoryRoot, path);
    const line = (offset) => source.slice(0, offset).split('\n').length;

    for (const match of code.matchAll(/\bisIntermittent\b/g)) {
      problems.push(`${file}:${line(match.index)}: isIntermittent is forbidden for known divergences`);
    }

    // Scope stack: entries are { kind, name } pushed at each `{`.
    const stack = [];
    let pending = null;
    const declaration = /\b(struct|class|extension|enum|actor|func)\s+([A-Za-z_][A-Za-z0-9_]*)/y;
    for (let offset = 0; offset < code.length; offset += 1) {
      declaration.lastIndex = offset;
      const found = declaration.exec(code);
      if (found && (offset === 0 || !/[A-Za-z0-9_]/.test(code[offset - 1]))) {
        pending = { kind: found[1] === 'func' ? 'func' : 'type', name: found[2] };
        offset += found[0].length - 1;
        continue;
      }
      if (code.startsWith('withKnownIssue', offset) && !/[A-Za-z0-9_.]/.test(code[offset - 1] ?? ' ')) {
        const typeScope = stack.find((scope) => scope.kind === 'type');
        const funcScope = stack.find((scope) => scope.kind === 'func');
        const literal = /^withKnownIssue\s*\(\s*"(OP-\d{2,}):[^"\n]+"/.exec(source.slice(offset));
        const open = code.indexOf('{', offset);
        let depth = 0;
        let close = open;
        for (; close < code.length; close += 1) {
          if (code[close] === '{') depth += 1;
          if (code[close] === '}' && --depth === 0) break;
        }
        const marker = {
          file,
          line: line(offset),
          id: literal?.[1] ?? null,
          testCase: typeScope && funcScope ? `${typeScope.name}/${funcScope.name}` : null,
          body: code.slice(open + 1, close),
        };
        if (!marker.id) {
          problems.push(`${file}:${marker.line}: withKnownIssue must start with a registered "OP-nn: description" literal`);
        }
        if (!marker.testCase) {
          problems.push(`${file}:${marker.line}: withKnownIssue outside a test function`);
        }
        if (/\bfor\b|\.forEach\b|\bwhile\b/.test(marker.body)) {
          problems.push(`${file}:${marker.line}: withKnownIssue must wrap one case's comparison, not a loop`);
        }
        markers.push(marker);
        offset += 'withKnownIssue'.length - 1;
        continue;
      }
      if (code[offset] === '{') {
        stack.push(pending ?? { kind: 'block', name: null });
        pending = null;
      } else if (code[offset] === '}') {
        stack.pop();
      } else if (code[offset] === ';') {
        pending = null;
      }
    }
  }
  return { markers, problems };
}

export function lint({ domainIds = null, today = new Date().toISOString().slice(0, 10) } = {}) {
  const errors = [];
  const warnings = [];
  const registry = loadRegistry();
  const byId = new Map();
  for (const entry of registry) {
    const where = `registry ${entry.id ?? '(no id)'}`;
    if (!ID_PATTERN.test(entry.id ?? '')) errors.push(`${where}: id must look like OP-01`);
    if (byId.has(entry.id)) errors.push(`${where}: duplicate id`);
    byId.set(entry.id, entry);
    if (!entry.domain) errors.push(`${where}: missing domain`);
    else if (domainIds && !domainIds.has(entry.domain)) errors.push(`${where}: unknown domain ${entry.domain}`);
    if (!Array.isArray(entry.cases) || entry.cases.length === 0) errors.push(`${where}: no cases`);
    if (!entry.summary) errors.push(`${where}: missing summary`);
    if (!DATE_PATTERN.test(entry.opened ?? '')) errors.push(`${where}: opened must be YYYY-MM-DD`);
    if (!DATE_PATTERN.test(entry.reviewBy ?? '')) errors.push(`${where}: reviewBy must be YYYY-MM-DD`);
    else if (entry.reviewBy < today) warnings.push(`${entry.id} is past its review-by date ${entry.reviewBy}: ${entry.summary}`);
  }

  const { markers, problems } = findMarkers();
  errors.push(...problems);
  const referenced = new Map();
  for (const marker of markers) {
    if (!marker.id) continue;
    const entry = byId.get(marker.id);
    if (!entry) {
      errors.push(`${marker.file}:${marker.line}: ${marker.id} is not in config/parity/known-divergences.json`);
      continue;
    }
    if (marker.testCase && !(entry.cases ?? []).includes(marker.testCase)) {
      errors.push(`${marker.file}:${marker.line}: ${marker.id} is used in ${marker.testCase}, which its entry does not list`);
    }
    if (!referenced.has(marker.id)) referenced.set(marker.id, new Set());
    referenced.get(marker.id).add(marker.testCase);
  }
  for (const entry of registry) {
    const used = referenced.get(entry.id);
    if (!used) {
      errors.push(`registry ${entry.id}: no test references it; remove the entry when the divergence is fixed`);
      continue;
    }
    for (const testCase of entry.cases ?? []) {
      if (!used.has(testCase)) errors.push(`registry ${entry.id}: lists ${testCase}, but that test has no ${entry.id} marker`);
    }
  }
  return { registry, errors, warnings };
}
