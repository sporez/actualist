// Cases for the file options of `parseCsvRecords`: `skipStartLines`, `skipEndLines` and
// `encoding` (all optional in the input; they default to 0, 0 and 'auto'). Pure data: no expected
// output lives here. parseFile skips lines after decoding by splitting on /\r?\n/ (a lone CR is
// not a break), and rejoins the kept lines with CRLF, which also rewrites a line feed inside a
// quoted field. Skips are clamped at zero with Math.max; a total at or above the line count is an
// error.
import { mulberry32 } from '../sync-merkle/cases.mjs';
import { base64, between, chance, encodeText, pad, pick } from './case-kit.mjs';

export const CSV_OPTION_SEED = 20261109 + 13;
export const CSV_OPTION_GENERATED_COUNT = 300;

const DELIMITERS = [',', ';', '|', '\t', '~'];

function optionInput(data, { delimiter = ',', header = false, skipStart, skipEnd, encoding } = {}) {
  const input = typeof data === 'string'
    ? { csv: data, delimiter, hasHeaderRow: header }
    : { bytesBase64: base64(data), delimiter, hasHeaderRow: header };
  if (skipStart !== undefined) input.skipStartLines = skipStart;
  if (skipEnd !== undefined) input.skipEndLines = skipEnd;
  if (encoding !== undefined) input.encoding = encoding;
  return input;
}

const option = (id, data, description, options) => ({
  id: `parseCsvRecords/${id}`,
  source: 'named',
  description,
  input: optionInput(data, options),
});

