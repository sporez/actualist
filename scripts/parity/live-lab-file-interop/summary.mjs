// Prints the live-lab file interop reports as one line per check and exits
// non-zero when any check differs or did not run. Usage: summary.mjs <handoff dir>
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
const read = name => {
  const p = path.join(dir, name);
  return fs.existsSync(p) ? JSON.parse(fs.readFileSync(p, 'utf8')) : null;
};
const lines = [];
let failed = false;
const check = (label, result, detail = '') => {
  const ok = result?.equal === true;
  failed ||= !ok;
  const why = result == null ? 'did not run' : result.error ?? detail;
  lines.push(`${ok ? 'PASS' : 'FAIL'}  ${label}${!ok && why ? `  (${why})` : ''}`);
};
const tables = data => (data?.differences ?? []).map(d => d.table).join(', ');

const zip = read('report-zip.json');
if (zip) {
  for (const [step, error] of Object.entries(zip.swiftErrors)) {
    failed = true;
    lines.push(`FAIL  Actualist ${step}: ${error}`);
  }
  check('Actualist reads the source budget (account balances)', zip.actualistReadsSource, `${zip.actualistReadsSource?.mismatches?.length} accounts differ`);
  check('Actualist download equals the source (all tables)', zip.actualistDownloadMatchesSource, `differ: ${tables(zip.actualistDownloadMatchesSource)}`);
  const z2 = zip.actualImportsActualistZip;
  check('Actualist ZIP -> Actual import: balances', z2?.balances ?? z2);
  check('Actualist ZIP -> Actual import: all tables', z2?.data ?? z2, `differ: ${tables(z2?.data)}`);
  const z1 = zip.actualistImportsActualZip;
  check('Actual ZIP -> Actualist import: balances', z1?.balances);
  check('Actual ZIP -> Actualist import: all tables', z1?.data, `differ: ${tables(z1?.data)}`);
  const up = zip.actualReadsActualistUpload;
  check("Actual reads Actualist's uploaded import: balances", up?.balances ?? up);
  check("Actual reads Actualist's uploaded import: all tables", up?.data ?? up, `differ: ${tables(up?.data)}`);
} else {
  check('ZIP checks', null);
}

const csv = read('report-csv.json');
if (csv) {
  for (const [step, error] of Object.entries(csv.swiftErrors)) {
    failed = true;
    lines.push(`FAIL  Actualist ${step}: ${error}`);
  }
  for (const [key, account] of Object.entries(csv.accounts)) {
    const rows = r => `${r?.onlyExpectedCount ?? '?'} rows only in Actual's, ${r?.onlyActualCount ?? '?'} only in the other`;
    check(`CSV ${key} (${account.sourceAccount}): Actualist export equals Actual export`, account.encoderParity, rows(account.encoderParity?.rows));
    check(`CSV ${key}: Actual imports Actualist's CSV like its own`, account.actualistCSVInActual.rowsVsActualCSV, rows(account.actualistCSVInActual.rowsVsActualCSV));
    const imported = account.actualCSVInActualist;
    check(`CSV ${key}: Actualist imports Actual's CSV like Actual`, imported, imported?.error ?? rows(imported));
    if (imported?.ignoringCleared) {
      check(`CSV ${key}: ... ignoring Cleared`, imported.ignoringCleared, rows(imported.ignoringCleared));
    }
    const server = account.actualistCSVImportOnServer;
    check(`CSV ${key}: the server has Actualist's imported rows`, server, server?.error ?? `server has ${server?.actualCount} of ${server?.expectedCount}`);
  }
} else {
  check('CSV checks', null);
}

console.log(lines.join('\n'));
console.log(`Reports: ${path.join(dir, 'report-zip.json')}, ${path.join(dir, 'report-csv.json')}`);
process.exit(failed ? 1 : 0);
