// Table digest shared by the live-lab ZIP interop peer and the portable archive
// parity harness: every table's live rows (`tombstone = 0` where the column
// exists), every column, order-independent. Engine bookkeeping that differs
// between copies of one budget is left out and only counted.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';

export function sql(db, query, params = []) {
  const bound = params.reduce((text, value) => text.replace('?', `'${String(value).replaceAll("'", "''")}'`), query);
  const out = execFileSync('sqlite3', ['-readonly', '-json', db, bound], { maxBuffer: 1 << 30 }).toString().trim();
  return out ? JSON.parse(out) : [];
}

// Engine bookkeeping that legitimately differs between copies of one budget.
export const excludedTables = /^(messages_crdt|messages_clock|messages_pending|kvcache|kvcache_key|sqlite_.*|actualist_.*)$/;

export function digest(db) {
  const tables = {};
  const excluded = {};
  for (const { name } of sql(db, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
    if (excludedTables.test(name)) {
      excluded[name] = sql(db, `SELECT COUNT(*) AS n FROM "${name}"`)[0].n;
      continue;
    }
    const columns = sql(db, `PRAGMA table_info("${name}")`).map(c => c.name);
    const where = columns.includes('tombstone') ? ' WHERE tombstone = 0' : '';
    const lines = sql(db, `SELECT * FROM "${name}"${where}`)
      .map(row => JSON.stringify(Object.keys(row).sort().map(k => [k, row[k]])))
      .sort();
    tables[name] = { count: lines.length, hash: createHash('sha256').update(lines.join('\n')).digest('hex'), lines };
  }
  return { tables, excluded };
}

export function compareDigests(expected, actual) {
  const names = [...new Set([...Object.keys(expected.tables), ...Object.keys(actual.tables)])].sort();
  const differences = [];
  for (const name of names) {
    const a = expected.tables[name];
    const b = actual.tables[name];
    if (!a || !b) {
      differences.push({ table: name, missingFrom: a ? 'actual' : 'expected' });
      continue;
    }
    if (a.hash === b.hash) continue;
    const inB = new Set(b.lines);
    const inA = new Set(a.lines);
    const short = line => (line.length > 400 ? line.slice(0, 400) + '…' : line);
    differences.push({
      table: name,
      expectedCount: a.count,
      actualCount: b.count,
      onlyExpected: a.lines.filter(l => !inB.has(l)).slice(0, 5).map(short),
      onlyActual: b.lines.filter(l => !inA.has(l)).slice(0, 5).map(short),
    });
  }
  return { equal: differences.length === 0, tables: names.length, differences };
}
