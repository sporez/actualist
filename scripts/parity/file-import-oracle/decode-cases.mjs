// Cases for `decodeCsvBytes`, the module-private decoder in parse-file.ts that turns the bytes of
// a CSV file into text. Pure data: no expected output lives here.
//
// Input: { bytesBase64, encoding } where `encoding` may be absent (the function's default,
// 'auto'). Output (from the oracle): { text } or { error } holding the message of the error
// TextDecoder threw, which only an unsupported label causes: decoding itself never throws.
// The message text is Node's; a port only needs to know that the label is refused.
import { mulberry32 } from '../sync-merkle/cases.mjs';
import { base64, between, chance, named, pad, pick } from './case-kit.mjs';

export const DECODE_SEED = 20261109 + 9;
export const DECODE_GENERATED_COUNT = 300;

// The modal's encoding list, in the order it offers them.
export const MODAL_ENCODINGS = ['auto', 'utf-8', 'utf-16le', 'utf-16be', 'windows-1252', 'windows-1250', 'iso-8859-2'];
const SINGLE_BYTE = ['windows-1252', 'windows-1250', 'iso-8859-2'];
// Labels the modal does not offer, but that a saved preference could hold.
const OTHER_LABELS = ['latin1', 'UTF-8', ' utf-8 ', 'klingon', 'utf8', 'ascii', 'iso-8859-1', 'utf-16', '', 'AUTO',
  'Windows-1252', 'cp1252', 'ISO-8859-2', 'latin2', 'ucs-2', 'iso-8859-15', 'utf-32'];

const slug = label => (label === '' ? 'empty' : label.replaceAll(' ', '_'));
const hex = data => [...data].map(byte => byte.toString(16).padStart(2, '0')).join('');

function bytesCase(id, data, encoding, description) {
  const input = { bytesBase64: base64(data) };
  if (encoding !== undefined) input.encoding = encoding;
  return named(`decodeCsvBytes/${id}`, input, description);
}

const range = (from, to) => Array.from({ length: to - from + 1 }, (_, index) => from + index);
const utf16le = text => [...Buffer.from(text, 'utf16le')];
const utf16be = text => [...Buffer.from(text, 'utf16le').swap16()];
const ascii = text => [...Buffer.from(text, 'latin1')];

const BOMS = [
  ['none', []],
  ['utf8', [0xef, 0xbb, 0xbf]],
  ['le', [0xff, 0xfe]],
  ['be', [0xfe, 0xff]],
  ['utf8-twice', [0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf]],
  ['le-twice', [0xff, 0xfe, 0xff, 0xfe]],
  ['be-twice', [0xfe, 0xff, 0xfe, 0xff]],
  ['utf8-then-le', [0xef, 0xbb, 0xbf, 0xff, 0xfe]],
  ['le-then-utf8', [0xff, 0xfe, 0xef, 0xbb, 0xbf]],
  ['be-then-utf8', [0xfe, 0xff, 0xef, 0xbb, 0xbf]],
  ['le-then-be', [0xff, 0xfe, 0xfe, 0xff]],
  ['half-le', [0xff]],
  ['half-be', [0xfe]],
];
const PAYLOADS = [
  ['ascii', ascii('a,b\n')],
  ['utf16le', utf16le('a,b\n')],
  ['utf16be', utf16be('a,b\n')],
];

