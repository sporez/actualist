// Helpers shared by the case builders: seeded draws, CSV text, and the looselyParseAmount-style
// amount alphabet. Pure data; nothing here holds an expected output.

export function named(id, input, description) {
  return { id, source: 'named', description, input };
}

export const pad = (index, width = 4) => String(index + 1).padStart(width, '0');
export const pick = (random, list) => list[Math.floor(random() * list.length)];
export const chance = (random, probability) => random() < probability;
export const between = (random, low, high) => low + Math.floor(random() * (high - low + 1));

export function digits(random, count) {
  let text = '';
  for (let index = 0; index < count; index += 1) text += String(Math.floor(random() * 10));
  return text;
}

export const CURRENCY_BEFORE = ['', '', '$', '€', '£', '¥', 'USD ', 'CHF ', 'US$', 'R$ ', ' $'];
export const CURRENCY_AFTER = ['', '', '', ' USD', '€', ' kr', ' zł', ' €', ' CR', 'DR'];
export const GROUPS = [',', '.', "'", ' ', ' ', ' ', ' ', ''];
export const DECIMALS = ['.', ',', '.', ','];
export const PAD_CHARS = [' ', '\t', '\n', ' ', '﻿', ' ', ' ', '　', '\u0085', '​', '᠎', ' '];
export const ALT_DIGITS = ['٠١٢٣٤٥٦٧٨٩', '０１２３４５６７８９', '²³¹⁴', '१२३'];

export function groupedInteger(random, integer, group) {
  if (group === '' || integer.length <= 3) return integer;
  return integer.replace(/\B(?=(\d{3})+(?!\d))/g, group);
}

export function generatedAmount(random) {
  const integerLength = chance(random, 0.04) ? between(random, 14, 40) : between(random, 0, 12);
  let integer = digits(random, integerLength);
  if (chance(random, 0.08) && integer.length > 0) {
    const alternative = pick(random, ALT_DIGITS);
    const at = between(random, 0, integer.length - 1);
    integer = integer.slice(0, at) + alternative[between(random, 0, alternative.length - 1)] + integer.slice(at + 1);
  }
  integer = groupedInteger(random, integer, pick(random, GROUPS));
  const decimal = pick(random, DECIMALS);
  const fractionLength = chance(random, 0.5) ? between(random, 0, 3) : between(random, 0, 12);
  const fraction = chance(random, 0.75) ? decimal + digits(random, fractionLength) : '';
  let text = `${pick(random, CURRENCY_BEFORE)}${integer}${fraction}${pick(random, CURRENCY_AFTER)}`;
  const style = between(random, 0, 11);
  if (style === 0) text = `-${text}`;
  else if (style === 1) text = `−${text}`;
  else if (style === 2) text = `${text}-`;
  else if (style === 3) text = `(${text})`;
  else if (style === 4) text = `(−${text})`;
  else if (style === 5) text = `--${text}`;
  else if (style === 6) text = `${text}−`;
  else if (style === 7) text = `(${text}`;
  if (chance(random, 0.15)) text = `${text}${pick(random, ['x', 'ab', ' CR', 'e5', 'E-3', '+'])}`;
  if (chance(random, 0.1)) text = `${pick(random, ['e', 'Total ', 'net '])}${text}`;
  if (chance(random, 0.25)) {
    const left = pick(random, PAD_CHARS).repeat(between(random, 1, 2));
    const right = chance(random, 0.6) ? pick(random, PAD_CHARS) : '';
    text = `${left}${text}${right}`;
  }
  return text;
}

export function csvField(value) {
  if (/[",\r\n]/.test(value)) return `"${value.replaceAll('"', '""')}"`;
  return value;
}

export function csvText(rows, { newline = '\r\n', trailing = true } = {}) {
  const body = rows.map(row => row.map(csvField).join(',')).join(newline);
  return trailing ? body + newline : body;
}


export const table = (header, rows, options) => csvText(header ? [header, ...rows] : rows, options);

// Text as file bytes. `latin1` writes one byte per character (code points up to U+00FF), which
// the single-byte encodings then read through their own tables.
export function encodeText(text, kind) {
  const utf16le = () => Buffer.from(text, 'utf16le');
  const utf16be = () => { const bytes = utf16le(); bytes.swap16(); return bytes; };
  switch (kind) {
    case 'utf8': return Buffer.from(text, 'utf8');
    case 'utf8-bom': return Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from(text, 'utf8')]);
    case 'utf16le': return utf16le();
    case 'utf16le-bom': return Buffer.concat([Buffer.from([0xff, 0xfe]), utf16le()]);
    case 'utf16be': return utf16be();
    case 'utf16be-bom': return Buffer.concat([Buffer.from([0xfe, 0xff]), utf16be()]);
    case 'latin1': return Buffer.from(text, 'latin1');
    default: throw new Error(`unknown file encoding kind ${kind}`);
  }
}

export const base64 = data => Buffer.from(data).toString('base64');

// Rows as delimited text with CSV quoting for fields holding the delimiter, a quote or a line break.
export function delimitedText(rows, delimiter, { newline = '\r\n', trailing = true } = {}) {
  const field = value => (value.includes(delimiter) || /["\r\n]/.test(value) ? `"${value.replaceAll('"', '""')}"` : value);
  const body = rows.map(row => row.map(field).join(delimiter)).join(newline);
  return trailing ? body + newline : body;
}