function skipCases() {
  const rows = 'junk,line\nh1,h2\n1,2\n3,4\n';
  const crlf = rows.replaceAll('\n', '\r\n');
  const quoted = 'h1,h2\n"a\nb",c\nx,y\n';
  return [
    option('skip/start-1-lf', rows, 'skip one start line, LF', { skipStart: 1 }),
    option('skip/start-1-lf-header', rows, 'skip one start line, then a header row', { skipStart: 1, header: true }),
    option('skip/start-2-lf', rows, 'skip two start lines', { skipStart: 2 }),
    option('skip/start-1-crlf', crlf, 'skip one start line, CRLF', { skipStart: 1 }),
    option('skip/start-1-crlf-header', crlf, 'skip one start line, CRLF, header row', { skipStart: 1, header: true }),
    option('skip/start-0-explicit', rows, 'skipStartLines present and zero', { skipStart: 0, skipEnd: 0 }),
    option('skip/end-1-lf', rows, 'skip one end line: only the blank line after the final line feed goes', { skipEnd: 1 }),
    option('skip/end-2-lf', rows, 'skip two end lines: the blank line and one row', { skipEnd: 2 }),
    option('skip/end-1-crlf', crlf, 'skip one end line, CRLF', { skipEnd: 1 }),
    option('skip/end-2-no-trailing-newline', 'h1,h2\n1,2\ntotal,3', 'skip two end lines of a file with no trailing newline', { skipEnd: 2 }),
    option('skip/end-1-no-trailing-newline', 'h1,h2\n1,2\ntotal,3', 'skip one end line of a file with no trailing newline', { skipEnd: 1 }),
    option('skip/both-lf', 'junk\nh1,h2\n1,2\nsummary\n', 'skip one start and two end lines', { skipStart: 1, skipEnd: 2, header: true }),
    option('skip/both-crlf', 'junk\r\nh1,h2\r\n1,2\r\nsummary\r\n', 'skip one start and two end lines, CRLF', { skipStart: 1, skipEnd: 2, header: true }),

    // The empty last line counts as a line.
    option('skip/trailing-newline-counts-total', 'a,b\nc,d\n', 'two rows and a trailing newline are three lines: skipping 2 + 1 fails', { skipStart: 2, skipEnd: 1 }),
    option('skip/trailing-newline-counts-fits', 'a,b\nc,d\n', 'two rows and a trailing newline: skipping 1 + 1 leaves the second row', { skipStart: 1, skipEnd: 1 }),
    option('skip/no-trailing-newline-total', 'a,b\nc,d', 'two lines: skipping 1 + 1 fails', { skipStart: 1, skipEnd: 1 }),
    option('skip/no-trailing-newline-fits', 'a,b\nc,d', 'two lines: skipping 1 leaves one', { skipStart: 1 }),
    option('skip/start-equals-count', 'a\nb\nc', 'start skip equal to the line count', { skipStart: 3 }),
    option('skip/start-above-count', 'a\nb\nc', 'start skip above the line count', { skipStart: 9 }),
    option('skip/end-equals-count', 'a\nb\nc', 'end skip equal to the line count', { skipEnd: 3 }),
    option('skip/end-above-count', 'a\nb\nc', 'end skip above the line count', { skipEnd: 50 }),
    option('skip/sum-equals-count', 'a\nb\nc', 'start and end skips summing to the line count', { skipStart: 2, skipEnd: 1 }),
    option('skip/sum-one-below-count', 'a\nb\nc', 'start and end skips one below the line count', { skipStart: 1, skipEnd: 1 }),
    option('skip/empty-file', '', 'an empty file is one empty line: skipping one fails', { skipStart: 1 }),
    option('skip/empty-file-end', '', 'an empty file, end skip', { skipEnd: 1 }),
    option('skip/single-newline', '\n', 'one newline is two empty lines', { skipStart: 1 }),
    option('skip/single-newline-both', '\n', 'one newline: skipping 1 + 1 fails', { skipStart: 1, skipEnd: 1 }),

    // Line breaks: only LF and CRLF.
    option('skip/lone-cr-is-one-line', 'junk\ra,b\rc,d\r', 'a lone CR is not a line break: one line, so skipping one fails', { skipStart: 1 }),
    option('skip/lone-cr-no-skip', 'junk\ra,b\rc,d\r', 'the same file without skipping reads three rows', {}),
    option('skip/lone-cr-inside-skipped-line', 'x\ry\na,b\n', 'a lone CR inside the skipped line goes with it', { skipStart: 1 }),
    option('skip/lone-cr-inside-kept-line', 'junk\na\rb,c\n', 'a lone CR in a kept line stays', { skipStart: 1 }),
    option('skip/mixed-endings', 'one\r\ntwo\nthree\r\nfour,5\n', 'mixed CRLF and LF endings both count', { skipStart: 3 }),
    option('skip/mixed-endings-end', 'one,1\r\ntwo,2\nthree,3\r\nfour,4\n', 'mixed endings, end skip', { skipEnd: 2 }),
    option('skip/cr-then-lf-split', 'a\r\r\nb,c\n', 'CR CR LF splits after the second CR; the first CR stays on the skipped line', { skipStart: 1 }),
    option('skip/cr-then-lf-kept', 'junk\na,b\r\r\nc,d\n', 'CR CR LF in a kept line leaves a CR in the field', { skipStart: 1 }),

    // Values that clamp.
    option('skip/negative-start', rows, 'a negative start skip reads as zero', { skipStart: -1 }),
    option('skip/negative-end', rows, 'a negative end skip reads as zero', { skipEnd: -2 }),
    option('skip/negative-both', rows, 'both negative: nothing is skipped and LF endings stay LF', { skipStart: -3, skipEnd: -4 }),
    option('skip/negative-start-positive-end', rows, 'a negative start with a positive end', { skipStart: -5, skipEnd: 1 }),
    option('skip/positive-start-negative-end', rows, 'a positive start with a negative end', { skipStart: 1, skipEnd: -5 }),
    option('skip/huge-start', rows, 'a very large start skip', { skipStart: 1000000 }),

    // Rewriting a line feed in a quoted field.
    option('skip/rejoin-rewrites-quoted-lf', 'junk\nh1,h2\n"a\nb",c\n', 'skipping a line rewrites the quoted field\'s LF as CRLF', { skipStart: 1, header: true }),
    option('skip/no-skip-keeps-quoted-lf', 'h1,h2\n"a\nb",c\n', 'without skipping the quoted field keeps its LF', { header: true }),
    option('skip/zero-skip-keeps-quoted-lf', 'h1,h2\n"a\nb",c\n', 'skips of zero keep the quoted field\'s LF', { header: true, skipStart: 0, skipEnd: 0 }),
    option('skip/rejoin-keeps-quoted-crlf', 'junk\nh1,h2\n"a\r\nb",c\n', 'a quoted CRLF stays CRLF', { skipStart: 1, header: true }),
    option('skip/rejoin-keeps-quoted-cr', 'junk\nh1,h2\n"a\rb",c\n', 'a quoted lone CR stays CR', { skipStart: 1, header: true }),

    // Skipping through a quoted multi-line field.
    option('skip/cut-into-quoted-start', quoted, 'the start skip ends inside a quoted field: the rest starts mid-field', { skipStart: 2 }),
    option('skip/cut-into-quoted-start-header', quoted, 'the same with a header row', { skipStart: 2, header: true }),
    option('skip/cut-after-quoted-start', quoted, 'the start skip ends after the quoted field closes', { skipStart: 3 }),
    option('skip/cut-into-quoted-end', quoted, 'the end skip keeps the whole quoted field', { skipEnd: 2 }),
    option('skip/cut-through-quoted-end', quoted, 'the end skip cuts the quoted field: an unclosed quote', { skipEnd: 3 }),
    option('skip/cut-through-quoted-end-all-but-opening', '"a\nb\nc"\nx,y', 'the end skip leaves only the opening of a quoted field', { skipEnd: 3 }),
    option('skip/quoted-field-spanning-skipped-lines', '"j\nk"\nh1,h2\n1,2\n', 'the start skip removes the first line of a quoted field and leaves its closing quote', { skipStart: 1 }),
    option('skip/quoted-field-skipped-whole', '"j\nk"\nh1,h2\n1,2\n', 'two start lines remove a whole quoted field', { skipStart: 2 }),

    // Blank lines count too.
    option('skip/blank-lines-counted', '\n\nh1,h2\n1,2\n', 'blank lines are lines', { skipStart: 2, header: true }),
    option('skip/blank-lines-kept', '\n\nh1,h2\n1,2\n', 'one skipped blank line leaves a blank one that csv-parse drops', { skipStart: 1, header: true }),
    option('skip/blank-end-lines', 'h1,h2\n1,2\n\n\n', 'trailing blank lines are lines', { skipEnd: 2, header: true }),
    option('skip/whitespace-line-counted', ' \nh1,h2\n1,2\n', 'a whitespace-only line is a line', { skipStart: 1, header: true }),

    // Other file shapes.
    option('skip/bom-on-skipped-line', '﻿junk\nh1,h2\n1,2\n', 'the U+FEFF of the skipped first line goes with it', { skipStart: 1, header: true }),
    option('skip/bom-on-kept-line', '﻿h1,h2\n1,2\njunk\n', 'a U+FEFF on the first kept line is stripped by the reader', { skipEnd: 2, header: true }),
    option('skip/bom-no-skip-line', '﻿junk\nh1,h2\n', 'U+FEFF before a line that is kept', { skipEnd: 1 }),
    option('skip/tab-delimited', 'junk\nh1\th2\n1\t2\n', 'tab delimiter', { skipStart: 1, header: true, delimiter: '\t' }),
    option('skip/semicolon-delimited', 'junk;x\nh1;h2\n1;2\n', 'semicolon delimiter', { skipStart: 1, header: true, delimiter: ';' }),
    option('skip/bank-preamble', 'Account: 0000\r\nExported: 2026-01-31\r\n\r\nDate,Amount,Payee\r\n2026-01-05,-12.34,Example Store\r\nTotal,-12.34,\r\n',
      'a bank preamble of three lines and a summary line', { skipStart: 3, skipEnd: 2, header: true }),
    option('skip/bank-preamble-end-one', 'Account: 0000\r\n\r\nDate,Amount\r\n2026-01-05,-12.34\r\nTotal,-12.34\r\n',
      'the same with end skip 1: the trailing blank line is the only one removed', { skipStart: 2, skipEnd: 1, header: true }),
  ];
}