function allBytesCases() {
  const cases = [];
  for (const encoding of [...MODAL_ENCODINGS, 'latin1']) {
    cases.push(
      bytesCase(`all-bytes/${slug(encoding)}`, range(0, 255), encoding, `every byte 0x00-0xFF in order, as ${encoding}`),
      bytesCase(`all-bytes-reversed/${slug(encoding)}`, range(0, 255).reverse(), encoding, `every byte 0xFF-0x00, as ${encoding}`),
    );
  }
  // One lone high byte between ASCII letters, so each decodes (or is replaced) on its own.
  for (const encoding of ['auto', 'utf-8', ...SINGLE_BYTE]) {
    const data = range(0x80, 0xff).flatMap(byte => [0x61, byte, 0x62]);
    cases.push(bytesCase(`lone-high-bytes/${slug(encoding)}`, data, encoding, `each byte 0x80-0xFF between a and b, as ${encoding}`));
  }
  cases.push(
    bytesCase('windows-1252/c1-holes', [0x81, 0x8d, 0x8f, 0x90, 0x9d], 'windows-1252',
      'the five bytes windows-1252 leaves undefined; WHATWG decodes them as C1 controls'),
    bytesCase('windows-1252/sample-row', [...ascii('Date;Betrag;Zahler\n05.01.2026;12,50;Caf'), 0xe9, ...ascii(' '), 0x80, ...ascii(' '), 0x93, ...ascii('x'), 0x94, 0x0a],
      'windows-1252', 'a German bank row with an accent, the euro sign and curly quotes'),
    bytesCase('windows-1250/sample-row', [...ascii('Data;Kwota;Odbiorca\n05.01.2026;12,50;'), 0xa3, 0xf3, 0x64, 0xbf, ...ascii(' '), 0x8a, 0x9c, 0x9f, 0x0a],
      'windows-1250', 'a Polish row with letters that differ from ISO-8859-2'),
    bytesCase('iso-8859-2/sample-row', [...ascii('Data;Kwota;Odbiorca\n05.01.2026;12,50;'), 0xa3, 0xf3, 0x64, 0xbf, ...ascii(' '), 0xa6, 0xb6, 0xac, 0x0a],
      'iso-8859-2', 'the same row in ISO-8859-2'),
  );
  return cases;
}

// Invalid and edge-case UTF-8 sequences, each between ASCII so replacement runs are visible.
const UTF8_SEQUENCES = [
  ['valid-2', [0xc2, 0xa9]],
  ['valid-3-min', [0xe0, 0xa0, 0x80]],
  ['valid-4', [0xf0, 0x9f, 0x98, 0x80]],
  ['valid-4-max', [0xf4, 0x8f, 0xbf, 0xbf]],
  ['noncharacter-fffe', [0xef, 0xbf, 0xbe]],
  ['noncharacter-ffff', [0xef, 0xbf, 0xbf]],
  ['nul', [0x00]],
  ['overlong-2-c0', [0xc0, 0x80]],
  ['overlong-2-c1', [0xc1, 0xbf]],
  ['overlong-3-e0', [0xe0, 0x80, 0x80]],
  ['overlong-3-e0-9f', [0xe0, 0x9f, 0xbf]],
  ['overlong-4-f0', [0xf0, 0x80, 0x80, 0x80]],
  ['overlong-4-f0-8f', [0xf0, 0x8f, 0xbf, 0xbf]],
  ['surrogate-low-bound', [0xed, 0xa0, 0x80]],
  ['surrogate-high-bound', [0xed, 0xbf, 0xbf]],
  ['above-10ffff', [0xf4, 0x90, 0x80, 0x80]],
  ['lead-f5', [0xf5, 0x80, 0x80, 0x80]],
  ['lead-f8', [0xf8, 0x88, 0x80, 0x80, 0x80]],
  ['byte-fe', [0xfe]],
  ['byte-ff', [0xff]],
  ['continuation-alone', [0x80]],
  ['continuation-bf', [0xbf]],
  ['two-continuations', [0x80, 0x80]],
  ['lead-2-truncated', [0xc2]],
  ['lead-2-then-ascii', [0xc2, 0x41]],
  ['lead-3-truncated-1', [0xe2]],
  ['lead-3-truncated-2', [0xe2, 0x82]],
  ['lead-3-truncated-2-ascii', [0xe2, 0x82, 0x41]],
  ['lead-3-then-ascii', [0xe2, 0x41]],
  ['lead-4-truncated-1', [0xf0]],
  ['lead-4-truncated-2', [0xf0, 0x9f]],
  ['lead-4-truncated-3', [0xf0, 0x9f, 0x98]],
  ['lead-4-truncated-3-ascii', [0xf0, 0x9f, 0x98, 0x41]],
  ['lead-4-then-ascii', [0xf0, 0x9f, 0x41]],
  ['e0-then-low-continuation', [0xe0, 0x80]],
  ['ed-then-a0', [0xed, 0xa0]],
  ['f4-then-90', [0xf4, 0x90]],
  ['f0-then-8f', [0xf0, 0x8f]],
  ['lead-2-then-lead-2', [0xc2, 0xc2, 0xa9]],
  ['lead-3-then-lead-3', [0xe2, 0xe2, 0x82, 0xac]],
  ['lead-then-valid-4', [0xe2, 0xf0, 0x9f, 0x98, 0x80]],
  ['valid-then-continuation', [0xc2, 0xa9, 0x80]],
];

