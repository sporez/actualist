// Run by generate.mjs under vitest against the pinned Actual checkout, inside a
// sandbox that denies writes to it. Every registered function is extracted from
// its frozen source file, evaluated in an isolated context and called for each
// planned case, while V8 precise coverage records which blocks the cases reach.
import assert from 'node:assert/strict';
import inspector from 'node:inspector';
import { readFileSync, writeFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import vm from 'node:vm';

const need = (name: string): string => {
  const value = process.env[name];
  assert.ok(value, `missing ${name}`);
  return value;
};
const root = need('ACTUALIST_FILE_IMPORT_ORACLE_ROOT');
const harness = need('ACTUALIST_FILE_IMPORT_ORACLE_HARNESS');
const planPath = need('ACTUALIST_FILE_IMPORT_ORACLE_PLAN');
const resultPath = need('ACTUALIST_FILE_IMPORT_ORACLE_RESULT');

const importAbsolute = (file: string) => import(/* @vite-ignore */ pathToFileURL(file).href);
const { test } = await importAbsolute(path.join(root, 'node_modules/vitest/dist/index.js'));
const ts = (await importAbsolute(path.join(root, 'node_modules/typescript/lib/typescript.js'))).default;
const { REGISTRY } = await importAbsolute(path.join(harness, 'registry.mjs'));

// JSON cannot carry these JS values, so they become { "$js": tag }.
function encode(value: unknown): unknown {
  if (value === undefined) return { $js: 'undefined' };
  if (typeof value === 'number') {
    if (Number.isNaN(value)) return { $js: 'NaN' };
    if (Object.is(value, -0)) return { $js: '-0' };
    if (value === Infinity) return { $js: 'Infinity' };
    if (value === -Infinity) return { $js: '-Infinity' };
    return value;
  }
  if (Array.isArray(value)) return value.map(encode);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, inner]) => [key, encode(inner)]));
  }
  return value;
}

function decode(value: any): unknown {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    if (typeof value.$js === 'string') {
      return { undefined: undefined, NaN, '-0': -0, Infinity, '-Infinity': -Infinity }[value.$js as string];
    }
    return Object.fromEntries(Object.entries(value).map(([key, inner]) => [key, decode(inner)]));
  }
  return Array.isArray(value) ? value.map(decode) : value;
}

// The declaration's text from its `function` keyword to its closing brace.
function extractFunction(file: string, name: string) {
  const source = readFileSync(path.join(root, file), 'utf8');
  const sourceFile = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true,
    file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS);
  const matches = sourceFile.statements.filter(
    (statement: any) => ts.isFunctionDeclaration(statement) && statement.name?.text === name && statement.body,
  );
  assert.equal(matches.length, 1, `${file} must declare exactly one top-level function ${name}, found ${matches.length}`);
  const node = matches[0];
  const keyword = node.getChildren(sourceFile).find((child: any) => child.kind === ts.SyntaxKind.FunctionKeyword);
  const start = keyword.getStart(sourceFile);
  const text = source.slice(start, node.end);
  const stripped = stripTypeScriptTypes(text, { mode: 'strip' });
  assert.equal(stripped.length, text.length, `type stripping moved characters in ${name}`);
  return { code: stripped, firstLine: sourceFile.getLineAndCharacterOfPosition(start).line + 1 };
}

// The initializer expression of a top-level `const name = ...;`.
function extractConstant(file: string, name: string) {
  const source = readFileSync(path.join(root, file), 'utf8');
  const sourceFile = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const matches = sourceFile.statements
    .filter((statement: any) => ts.isVariableStatement(statement))
    .flatMap((statement: any) => statement.declarationList.declarations)
    .filter((declaration: any) => declaration.name.text === name && declaration.initializer);
  assert.equal(matches.length, 1, `${file} must declare exactly one top-level const ${name}, found ${matches.length}`);
  return `(${stripTypeScriptTypes(matches[0].initializer.getText(sourceFile), { mode: 'strip' })})`;
}