const ENCODINGS = ['auto', 'utf-8', 'utf-16le', 'utf-16be', 'windows-1252', 'windows-1250', 'iso-8859-2'];
const SAMPLE = 'Date,Payee,Amount\r\n2026-01-05,Café Ñandú,-12.34\r\n2026-01-06,Sample Store,5.00\r\n';
const SINGLE_BYTE_LABELS = ['windows-1252', 'windows-1250', 'iso-8859-2'];
const DATA_KINDS = ['utf8', 'utf8-bom', 'utf16le', 'utf16le-bom', 'utf16be', 'utf16be-bom', 'latin1'];

function encodingCases() {
  const cases = [];
  // The same file in every byte layout, read under every label.
  for (const kind of DATA_KINDS) {
    for (const encoding of ENCODINGS) {
      cases.push(option(`encoding/${kind}/${encoding}`, encodeText(SAMPLE, kind), `${kind} bytes read as ${encoding}`,
        { header: true, encoding }));
    }
  }
  // Skips applied to the decoded text.
  cases.push(
    option('encoding/skip-utf16le-bom', encodeText(`junk\r\n${SAMPLE}`, 'utf16le-bom'), 'UTF-16LE with a mark, skip one line, auto', { header: true, skipStart: 1 }),
    option('encoding/skip-utf16be-bom-end', encodeText(`${SAMPLE}total,1,2\r\n`, 'utf16be-bom'), 'UTF-16BE with a mark, skip two end lines, auto', { header: true, skipEnd: 2 }),
    option('encoding/skip-utf16le-explicit', encodeText(`junk\n${SAMPLE}`, 'utf16le'), 'UTF-16LE without a mark, explicit label, skip one line', { header: true, skipStart: 1, encoding: 'utf-16le' }),
    option('encoding/skip-windows-1252', encodeText(`junk\n${SAMPLE}`, 'latin1'), 'windows-1252 bytes, skip one line', { header: true, skipStart: 1, encoding: 'windows-1252' }),
    option('encoding/skip-iso-8859-2-both', encodeText(`junk\r\n${SAMPLE}summary\r\n`, 'latin1'), 'ISO-8859-2 bytes, skip one start and two end lines', { header: true, skipStart: 1, skipEnd: 2, encoding: 'iso-8859-2' }),
    option('encoding/skip-total-error', encodeText(SAMPLE, 'utf16le-bom'), 'UTF-16LE, skips that exceed the lines', { skipStart: 4, skipEnd: 1 }),
    option('encoding/skip-utf8-bom-explicit', encodeText(`junk\n${SAMPLE}`, 'utf8-bom'), 'UTF-8 with a mark, explicit label, skip one line', { header: true, skipStart: 1, encoding: 'utf-8' }),
    option('encoding/unsupported-label', encodeText(SAMPLE, 'utf8'), 'a label TextDecoder refuses is a read error', { header: true, encoding: 'klingon' }),
    option('encoding/padded-label', encodeText(SAMPLE, 'utf8'), 'TextDecoder trims the label', { header: true, encoding: ' utf-8 ' }),
    option('encoding/uppercase-label', encodeText(SAMPLE, 'utf8'), 'TextDecoder lowercases the label', { header: true, encoding: 'UTF-8' }),
    option('encoding/latin1-label', encodeText(SAMPLE, 'latin1'), 'latin1 is windows-1252', { header: true, encoding: 'latin1' }),
    option('encoding/empty-label', encodeText(SAMPLE, 'utf8'), 'an empty label is not auto and is refused', { header: true, encoding: '' }),
    option('encoding/explicit-auto', encodeText(SAMPLE, 'utf16le-bom'), 'auto spelled out', { header: true, encoding: 'auto' }),
    option('encoding/explicit-auto-utf8-bom', encodeText(SAMPLE, 'utf8-bom'), 'a UTF-8 mark under auto', { header: true, encoding: 'auto' }),
    option('encoding/semicolon-windows-1250', Buffer.from('Data;Odbiorca;Kwota\r\n05.01.2026;£ód¿;-12,34\r\n', 'latin1'), 'a Polish file under windows-1250', { header: true, delimiter: ';', encoding: 'windows-1250' }),
    option('encoding/odd-length-utf16', Buffer.from([0xff, 0xfe, 0x61, 0x00, 0x2c, 0x00, 0x62]), 'an odd-length UTF-16LE file', { encoding: 'auto' }),
    option('encoding/lead-surrogate-utf16', Buffer.from([0xff, 0xfe, 0x61, 0x00, 0x3d, 0xd8]), 'a UTF-16LE file ending in a lead surrogate', { encoding: 'auto' }),
    option('encoding/invalid-utf8-explicit', Buffer.from([0x61, 0x2c, 0xc3, 0x28, 0x2c, 0xff, 0x0a]), 'invalid UTF-8 under an explicit label', { encoding: 'utf-8' }),
  );
  return cases;
}