function utf8Cases() {
  const cases = [];
  for (const [name, sequence] of UTF8_SEQUENCES) {
    const data = [0x61, ...sequence, 0x62];
    cases.push(
      bytesCase(`utf8/${name}`, data, 'utf-8', `a ${name} sequence between a and b, utf-8`),
      bytesCase(`utf8-auto/${name}`, data, 'auto', `a ${name} sequence between a and b, auto`),
      bytesCase(`utf8-end/${name}`, [0x61, ...sequence], 'utf-8', `a ${name} sequence at the end of the input, utf-8`),
    );
  }
  cases.push(
    bytesCase('utf8/valid-text', [...Buffer.from('Café ñ € 😀 日本語\n', 'utf8')], 'auto', 'valid multi-byte text'),
    bytesCase('utf8/combining-and-nfc', [...Buffer.from('é é\n', 'utf8')], 'utf-8', 'decomposed and precomposed accents stay as written'),
  );
  return cases;
}

function bomCases() {
  const cases = [];
  for (const encoding of MODAL_ENCODINGS) {
    for (const [bomName, bom] of BOMS) {
      for (const [payloadName, payload] of PAYLOADS) {
        cases.push(bytesCase(`bom/${slug(encoding)}/${bomName}/${payloadName}`, [...bom, ...payload], encoding,
          `bytes ${bomName} byte order marks then ${payloadName} text, decoded as ${encoding}`));
      }
      if (bom.length > 0) {
        cases.push(bytesCase(`bom/${slug(encoding)}/${bomName}/only`, bom, encoding, `only the ${bomName} mark, decoded as ${encoding}`));
      }
    }
  }
  return cases;
}