// Maximal runs of zero-count code in a script, per V8 block coverage.
function uncoveredRuns(code: string, functions: any[]) {
  const ranges = functions.flatMap(entry => entry.ranges);
  const ordered = ranges
    .map((range: any, index: number) => ({ ...range, index }))
    .sort((a: any, b: any) => a.startOffset - b.startOffset || b.endOffset - a.endOffset || a.index - b.index);
  const counts = new Int32Array(code.length).fill(-1);
  for (const range of ordered) counts.fill(range.count, range.startOffset, Math.min(range.endOffset, code.length));
  const runs: Array<[number, number]> = [];
  let index = 0;
  while (index < code.length) {
    if (counts[index] !== 0) { index += 1; continue; }
    let end = index;
    while (end < code.length && counts[end] === 0) end += 1;
    let from = index;
    let to = end;
    while (from < to && /\s/.test(code[from])) from += 1;
    while (to > from && /\s/.test(code[to - 1])) to -= 1;
    if (to > from) runs.push([from, to]);
    index = end;
  }
  return runs;
}

test('file import oracle', async () => {
  const plan = JSON.parse(readFileSync(planPath, 'utf8'));
  const session = new inspector.Session();
  session.connect();
  const post = (method: string, params?: object) => new Promise<any>((resolve, reject) =>
    session.post(method, params, (error: Error | null, result: any) => (error ? reject(error) : resolve(result))));
  await post('Profiler.enable');
  await post('Profiler.startPreciseCoverage', { callCount: true, detailed: true });

  const modules = new Map<string, any>();
  const loadExport = async (from: string, exportName: string) => {
    if (!modules.has(from)) modules.set(from, await importAbsolute(path.join(root, from)));
    const exported = modules.get(from)[exportName];
    assert.ok(exported !== undefined, `${from} does not export ${exportName}`);
    return exported;
  };

  const functions = new Map<string, any>();
  for (const entry of REGISTRY) {
    const extracted = extractFunction(entry.source, entry.name);
    const sandbox: Record<string, unknown> = {};
    const context = vm.createContext(sandbox);
    for (const [globalName, dependency] of Object.entries<any>(entry.deps)) {
      sandbox[globalName] = dependency.constant
        ? vm.runInContext(extractConstant(dependency.from, dependency.constant), context)
        : await loadExport(dependency.from, dependency.export);
    }
    new vm.Script(extracted.code, { filename: `oracle-fn:${entry.name}` }).runInContext(context);
    const fn = (context as any)[entry.name];
    assert.equal(typeof fn, 'function', `${entry.name} did not evaluate to a function`);
    const real = entry.crossCheck ? await loadExport(entry.crossCheck.from, entry.crossCheck.export) : null;
    functions.set(entry.name, { entry, fn, real, ...extracted });
  }

  const outputs = new Map<string, unknown>();
  const records: any[] = [];
  for (const planCase of plan.cases) {
    const { entry, fn, real } = functions.get(planCase.function);
    let input = planCase.input;
    if (planCase.source === 'derived') {
      assert.ok(outputs.has(planCase.derivedFrom), `${planCase.id} derives from an earlier case ${planCase.derivedFrom}`);
      if (outputs.get(planCase.derivedFrom) === null) continue;
      input = { amount: encode(outputs.get(planCase.derivedFrom)) };
    }
    const runInput = decode(input);
    let result: unknown;
    let output: unknown;
    try {
      result = entry.call(fn, runInput);
      output = encode(result);
    } catch (error: any) {
      result = undefined;
      output = { $js: 'threw', message: String(error?.message ?? error) };
    }
    if (real) {
      let realOutput: unknown;
      try { realOutput = encode(entry.call(real, runInput)); } catch (error: any) {
        realOutput = { $js: 'threw', message: String(error?.message ?? error) };
      }
      assert.deepEqual(JSON.stringify(output), JSON.stringify(realOutput), `${planCase.id}: extracted copy differs from the real export`);
    }
    outputs.set(planCase.id, result);
    records.push({ ...planCase, input, output });
  }

  const { result: scripts } = await post('Profiler.takePreciseCoverage');
  await post('Profiler.stopPreciseCoverage');
  session.disconnect();

  const coverage: Record<string, unknown> = {};
  for (const [name, item] of functions) {
    const script = scripts.find((candidate: any) => candidate.url === `oracle-fn:${name}`);
    assert.ok(script, `no coverage was recorded for ${name}`);
    const runs = uncoveredRuns(item.code, script.functions);
    coverage[name] = {
      gate: item.entry.coverageGate,
      uncovered: runs.map(([from, to]) => ({
        startLine: item.firstLine + item.code.slice(0, from).split('\n').length - 1,
        endLine: item.firstLine + item.code.slice(0, to).split('\n').length - 1,
        snippet: item.code.slice(from, to).replace(/\s+/g, ' ').slice(0, 240),
      })),
    };
  }
  writeFileSync(resultPath, JSON.stringify({ records, coverage }));
}, 120_000);