// A random file: a few lines of CSV, possibly with preamble and summary lines, quoted multi-line
// fields and mixed line endings, in a random byte layout under a random label, with random skips.
const TOKENS = ['a', 'b', 'x y', '"q"', '""', '1,2', ';', '  ', '"m\nl"', '"m\r\nl"', '12.34', '-5', 'Café', 'ñ', ''];

function generatedFileText(random, delimiter) {
  const lineCount = between(random, 2, 10);
  const lines = Array.from({ length: lineCount }, () => {
    const cellCount = between(random, 1, 4);
    return Array.from({ length: cellCount }, () => pick(random, TOKENS)).join(delimiter);
  });
  const ending = pick(random, ['\n', '\r\n', '\r', 'mixed']);
  let text = '';
  lines.forEach((line, index) => {
    const separator = ending === 'mixed' ? pick(random, ['\n', '\r\n', '\r']) : ending;
    text += line + (index < lines.length - 1 || chance(random, 0.7) ? separator : '');
  });
  return text;
}

function generatedCases() {
  const random = mulberry32(CSV_OPTION_SEED);
  const skips = [0, 0, 0, 0, 1, 1, 2, 3, -1, -3];
  return Array.from({ length: CSV_OPTION_GENERATED_COUNT }, (_, index) => {
    const delimiter = chance(random, 0.6) ? ',' : pick(random, DELIMITERS);
    const text = generatedFileText(random, delimiter);
    const kind = pick(random, ['utf8', 'utf8', 'utf8-bom', 'utf16le-bom', 'utf16be-bom', 'utf16le', 'utf16be', 'latin1']);
    const data = encodeText(text, kind);
    // Most files are read under a label that suits their bytes; the rest under any label.
    const suited = {
      utf8: ['utf-8', 'auto', undefined], 'utf8-bom': ['utf-8', 'auto', undefined], 'utf16le-bom': ['auto', undefined, 'utf-16le'],
      'utf16be-bom': ['auto', undefined, 'utf-16be'], utf16le: ['utf-16le'], utf16be: ['utf-16be'], latin1: SINGLE_BYTE_LABELS,
    }[kind];
    const encoding = chance(random, 0.75) ? pick(random, suited) : pick(random, [undefined, ...ENCODINGS]);
    const options = { delimiter, header: chance(random, 0.5), skipStart: pick(random, skips), skipEnd: pick(random, skips) };
    if (encoding !== undefined) options.encoding = encoding;
    // Roughly half the files omit a zero skip, as the base cases do.
    if (options.skipStart === 0 && chance(random, 0.5)) delete options.skipStart;
    if (options.skipEnd === 0 && chance(random, 0.5)) delete options.skipEnd;
    return {
      id: `parseCsvRecords/option-gen-${pad(index, 3)}`,
      source: 'generated',
      description: 'seeded small file in a random byte layout, label and line-skip setting',
      seed: CSV_OPTION_SEED,
      input: optionInput(data, options),
    };
  });
}