function utf16Cases() {
  const cases = [];
  const lead = 0xd83d;
  const trail = 0xde00;
  const unit = (value, big) => (big ? [value >> 8, value & 0xff] : [value & 0xff, value >> 8]);
  for (const [encoding, big] of [['utf-16le', false], ['utf-16be', true]]) {
    const u = value => unit(value, big);
    const a = u(0x61);
    const sequences = [
      ['lead-alone', [...u(lead)]],
      ['lead-after-text', [...a, ...u(lead)]],
      ['lead-then-ascii', [...u(lead), ...a]],
      ['lead-then-odd-byte', [...u(lead), 0x41]],
      ['lead-then-odd-byte-after-text', [...a, ...u(lead), 0x41]],
      ['lead-then-lead', [...u(lead), ...u(lead)]],
      ['lead-then-lead-then-trail', [...u(lead), ...u(lead), ...u(trail)]],
      ['lead-then-trail', [...u(lead), ...u(trail)]],
      ['lead-then-trail-odd-byte', [...u(lead), ...u(trail), 0x41]],
      ['trail-alone', [...u(trail)]],
      ['trail-then-lead', [...u(trail), ...u(lead)]],
      ['trail-then-trail', [...u(trail), ...u(trail)]],
      ['trail-then-lead-then-trail', [...u(trail), ...u(lead), ...u(trail)]],
      ['lead-then-bmp-then-trail', [...u(lead), ...a, ...u(trail)]],
      ['boundary-d7ff', [...u(0xd7ff)]],
      ['boundary-e000', [...u(0xe000)]],
      ['boundary-dbff-dc00', [...u(0xdbff), ...u(0xdc00)]],
      ['boundary-d800-dfff', [...u(0xd800), ...u(0xdfff)]],
      ['noncharacters', [...u(0xfffe), ...u(0xffff), ...u(0xfdd0)]],
      ['nul', [...a, ...u(0), ...a]],
      ['odd-lone-byte', [0x61]],
      ['odd-after-one-unit', [...a, 0x62]],
      ['odd-after-two-units', [...a, ...a, 0x62]],
      ['odd-high-byte', [...a, 0xff]],
      ['valid-text', [...a, ...u(0x2c), ...u(0x20ac), ...u(0x0a)]],
    ];
    for (const [name, data] of sequences) {
      cases.push(bytesCase(`utf16/${encoding}/${name}`, data, encoding, `${name}, as ${encoding}`));
    }
  }
  // The same sequences read through a byte order mark with auto.
  const leadLE = [0x3d, 0xd8];
  const leadBE = [0xd8, 0x3d];
  cases.push(
    bytesCase('utf16/auto-le-lead-alone', [0xff, 0xfe, ...leadLE], 'auto', 'auto, little-endian mark, lead surrogate at the end'),
    bytesCase('utf16/auto-le-lead-odd', [0xff, 0xfe, ...leadLE, 0x41], 'auto', 'auto, little-endian mark, lead surrogate then an odd byte'),
    bytesCase('utf16/auto-le-odd', [0xff, 0xfe, 0x61, 0x00, 0x62], 'auto', 'auto, little-endian mark, odd length'),
    bytesCase('utf16/auto-be-lead-alone', [0xfe, 0xff, ...leadBE], 'auto', 'auto, big-endian mark, lead surrogate at the end'),
    bytesCase('utf16/auto-be-odd', [0xfe, 0xff, 0x00, 0x61, 0x62], 'auto', 'auto, big-endian mark, odd length'),
    bytesCase('utf16/auto-le-mark-only-odd', [0xff, 0xfe, 0x41], 'auto', 'auto, little-endian mark and one stray byte'),
    bytesCase('utf16/auto-le-text', [0xff, 0xfe, ...utf16le('Date,Café\r\n2026-01-05,1\r\n')], 'auto', 'auto, little-endian text'),
    bytesCase('utf16/auto-be-text', [0xfe, 0xff, ...utf16be('Date,Café\r\n2026-01-05,1\r\n')], 'auto', 'auto, big-endian text'),
    bytesCase('utf16/auto-no-mark-le', utf16le('Date,Amount\r\n'), 'auto', 'UTF-16LE text without a mark is read as UTF-8, NULs included'),
    bytesCase('utf16/auto-no-mark-be', utf16be('Date,Amount\r\n'), 'auto', 'UTF-16BE text without a mark is read as UTF-8'),
    bytesCase('utf16/le-text-as-be', [0xff, 0xfe, ...utf16le('ab')], 'utf-16be', 'little-endian bytes with their mark read as big-endian'),
    bytesCase('utf16/be-text-as-le', [0xfe, 0xff, ...utf16be('ab')], 'utf-16le', 'big-endian bytes with their mark read as little-endian'),
  );
  return cases;
}

function emptyAndLabelCases() {
  const cases = [];
  for (const encoding of [...MODAL_ENCODINGS, ...OTHER_LABELS]) {
    cases.push(bytesCase(`empty/${slug(encoding)}`, [], encoding, `no bytes, label ${JSON.stringify(encoding)}`));
  }
  const sample = [0x63, 0x61, 0x66, 0xe9, 0x0a, 0x80, 0x9f, 0xa4, 0xff];
  const withMark = [0xff, 0xfe, 0x61, 0x00, 0x0a, 0x00];
  for (const label of OTHER_LABELS) {
    cases.push(
      bytesCase(`label/${slug(label)}`, sample, label, `high bytes under the label ${JSON.stringify(label)}`),
      bytesCase(`label-bom/${slug(label)}`, withMark, label, `a little-endian mark under the label ${JSON.stringify(label)}`),
    );
  }
  cases.push(
    bytesCase('omitted-encoding/utf8', [...Buffer.from('a,é\n', 'utf8')], undefined, 'no encoding argument: the default is auto'),
    bytesCase('omitted-encoding/le', withMark, undefined, 'no encoding argument, little-endian mark'),
    bytesCase('omitted-encoding/be', [0xfe, 0xff, 0x00, 0x61], undefined, 'no encoding argument, big-endian mark'),
  );
  return cases;
}

// Seeded byte strings from an alphabet weighted toward marks, surrogate halves, UTF-8 lead and
// continuation bytes, and the ASCII CSV characters, under every modal label.
const SPECIAL = [0xff, 0xfe, 0xef, 0xbb, 0xbf, 0xd8, 0xdb, 0xdc, 0xdf, 0xc0, 0xc2, 0xe0, 0xed, 0xf0, 0xf4, 0xf5, 0x80, 0xbf, 0x00, 0x81, 0x9d, 0xa0, 0xb1, 0xe9];
const TEXTUAL = [0x61, 0x62, 0x2c, 0x22, 0x0a, 0x0d, 0x20, 0x31];

function generatedCases() {
  const random = mulberry32(DECODE_SEED);
  return Array.from({ length: DECODE_GENERATED_COUNT }, (_, index) => {
    const length = chance(random, 0.1) ? 0 : between(random, 1, 40);
    const data = [];
    if (chance(random, 0.3)) data.push(...pick(random, BOMS)[1]);
    while (data.length < length) data.push(chance(random, 0.55) ? pick(random, SPECIAL) : pick(random, TEXTUAL));
    const encoding = chance(random, 0.1) ? undefined : pick(random, MODAL_ENCODINGS);
    const input = { bytesBase64: base64(data) };
    if (encoding !== undefined) input.encoding = encoding;
    return {
      id: `decodeCsvBytes/gen-${pad(index, 3)}`,
      source: 'generated',
      description: 'seeded bytes from an alphabet weighted toward marks, surrogate halves and UTF-8 lead bytes',
      seed: DECODE_SEED,
      input,
    };
  });
}

export function decodeCsvBytesCases() {
  return [
    ...allBytesCases(),
    ...utf8Cases(),
    ...bomCases(),
    ...utf16Cases(),
    ...emptyAndLabelCases(),
    ...generatedCases(),
  ];
}