export function csvFileOptionCases() {
  return [...skipCases(), ...encodingCases(), ...generatedCases()];
}

// Behaviors of the skip and encoding options, in the shape of CSV_PARSE_CHECKLIST.
export const CSV_OPTION_CHECKLIST = [
  ['start skip, LF', 'skip/start-1-lf', input => input.skipStartLines === 1 && input.csv.includes('\n')],
  ['end skip drops the blank last line', 'skip/end-1-lf', input => input.skipEndLines === 1 && input.csv.endsWith('\n')],
  ['trailing newline counts as a line (error)', 'skip/trailing-newline-counts-total', input => input.csv === 'a,b\nc,d\n' && input.skipStartLines + input.skipEndLines === 3],
  ['skip totals equal to the line count (error)', 'skip/sum-equals-count', input => input.skipStartLines + input.skipEndLines === 3],
  ['skip above the line count (error)', 'skip/start-above-count', input => input.skipStartLines === 9],
  ['lone CR is not a line break', 'skip/lone-cr-is-one-line', input => !input.csv.includes('\n') && input.csv.includes('\r')],
  ['CRLF endings', 'skip/start-1-crlf', input => input.csv.includes('\r\n')],
  ['negative skips read as zero', 'skip/negative-both', input => input.skipStartLines < 0 && input.skipEndLines < 0],
  ['rejoining rewrites a quoted LF', 'skip/rejoin-rewrites-quoted-lf', input => input.csv.includes('"a\nb"') && input.skipStartLines === 1],
  ['no skip keeps a quoted LF', 'skip/no-skip-keeps-quoted-lf', input => input.skipStartLines === undefined],
  ['skip cuts into a quoted field', 'skip/cut-into-quoted-start', input => input.csv.includes('"a\nb"') && input.skipStartLines === 2],
  ['end skip cuts through a quoted field (error)', 'skip/cut-through-quoted-end', input => input.csv.includes('"a\nb"') && input.skipEndLines === 3],
  ['empty file with a skip (error)', 'skip/empty-file', input => input.csv === '' && input.skipStartLines === 1],
  ['skip with a header row', 'skip/start-1-lf-header', input => input.hasHeaderRow && input.skipStartLines === 1],
  ['encoding: UTF-16LE with a mark under auto', 'encoding/utf16le-bom/auto', input => input.encoding === 'auto' && Buffer.from(input.bytesBase64, 'base64')[0] === 0xff],
  ['encoding: UTF-16BE with a mark under auto', 'encoding/utf16be-bom/auto', input => input.encoding === 'auto' && Buffer.from(input.bytesBase64, 'base64')[0] === 0xfe],
  ['encoding: windows-1252 bytes', 'encoding/latin1/windows-1252', input => input.encoding === 'windows-1252'],
  ['encoding: windows-1250 bytes', 'encoding/latin1/windows-1250', input => input.encoding === 'windows-1250'],
  ['encoding: iso-8859-2 bytes', 'encoding/latin1/iso-8859-2', input => input.encoding === 'iso-8859-2'],
  ['encoding: unsupported label', 'encoding/unsupported-label', input => input.encoding === 'klingon'],
  ['encoding: skip on a decoded UTF-16 file', 'encoding/skip-utf16le-bom', input => input.skipStartLines === 1],
];