// One entry per behavior of decodeCsvBytes and TextDecoder that a port must reproduce: the label,
// the case that shows it, and a test of that case's input. The plan refuses an entry whose case
// is missing or whose input does not show the behavior.
const bytesOf = input => Buffer.from(input.bytesBase64, 'base64');
export const DECODE_CHECKLIST = [
  ['auto: little-endian mark picks UTF-16LE', 'bom/auto/le/utf16le', input => bytesOf(input).subarray(0, 2).equals(Buffer.from([0xff, 0xfe]))],
  ['auto: big-endian mark picks UTF-16BE', 'bom/auto/be/utf16be', input => bytesOf(input).subarray(0, 2).equals(Buffer.from([0xfe, 0xff]))],
  ['auto: no mark is UTF-8', 'utf16/auto-no-mark-le', input => bytesOf(input)[0] !== 0xff && input.encoding === 'auto'],
  ['auto: UTF-8 mark is stripped', 'bom/auto/utf8/ascii', input => bytesOf(input)[0] === 0xef],
  ['auto: a second mark stays', 'bom/auto/utf8-twice/ascii', input => bytesOf(input).length === 10],
  ['auto: one 0xFF byte is not a mark', 'bom/auto/half-le/ascii', input => bytesOf(input)[0] === 0xff && bytesOf(input)[1] === 0x61],
  ['explicit label wins over a mark', 'bom/utf-8/le/utf16le', input => input.encoding === 'utf-8' && bytesOf(input)[0] === 0xff],
  ['explicit UTF-16LE strips its own mark', 'bom/utf-16le/le/utf16le', input => input.encoding === 'utf-16le'],
  ['explicit UTF-16LE with the big-endian mark', 'bom/utf-16le/be/utf16be', input => input.encoding === 'utf-16le' && bytesOf(input)[0] === 0xfe],
  ['explicit single-byte label with a UTF-8 mark', 'bom/windows-1252/utf8/ascii', input => input.encoding === 'windows-1252' && bytesOf(input)[0] === 0xef],
  ['omitted encoding means auto', 'omitted-encoding/le', input => input.encoding === undefined],
  ['windows-1252 table', 'all-bytes/windows-1252', input => bytesOf(input).length === 256],
  ['windows-1252 undefined bytes', 'windows-1252/c1-holes', input => bytesOf(input).includes(0x81)],
  ['windows-1250 table', 'all-bytes/windows-1250', input => bytesOf(input).length === 256],
  ['iso-8859-2 table', 'all-bytes/iso-8859-2', input => bytesOf(input).length === 256],
  ['latin1 is windows-1252', 'all-bytes/latin1', input => input.encoding === 'latin1'],
  ['uppercase UTF-8 label', 'label/UTF-8', input => input.encoding === 'UTF-8'],
  ['padded label', 'label/_utf-8_', input => input.encoding === ' utf-8 '],
  ['unsupported label', 'label/klingon', input => input.encoding === 'klingon'],
  ['empty label', 'label/empty', input => input.encoding === ''],
  ['AUTO is not auto', 'label/AUTO', input => input.encoding === 'AUTO'],
  ['UTF-8: lone continuation byte', 'utf8/continuation-alone', input => bytesOf(input).includes(0x80)],
  ['UTF-8: overlong', 'utf8/overlong-3-e0', input => bytesOf(input).includes(0xe0)],
  ['UTF-8: encoded surrogate', 'utf8/surrogate-low-bound', input => bytesOf(input).includes(0xed)],
  ['UTF-8: above U+10FFFF', 'utf8/above-10ffff', input => bytesOf(input).includes(0xf4)],
  ['UTF-8: truncated sequence at the end', 'utf8-end/lead-4-truncated-3', input => bytesOf(input).at(-1) === 0x98],
  ['UTF-8: truncated sequence then ASCII', 'utf8/lead-3-truncated-2-ascii', input => bytesOf(input).includes(0x82)],
  ['UTF-16: lead surrogate at the end', 'utf16/utf-16le/lead-alone', input => bytesOf(input).length === 2],
  ['UTF-16: lead surrogate then an odd byte', 'utf16/utf-16le/lead-then-odd-byte', input => bytesOf(input).length === 3],
  ['UTF-16: lone trail surrogate', 'utf16/utf-16le/trail-alone', input => bytesOf(input).length === 2],
  ['UTF-16: odd length', 'utf16/utf-16le/odd-after-two-units', input => bytesOf(input).length === 5],
  ['UTF-16BE: lead surrogate at the end', 'utf16/utf-16be/lead-alone', input => bytesOf(input).length === 2],
  ['empty input', 'empty/utf-8', input => bytesOf(input).length === 0],
];

export function checkDecodeChecklist(cases) {
  const byId = new Map(cases.map(planCase => [planCase.id, planCase]));
  for (const [label, caseId, shows] of DECODE_CHECKLIST) {
    const planCase = byId.get(`decodeCsvBytes/${caseId}`);
    if (!planCase) throw new Error(`decode checklist: no case ${caseId} for ${label}`);
    if (!shows(planCase.input)) throw new Error(`decode checklist: ${caseId} does not exercise ${label}`);
  }
}
