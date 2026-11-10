// Cases for `parseCsvRecords`: Actual's real parseFile -> parseCSV -> csv-parse
// (7.0.3) on the option set Actual passes (bom, quote '"', trim, relax_column_count,
// skip_empty_lines, delimiter, columns: hasHeaderRow). Pure data, like cases.mjs:
// no expected output lives here.
//
// Input: { csv, delimiter, hasHeaderRow } or { bytesBase64, delimiter, hasHeaderRow }
// (raw file bytes, for byte order marks and invalid UTF-8), plus the optional file options
// skipStartLines, skipEndLines and encoding (defaults 0, 0 and 'auto'; cases for them are in
// csv-file-option-cases.mjs). The modal only offers the single-character delimiters
// , ; | tab ~, so those are the only ones used.

import { mulberry32 } from '../sync-merkle/cases.mjs';
import { CSV_OPTION_CHECKLIST, csvFileOptionCases } from './csv-file-option-cases.mjs';

const DELIMITERS = [',', ';', '|', '\t', '~'];
const SEED = 20261109 + 8;
export const CSV_PARSE_GENERATED_COUNT = 1500;
export const CSV_PARSE_SEED = SEED;

const text = (id, csv, description, { delimiter = ',', header = false } = {}) => ({
  id: `parseCsvRecords/${id}`,
  source: 'named',
  description,
  input: { csv, delimiter, hasHeaderRow: header },
});

const bytes = (id, data, description, { delimiter = ',', header = false } = {}) => ({
  id: `parseCsvRecords/${id}`,
  source: 'named',
  description,
  input: { bytesBase64: Buffer.from(data).toString('base64'), delimiter, hasHeaderRow: header },
});

const codePoint = value => `U+${value.toString(16).toUpperCase().padStart(4, '0')}`;

// Whitespace csv-parse trims (its timchars list) and near misses it does not.
const TRIMMED = [0x20, 0x09, 0x0b, 0x0c, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
  0x2007, 0x2008, 0x2009, 0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff];
const NOT_TRIMMED = [0x200b, 0x200c, 0x200d, 0x2060, 0x180e, 0x85, 0x1c, 0x1f, 0x00, 0xad, 0x2800];
const ALL_SPACES = [...TRIMMED, ...NOT_TRIMMED];

function trimCases() {
  const cases = [];
  for (const value of ALL_SPACES) {
    const ch = String.fromCodePoint(value);
    const label = codePoint(value);
    cases.push(
      text(`trim/unquoted-${label}`, `${ch}a${ch},${ch}b c${ch}\n`, `${label} around unquoted fields`),
      text(`trim/quoted-around-${label}`, `${ch}"a"${ch},${ch}"b c"${ch}\n`, `${label} before an opening and after a closing quote`),
      text(`trim/quoted-inside-${label}`, `"${ch}a${ch}","${ch}${ch}"\n`, `${label} inside quotes`),
      text(`trim/only-${label}`, `${ch}${ch},${ch}\n${ch}\nx,y\n`, `fields and a line holding only ${label}`),
      text(`trim/header-${label}`, `${ch}h1${ch},${ch}h2\n1,2\n`, `${label} around header names`, { header: true }),
    );
  }
  return cases;
}

const LINE_ENDING_NAMES = [['lf', '\n'], ['crlf', '\r\n'], ['cr', '\r']];

function lineEndingCases() {
  const cases = [];
  for (const [name, ending] of LINE_ENDING_NAMES) {
    cases.push(
      text(`endings/${name}`, `a,b${ending}c,d${ending}e,f${ending}`, `${name} record delimiter with a trailing one`),
      text(`endings/${name}-no-trailing`, `a,b${ending}c,d`, `${name} record delimiter, no trailing one`),
      text(`endings/${name}-double-trailing`, `a,b${ending}c,d${ending}${ending}`, `${name} with a blank line at the end`),
      text(`endings/${name}-header`, `h1,h2${ending}1,2${ending}3,4${ending}`, `${name} with a header row`, { header: true }),
      text(`endings/${name}-quoted-newlines`, `"a\nb","c\r\nd"${ending}"e\rf",g${ending}`, `${name} with every ending kind inside quotes`),
    );
  }
  // The first ending seen decides the record delimiter; other endings later stay in the
  // field (and trailing ones are trimmed from unquoted fields).
  for (const [firstName, first] of LINE_ENDING_NAMES) {
    for (const [secondName, second] of LINE_ENDING_NAMES) {
      if (firstName === secondName) continue;
      cases.push(
        text(`endings/mixed-${firstName}-then-${secondName}`, `a,b${first}c,d${second}e,f${first}g,h${second}`,
          `first ending ${firstName}, then ${secondName} and ${firstName} alternating`),
        text(`endings/mixed-${firstName}-then-${secondName}-inline`, `a,b${first}c ${second}x,d${second}${second}e${first}`,
          `first ending ${firstName}; ${secondName} mid-field and doubled`),
        text(`endings/mixed-${firstName}-then-${secondName}-header`, `h1,h2${first}1,2${second}3,4${first}`,
          `header row, first ending ${firstName}, then ${secondName}`, { header: true }),
      );
    }
  }
  cases.push(
    text('endings/lone-cr-in-unquoted-after-lf', 'a\rb,c\nd,e\n', 'a CR inside an unquoted field once LF is the record delimiter'),
    text('endings/lone-lf-in-unquoted-after-crlf', 'a\nb,c\r\nd,e\r\n', 'an LF inside an unquoted field once CRLF is the record delimiter'),
    text('endings/cr-then-lf-pair-after-cr', 'a,b\r\nc,d\r', 'CR first, so CRLF is a record end followed by an LF-only record'),
    text('endings/crlf-then-lone-cr-at-end', 'a,b\r\nc,d\r', 'CRLF first, trailing lone CR'),
    text('endings/lf-then-crlf-at-end', 'a,b\nc,d\r\n', 'LF first, trailing CRLF'),
    text('endings/no-ending-single-record', 'a,b,c', 'one record, no ending'),
    text('endings/cr-after-quote', '"a"\r"b"\r', 'CR record delimiter right after a closing quote'),
    text('endings/lf-after-crlf-quote', '"a"\r\n"b"\n"c"\r\n', 'LF after a closing quote when CRLF came first'),
    text('endings/ls-ps-not-record-ends', 'a\u2028b,c\u2029d\n', 'U+2028 and U+2029 are never record delimiters'),
    text('endings/nel-not-record-end', 'a\u0085b,c\nd,e\n', 'U+0085 is not a record delimiter'),
  );
  return cases;
}

function blankLineCases() {
  const options = { header: false };
  const headerOptions = { header: true };
  return [
    text('blank/middle', 'a,b\n\nc,d\n', 'an empty line between records'),
    text('blank/leading', '\n\na,b\n', 'empty lines before the first record'),
    text('blank/leading-header', '\n\nh1,h2\n1,2\n', 'empty lines before the header row', headerOptions),
    text('blank/after-header', 'h1,h2\n\n\n1,2\n', 'empty lines after the header row', headerOptions),
    text('blank/crlf-middle', 'a,b\r\n\r\n\r\nc,d\r\n', 'empty lines in a CRLF file'),
    text('blank/cr-middle', 'a,b\r\r\rc,d\r', 'empty lines in a CR file'),
    text('blank/spaces-only-line', 'a,b\n   \nc,d\n', 'a line of spaces between records'),
    text('blank/tab-only-line', 'a,b\n\t\t\nc,d\n', 'a line of tabs between records'),
    text('blank/nbsp-only-line', 'a,b\n\u00a0\u00a0\nc,d\n', 'a line of NBSP between records'),
    text('blank/em-space-only-line', 'a,b\n\u2003\n\u3000\nc,d\n', 'lines of U+2003 and U+3000'),
    text('blank/bom-char-only-line', 'a,b\n\ufeff\nc,d\n', 'a line holding only U+FEFF'),
    text('blank/zwsp-only-line', 'a,b\n\u200b\nc,d\n', 'a line holding only U+200B (not trimmed)'),
    text('blank/spaces-only-line-header', 'h1,h2\n   \n1,2\n', 'whitespace-only line after a header row', headerOptions),
    text('blank/spaces-only-line-crlf', 'a,b\r\n  \r\nc,d\r\n', 'whitespace-only line in a CRLF file'),
    text('blank/spaces-only-first-line', '   \na,b\n', 'whitespace-only first line'),
    text('blank/spaces-only-last-line-no-newline', 'a,b\n   ', 'whitespace-only last line with no ending'),
    text('blank/spaces-only-last-line-newline', 'a,b\n   \n', 'whitespace-only last line with an ending'),
    text('blank/whitespace-line-with-cr-inside', 'a,b\n \r \nc,d\n', 'whitespace line holding a CR when LF is the delimiter'),
    text('blank/lone-delimiter-line', 'a,b\n,\nc,d\n', 'a line holding only the delimiter', options),
    text('blank/lone-delimiter-line-header', 'h1,h2\n,\n1,2\n', 'a line holding only the delimiter after a header', headerOptions),
    text('blank/lone-delimiter-semicolon', 'a;b\n;\nc;d\n', 'a lone semicolon line', { delimiter: ';' }),
    text('blank/lone-delimiter-tab', 'a\tb\n\t\nc\td\n', 'a lone tab line with a tab delimiter', { delimiter: '\t' }),
    text('blank/spaces-then-delimiter-line', 'a,b\n  ,  \nc,d\n', 'a line of empty padded fields'),
    text('blank/quoted-empty-line', 'a,b\n""\nc,d\n', 'a line holding only an empty quoted field'),
    text('blank/quoted-empty-and-spaces', 'a,b\n  ""  \nc,d\n', 'an empty quoted field padded with spaces'),
    text('blank/only-blank-lines', '\n\n\n', 'a file of only empty lines'),
    text('blank/only-blank-lines-header', '\n\n\n', 'a file of only empty lines with a header row', headerOptions),
    text('blank/only-whitespace-lines', ' \n\t\n  \n', 'a file of only whitespace lines'),
    text('blank/only-whitespace-lines-header', ' \n\t\n  \n', 'whitespace lines with a header row', headerOptions),
    text('blank/only-crlf', '\r\n\r\n', 'a file of only CRLF'),
    text('blank/only-cr', '\r\r\r', 'a file of only CR'),
    text('blank/single-space', ' ', 'a file of one space'),
    text('blank/single-space-header', ' ', 'a file of one space with a header row', headerOptions),
    text('blank/header-then-blank-lines', 'h1,h2\n\n\n', 'a header row then only empty lines', headerOptions),
    text('blank/header-then-whitespace-lines', 'h1,h2\n  \n  \n', 'a header row then only whitespace lines', headerOptions),
  ];
}

function bomCases() {
  const utf8Bom = [0xef, 0xbb, 0xbf];
  const body = Buffer.from('a,b\n1,2\n', 'utf8');
  const u16 = (value, little) => {
    const output = Buffer.from(value, 'utf16le');
    return little ? output : Buffer.from(output).swap16();
  };
  return [
    bytes('bom/utf8-bytes', Buffer.concat([Buffer.from(utf8Bom), body]), 'UTF-8 BOM bytes before the file'),
    bytes('bom/utf8-bytes-header', Buffer.concat([Buffer.from(utf8Bom), Buffer.from('h1,h2\n1,2\n')]), 'UTF-8 BOM bytes, header row', { header: true }),
    bytes('bom/utf8-bytes-quoted-first', Buffer.concat([Buffer.from(utf8Bom), Buffer.from('"a",b\n')]), 'UTF-8 BOM bytes before a quoted first field'),
    bytes('bom/utf8-bytes-twice', Buffer.concat([Buffer.from(utf8Bom), Buffer.from(utf8Bom), body]), 'two UTF-8 BOMs: the decoder keeps one, csv-parse strips it'),
    bytes('bom/utf8-bytes-three-times', Buffer.concat([Buffer.from(utf8Bom), Buffer.from(utf8Bom), Buffer.from(utf8Bom), body]), 'three UTF-8 BOMs'),
    bytes('bom/utf8-bytes-twice-header', Buffer.concat([Buffer.from(utf8Bom), Buffer.from(utf8Bom), Buffer.from('h1,h2\n1,2\n')]), 'two UTF-8 BOMs, header row', { header: true }),
    bytes('bom/utf8-bytes-only', Buffer.from(utf8Bom), 'a file of only a UTF-8 BOM'),
    bytes('bom/utf8-bytes-twice-only', Buffer.concat([Buffer.from(utf8Bom), Buffer.from(utf8Bom)]), 'a file of two UTF-8 BOMs'),
    bytes('bom/utf8-bytes-then-newline', Buffer.concat([Buffer.from(utf8Bom), Buffer.from('\n')]), 'UTF-8 BOM then a newline'),
    bytes('bom/utf8-bytes-then-space-quote', Buffer.concat([Buffer.from(utf8Bom), Buffer.from(' "a",b\n')]), 'UTF-8 BOM, space, then a quote'),
    bytes('bom/utf8-bytes-in-second-line', Buffer.concat([Buffer.from('a,b\n'), Buffer.from(utf8Bom), Buffer.from('c,d\n')]), 'a BOM at the start of a later line'),
    text('bom/text-feff-start', '\ufeffa,b\n1,2\n', 'U+FEFF as the first character of the text (becomes a BOM byte sequence on disk)'),
    text('bom/text-feff-twice', '\ufeff\ufeffa,b\n1,2\n', 'U+FEFF twice at the start'),
    text('bom/text-feff-quoted', '\ufeff"a",b\n', 'U+FEFF before a quoted field'),
    text('bom/text-feff-middle-field', 'a,\ufeffb\n', 'U+FEFF at the start of a later field'),
    text('bom/text-feff-end-field', 'a\ufeff,b\n', 'U+FEFF at the end of an unquoted field'),
    text('bom/text-feff-line-start', 'a,b\n\ufeffc,d\n', 'U+FEFF at the start of a later line'),
    text('bom/text-feff-then-quote-after-space', '\ufeff "a",b\n', 'U+FEFF, space, quoted field'),
    text('bom/text-feff-header-name', '\ufeffh1,h2\n1,2\n', 'U+FEFF at the start of the header row', { header: true }),
    bytes('bom/utf16le', Buffer.concat([Buffer.from([0xff, 0xfe]), u16('a,b\n1,2\n', true)]), 'UTF-16 LE file with BOM'),
    bytes('bom/utf16le-header', Buffer.concat([Buffer.from([0xff, 0xfe]), u16('h1,h2\n1,2\n', true)]), 'UTF-16 LE file with BOM, header row', { header: true }),
    bytes('bom/utf16be', Buffer.concat([Buffer.from([0xfe, 0xff]), u16('a,b\n1,2\n', false)]), 'UTF-16 BE file with BOM'),
    bytes('bom/utf16le-odd-length', Buffer.concat([Buffer.from([0xff, 0xfe]), u16('a,b', true), Buffer.from([0x41])]), 'UTF-16 LE with a dangling byte'),
    bytes('bom/utf16le-bom-only', Buffer.from([0xff, 0xfe]), 'a file of only a UTF-16 LE BOM'),
    bytes('bom/utf16-bom-then-utf8-bom', Buffer.concat([Buffer.from([0xff, 0xfe]), u16('\ufeffa,b\n', true)]), 'UTF-16 LE BOM then a U+FEFF character'),
    bytes('bom/utf16le-cr', Buffer.concat([Buffer.from([0xff, 0xfe]), u16('a,b\rc,d\r', true)]), 'UTF-16 LE with CR endings'),
    bytes('bom/ff-only', Buffer.from([0xff]), 'a single 0xFF byte'),
    bytes('bom/fe-ff-no-content', Buffer.from([0xfe, 0xff]), 'a UTF-16 BE BOM only'),
    bytes('invalid-utf8/lone-continuation', Buffer.from([0x61, 0x2c, 0x80, 0x62, 0x0a]), 'a lone continuation byte (decodes to U+FFFD)'),
    bytes('invalid-utf8/truncated-sequence', Buffer.from([0x61, 0x2c, 0xe2, 0x82, 0x0a, 0x62, 0x2c, 0x63, 0x0a]), 'a truncated three-byte sequence before a newline'),
    bytes('invalid-utf8/c3-28', Buffer.from([0xc3, 0x28, 0x2c, 0x62, 0x0a]), 'an invalid two-byte sequence'),
    bytes('invalid-utf8/ff-mid-file', Buffer.from([0x61, 0x2c, 0xff, 0xfe, 0x62, 0x0a]), '0xFF 0xFE inside the file'),
    bytes('invalid-utf8/overlong-newline', Buffer.from([0x61, 0xc0, 0x8a, 0x62, 0x2c, 0x63, 0x0a]), 'an overlong encoding of LF'),
    bytes('invalid-utf8/surrogate-bytes', Buffer.from([0x61, 0x2c, 0xed, 0xa0, 0x80, 0x0a]), 'an encoded surrogate'),
    bytes('invalid-utf8/at-end', Buffer.from([0x61, 0x2c, 0x62, 0xf0, 0x9f]), 'a truncated four-byte sequence at the end'),
    bytes('invalid-utf8/in-quotes', Buffer.from([0x22, 0x61, 0xff, 0x22, 0x2c, 0x62, 0x0a]), 'an invalid byte inside a quoted field'),
    bytes('invalid-utf8/replacement-adjacent-to-quote', Buffer.from([0x22, 0x61, 0x22, 0xff, 0x2c, 0x62, 0x0a]), 'an invalid byte right after a closing quote'),
    text('bom/nul-byte-field', 'a\u0000b,c\n', 'a NUL character inside a field'),
  ];
}

function quoteCases() {
  const header = { header: true };
  return [
    text('quote/space-before-opening', ' "a",b\n', 'one space before an opening quote'),
    text('quote/spaces-before-opening-with-delimiter', '  "a,b" , c\n', 'spaces before an opening quote around a delimiter'),
    text('quote/tab-before-opening', '\t"a b",c\n', 'a tab before an opening quote'),
    text('quote/nbsp-before-opening', '\u00a0"a b",c\n', 'NBSP before an opening quote'),
    text('quote/zwsp-before-opening', '\u200b"a b",c\n', 'U+200B before a quote (not trimmed, so a quote mid-field)'),
    text('quote/space-before-opening-later-field', 'a, "b,c",d\n', 'a space before an opening quote in a later field'),
    text('quote/space-before-opening-header', ' "h 1" , "h,2"\n1,2\n', 'spaces before opening quotes in the header', header),
    text('quote/space-before-opening-multiline', ' "a\nb" ,c\n', 'a space before an opening quote with a newline inside'),
    text('quote/text-before-opening', 'x"a",b\n', 'a character before a quote (mid-field quote)'),
    text('quote/space-text-space-quote', ' x "a",b\n', 'padding, text, then a quote'),
    text('quote/trimable-after-closing', '"a" ,b\n', 'a space after a closing quote'),
    text('quote/trimable-after-closing-many', '"a" \t\u00a0\u3000,b\n', 'several trimmable characters after a closing quote'),
    text('quote/trimable-after-closing-end', '"a"  \n', 'trimmable characters then the record end'),
    text('quote/trimable-after-closing-eof', '"a"  ', 'trimmable characters then the end of file'),
    text('quote/trimable-then-text', '"a" x,b\n', 'a space then text after a closing quote (error)'),
    text('quote/non-trimable-after-closing', '"a"x,b\n', 'text right after a closing quote (error)'),
    text('quote/zwsp-after-closing', '"a"\u200b,b\n', 'U+200B after a closing quote (error)'),
    text('quote/accent-after-closing', '"a"\u00e9,b\n', 'a non-ASCII letter after a closing quote (error)'),
    text('quote/quote-after-closing', '"a" "b",c\n', 'a second quoted part after a closing quote'),
    text('quote/other-delimiter-after-closing', '"a";b\n', 'a semicolon after a closing quote with comma as delimiter (error)'),
    text('quote/delimiter-after-closing-semicolon', '"a";b\n', 'a semicolon delimiter after a closing quote', { delimiter: ';' }),
    text('quote/cr-after-closing-lf-file', 'x\n"a"\ry\n', 'a CR after a closing quote when LF is the delimiter'),
    text('quote/crlf-after-closing', '"a"\r\n"b"\r\n', 'CRLF after closing quotes'),
    text('quote/mid-field', 'a"b,c\n', 'a quote in the middle of an unquoted field'),
    text('quote/mid-field-end', 'ab",c\n', 'a quote at the end of an unquoted field'),
    text('quote/mid-field-pair', 'a""b,c\n', 'a pair of quotes in an unquoted field'),
    text('quote/mid-field-spaces', 'a "b" c,d\n', 'a quoted-looking part inside an unquoted field'),
    text('quote/mid-field-later', 'a,b"\n', 'a trailing quote in a later field'),
    text('quote/mid-field-header', 'h"1,h2\n1,2\n', 'a quote in the middle of a header', header),
    text('quote/escaped', '"a""b",c\n', 'an escaped quote inside a quoted field'),
    text('quote/escaped-only', '"""",b\n', 'a field holding one escaped quote'),
    text('quote/escaped-start', '"""a",b\n', 'an escaped quote at the start'),
    text('quote/escaped-end', '"a""",b\n', 'an escaped quote at the end'),
    text('quote/escaped-run', '"a"""""b",c\n', 'five quotes in a row inside a field'),
    text('quote/escaped-then-closing-padded', '"a"" " ,b\n', 'an escaped quote, then padding, then close'),
    text('quote/empty-quoted', '"",b,""\n', 'empty quoted fields'),
    text('quote/empty-quoted-only', '""\n', 'a record of one empty quoted field'),
    text('quote/empty-quoted-eof', '""', 'an empty quoted field at the end of file'),
    text('quote/quote-then-eof', '"', 'a single quote'),
    text('quote/unclosed-eof', '"abc', 'an unclosed quote at the end of file'),
    text('quote/unclosed-later', 'a,"b\nc,d\n', 'an unclosed quote swallowing later lines'),
    text('quote/unclosed-after-escape', '"a""', 'an unclosed quote after an escaped quote'),
    text('quote/unclosed-header', '"h1,h2\n1,2\n', 'an unclosed quote in the header', header),
    text('quote/unclosed-trailing-newline', '"abc\n', 'an unclosed quote then a newline then end of file'),
    text('quote/closing-at-eof-after-newline', '"abc\n"', 'a quoted field ending exactly at end of file'),
    text('quote/delimiters-inside', '"a,b;c|d\te~f",g\n', 'every delimiter character inside quotes'),
    text('quote/newlines-inside', '"a\nb\r\nc\rd",e\n', 'every newline kind inside quotes'),
    text('quote/newline-only-inside', '"\n","\r","\r\n"\n', 'quoted fields holding only a newline'),
    text('quote/newline-inside-crlf-file', 'x,y\r\n"a\nb",c\r\n', 'an LF inside quotes in a CRLF file'),
    text('quote/newline-inside-header', '"h\n1",h2\n1,2\n', 'a newline inside a quoted header name', header),
    text('quote/space-inside-preserved', '" a ", b \n', 'padding inside versus outside quotes'),
    text('quote/quote-in-other-delimiter-files', 'a,"b;c"\n', 'a comma delimiter file with a quoted semicolon'),
    text('quote/pipe-quoted', 'a|"b|c"|d\n', 'a quoted pipe', { delimiter: '|' }),
    text('quote/single-quote-literal', "a,'b,c'\n", 'single quotes are ordinary characters'),
    text('quote/backslash-literal', '"a\\"b",c\n', 'a backslash is not an escape'),
    text('quote/smart-quotes-literal', '\u201ca,b\u201d,c\n', 'curly quotes are ordinary characters'),
    text('quote/quote-after-delimiter-space', 'a,   "b"\n', 'padded opening quote after a delimiter'),
    text('quote/closing-then-spaces-then-quote-newline', '"a"  \n"b"\n', 'closing quote, spaces, newline, next record'),
  ];
}

const EMPTY_FIELDS = ['a,,b\n', ',,\n', ',\n', 'a,\n', ',a\n', 'a,b,\n', ',\n,\n,\n'];

function delimiterCases() {
  const cases = EMPTY_FIELDS.map((csv, index) => text(`fields/empty-${index + 1}`, csv, `empty fields: ${JSON.stringify(csv)}`));
  for (const delimiter of DELIMITERS) {
    const label = delimiter === '\t' ? 'tab' : delimiter === '|' ? 'pipe' : delimiter === ';' ? 'semicolon' : delimiter === '~' ? 'tilde' : 'comma';
    const join = (...parts) => parts.join(delimiter);
    cases.push(
      text(`delimiter/${label}-plain`, `${join('a', 'b', 'c')}\n${join('1', '2', '3')}\n`, `${label} delimited rows`, { delimiter }),
      text(`delimiter/${label}-header`, `${join('h1', 'h2', 'h3')}\n${join('1', '2', '3')}\n`, `${label} delimited rows with a header`, { delimiter, header: true }),
      text(`delimiter/${label}-quoted-and-padded`, `${join(' "a b" ', 'c,d;e|f~g', ' "x""y" ')}\r\n${join('', '', '')}\r\n`,
        `${label} with quoted, padded and empty fields`, { delimiter }),
      text(`delimiter/${label}-others-literal`, `a,b;c|d~e\tf${delimiter}g\nh\n`, `the other delimiters are ordinary text with ${label}`, { delimiter }),
      text(`delimiter/${label}-trailing`, `${join('a', 'b', '')}\n${join('', 'c')}\n${delimiter}\n`, `${label} with trailing delimiters`, { delimiter }),
      text(`delimiter/${label}-spaces-around`, `a ${delimiter} b ${delimiter} c\n`, `${label} with padding around the delimiter`, { delimiter }),
      text(`delimiter/${label}-delimiter-only-file`, `${delimiter}`, `a file of one ${label}`, { delimiter }),
    );
  }
  cases.push(
    text('delimiter/tab-trimmed-fields', 'a\t\tb\t \tc\n', 'a tab delimiter next to padding tabs: tabs are delimiters first', { delimiter: '\t' }),
    text('delimiter/tab-leading-trim', '\ta\tb\n', 'a leading tab with a tab delimiter', { delimiter: '\t' }),
    text('delimiter/tab-file-comma-delimiter', 'a\tb\tc\n', 'a tab file read with a comma delimiter'),
    text('delimiter/comma-file-semicolon-delimiter', 'a,b,c\n', 'a comma file read with a semicolon delimiter', { delimiter: ';' }),
    text('delimiter/space-trim-before-tab-delimiter', ' \ta\n', 'a space then a tab delimiter then text', { delimiter: '\t' }),
  );
  return cases;
}

function headerCases() {
  const header = { header: true };
  return [
    text('header/plain', 'date,amount,payee\n2026-01-01,10.00,Example Store\n', 'ordinary header and row', header),
    text('header/duplicate-names', 'a,b,a\n1,2,3\n', 'duplicate header names (the last value wins, at the first key position)', header),
    text('header/duplicate-names-triple', 'a,a,a,b\n1,2,3,4\n', 'a header name three times', header),
    text('header/duplicate-after-trim', 'a, a ,b\n1,2,3\n', 'names that only differ in padding', header),
    text('header/duplicate-case-differs', 'a,A\n1,2\n', 'names that differ by case', header),
    text('header/empty-name', 'a,,c\n1,2,3\n', 'an empty header name', header),
    text('header/two-empty-names', ',,\n1,2,3\n', 'two empty header names', header),
    text('header/all-empty-single', '\n1,2\n', 'empty first line then a record (the line is skipped)', header),
    text('header/whitespace-name', 'a,   ,c\n1,2,3\n', 'a whitespace-only header name', header),
    text('header/quoted-empty-name', 'a,"",c\n1,2,3\n', 'a quoted empty header name', header),
    text('header/proto', '__proto__,b\n1,2\n', 'a header named __proto__', header),
    text('header/proto-quoted', '"__proto__",__proto__\n1,2\n', '__proto__ twice', header),
    text('header/proto-only', '__proto__\nx\n', 'only __proto__', header),
    text('header/constructor', 'constructor,toString,hasOwnProperty,valueOf\n1,2,3,4\n', 'names of Object.prototype members', header),
    text('header/numeric-names', '10,2,b,1,01,-1,1.5\na,b,c,d,e,f,g\n', 'integer-like names (JS orders them first, ascending)', header),
    text('header/numeric-names-large', '4294967295,4294967294,2,18446744073709551616\na,b,c,d\n', 'array-index boundary names', header),
    text('header/numeric-duplicates', '1,1,2\na,b,c\n', 'a duplicated numeric name', header),
    text('header/spaces-in-name', ' first name , last name \na,b\n', 'padded names with inner spaces', header),
    text('header/unicode-names', '\u00e9,e\u0301,\u{1F600}\n1,2,3\n', 'composed, decomposed and astral names', header),
    text('header/shorter-row', 'a,b,c\n1,2\n', 'a row shorter than the header', header),
    text('header/longer-row', 'a,b\n1,2,3,4\n', 'a row longer than the header', header),
    text('header/one-field-row', 'a,b,c\n1\n', 'a one-field row', header),
    text('header/shorter-and-longer', 'a,b\n1\n1,2,3\n1,2\n', 'short, long and exact rows', header),
    text('header/row-only-delimiters', 'a,b\n,,,\n', 'a row of only delimiters under a short header', header),
    text('header/header-only', 'a,b,c\n', 'a header-only file', header),
    text('header/header-only-no-newline', 'a,b,c', 'a header-only file with no ending', header),
    text('header/header-only-crlf', 'a,b,c\r\n', 'a header-only CRLF file', header),
    text('header/header-only-cr', 'a,b,c\r', 'a header-only CR file', header),
    text('header/empty-file', '', 'an empty file with a header row', header),
    text('header/empty-file-no-header', '', 'an empty file without a header row'),
    text('header/single-delimiter-header', ',\n1,2\n', 'a header of two empty names', header),
    text('header/single-column', 'a\n1\n2\n', 'one column', header),
    text('header/single-column-empty-values', 'a\n\n\n1\n', 'one column with empty lines', header),
    text('header/single-column-spaces-row', 'a\n  \n1\n', 'one column with a whitespace row', header),
    text('header/single-column-quoted-empty', 'a\n""\n1\n', 'one column with a quoted empty row', header),
    text('header/long-row-then-short-no-header', 'a,b,c\n1\n1,2,3,4\n', 'ragged rows with no header row'),
    text('header/ragged-no-header', 'a\nb,c\nd,e,f\n\ng,h\n', 'ragged rows with no header row'),
    text('header/ragged-no-header-trailing-delimiters', 'a,b,\nc,d\n,\n', 'ragged rows with trailing delimiters'),
    text('header/quoted-names', '"Date","Amount","Payee, Name"\n2026-01-01,1,"X, Y"\n', 'quoted header names with a delimiter', header),
    text('header/header-with-bom-bytes', '\ufeffDate,Amount\n2026-01-01,1\n', 'a BOM before the header', header),
    text('header/header-error-in-row', 'a,b\n"x"y,2\n', 'a malformed row after the header', header),
    text('header/header-then-unclosed', 'a,b\n1,"2\n', 'an unclosed quote in a row after the header', header),
    text('header/header-trailing-spaces-crlf', 'a , b \r\n1 , 2 \r\n', 'padded header and row in a CRLF file', header),
    text('header/header-multiline-then-row', '"a\r\nb",c\r\n1,2\r\n', 'a multiline header name', header),
    text('header/header-line-of-spaces-then-header', '  \na,b\n1,2\n', 'a whitespace line, then the header, then a row', header),
    text('header/header-cr-endings', 'a,b\r1,2\r3,4\r', 'a header and rows with CR endings', header),
  ];
}

function textCases() {
  return [
    text('text/composed-and-decomposed', '\u00e9,e\u0301,\u00e9\u0301\n', 'composed and decomposed accents'),
    text('text/astral', '\u{1F600},a\u{1F600}b,\u{1F468}\u200d\u{1F469}\n', 'astral characters and a ZWJ sequence'),
    text('text/long-field', `${'x'.repeat(5000)},${'y '.repeat(2000)}\n`, 'long fields'),
    text('text/many-columns', `${Array.from({ length: 200 }, (_, i) => i).join(',')}\n${Array.from({ length: 200 }, (_, i) => `v${i}`).join(',')}\n`,
      'two hundred columns', { header: true }),
    text('text/numbers-and-signs', '-1.5,+2,(3.00),1e3,0x10,\n', 'numeric looking text stays text'),
    text('text/rtl-and-combining', '\u05e9\u05bc\u05dc\u05d5\u05dd,\u202ea\u202c,\u0301\n', 'right-to-left and combining characters'),
    text('text/ls-ps-fields', 'a\u2028,\u2029b,\u2028\u2029\n', 'U+2028 and U+2029 around unquoted fields are trimmed'),
    text('text/nel-field', 'a\u0085,\u0085b\n', 'U+0085 around unquoted fields is kept'),
    text('text/trailing-space-then-eof', 'a,b ', 'a trailing space at the end of file'),
    text('text/trailing-nbsp-then-eof', 'a,b\u00a0\u00a0', 'trailing NBSP at the end of file'),
    text('text/trailing-zwsp-then-eof', 'a,b\u200b', 'a trailing U+200B at the end of file'),
    text('text/leading-after-newline', 'a,b\n  c,  d\n', 'leading padding on a later line'),
    text('text/delimiter-then-spaces-eof', 'a,   ', 'a delimiter then spaces at the end of file'),
    text('text/space-then-cr-eof', 'a,b \r', 'a trailing space then a CR at the end of file'),
    text('text/space-lf-space', 'a, \n ,b\n', 'padding next to a newline'),
    text('text/form-feed-and-vt', 'a\u000b,\u000cb\n', 'vertical tab and form feed padding'),
    text('text/inner-spaces-kept', 'a  b ,  c   d\n', 'inner spaces survive trimming'),
  ];
}

// Which named case exercises each csv-parse behavior (the plan refuses an entry whose
// case is missing or whose input does not show the behavior).
export const CSV_PARSE_CHECKLIST = [
  ['LF record delimiter', 'endings/lf', input => !input.csv.includes('\r')],
  ['CRLF record delimiter', 'endings/crlf', input => input.csv.includes('\r\n')],
  ['CR-only record delimiter', 'endings/cr', input => input.csv.includes('\r') && !input.csv.includes('\n')],
  ['first ending decides: LF then CRLF', 'endings/mixed-lf-then-crlf', input => input.csv.startsWith('a,b\nc,d\r\n')],
  ['first ending decides: LF then CR', 'endings/mixed-lf-then-cr', input => input.csv.startsWith('a,b\nc,d\r')],
  ['first ending decides: CRLF then LF', 'endings/mixed-crlf-then-lf', input => input.csv.startsWith('a,b\r\nc,d\n')],
  ['first ending decides: CRLF then CR', 'endings/mixed-crlf-then-cr', input => input.csv.startsWith('a,b\r\nc,d\r')],
  ['first ending decides: CR then LF', 'endings/mixed-cr-then-lf', input => input.csv.startsWith('a,b\rc,d\n')],
  ['first ending decides: CR then CRLF', 'endings/mixed-cr-then-crlf', input => input.csv.startsWith('a,b\rc,d\r\n')],
  ['trailing newline', 'endings/lf', input => input.csv.endsWith('\n')],
  ['no trailing newline', 'endings/lf-no-trailing', input => !input.csv.endsWith('\n')],
  ['empty line between records', 'blank/middle', input => input.csv.includes('\n\n')],
  ['whitespace-only line', 'blank/spaces-only-line', input => /\n {3}\n/.test(input.csv)],
  ['whitespace-only last line without ending', 'blank/spaces-only-last-line-no-newline', input => input.csv.endsWith('\n   ')],
  ['lone delimiter line', 'blank/lone-delimiter-line', input => input.csv.includes('\n,\n')],
  ['UTF-8 BOM bytes', 'bom/utf8-bytes', input => input.bytesBase64.startsWith('77u/')],
  ['text U+FEFF at the start', 'bom/text-feff-start', input => input.csv.startsWith('\ufeff')],
  ['two BOMs', 'bom/text-feff-twice', input => input.csv.startsWith('\ufeff\ufeff')],
  ['UTF-16 LE BOM', 'bom/utf16le', input => input.bytesBase64.startsWith('//5')],
  ['UTF-16 BE BOM', 'bom/utf16be', input => input.bytesBase64.startsWith('/v8')],
  ['invalid UTF-8', 'invalid-utf8/lone-continuation', input => 'bytesBase64' in input],
  ['trimmed: space', 'trim/unquoted-U+0020', input => input.csv.startsWith(' a ')],
  ['trimmed: tab', 'trim/unquoted-U+0009', input => input.csv.startsWith('\ta\t')],
  ['trimmed: NBSP', 'trim/unquoted-U+00A0', input => input.csv.startsWith('\u00a0a')],
  ['trimmed: U+2000..U+200A', 'trim/unquoted-U+2005', input => input.csv.startsWith('\u2005a')],
  ['trimmed: U+3000', 'trim/unquoted-U+3000', input => input.csv.startsWith('\u3000a')],
  ['trimmed: U+FEFF mid-file', 'trim/unquoted-U+FEFF', input => input.csv.startsWith('\ufeffa')],
  ['not trimmed: U+200B', 'trim/unquoted-U+200B', input => input.csv.startsWith('\u200ba')],
  ['not trimmed: U+0085', 'trim/unquoted-U+0085', input => input.csv.startsWith('\u0085a')],
  ['not trimmed: U+180E', 'trim/unquoted-U+180E', input => input.csv.startsWith('\u180ea')],
  ['padding around quoted fields', 'trim/quoted-around-U+0020', input => input.csv.startsWith(' "a" ')],
  ['padding inside quotes kept', 'trim/quoted-inside-U+0020', input => input.csv.startsWith('" a "')],
  ['space before an opening quote', 'quote/space-before-opening', input => input.csv.startsWith(' "a"')],
  ['non-trimmable before an opening quote', 'quote/zwsp-before-opening', input => input.csv.startsWith('\u200b"')],
  ['trimmable after a closing quote', 'quote/trimable-after-closing', input => input.csv.startsWith('"a" ,')],
  ['non-trimmable after a closing quote (error)', 'quote/non-trimable-after-closing', input => input.csv.startsWith('"a"x')],
  ['quote in the middle of an unquoted field', 'quote/mid-field', input => input.csv.startsWith('a"b')],
  ['escaped quotes', 'quote/escaped', input => input.csv.includes('""')],
  ['unclosed quote at EOF (error)', 'quote/unclosed-eof', input => input.csv === '"abc'],
  ['embedded delimiters in quotes', 'quote/delimiters-inside', input => input.csv.startsWith('"a,b;c|d\te~f"')],
  ['embedded newlines in quotes', 'quote/newlines-inside', input => input.csv.includes('"a\nb\r\nc\rd"')],
  ['empty fields', 'fields/empty-1', input => input.csv.includes(',,')],
  ['comma delimiter', 'delimiter/comma-plain', input => input.delimiter === ','],
  ['semicolon delimiter', 'delimiter/semicolon-plain', input => input.delimiter === ';'],
  ['pipe delimiter', 'delimiter/pipe-plain', input => input.delimiter === '|'],
  ['tab delimiter', 'delimiter/tab-plain', input => input.delimiter === '\t'],
  ['tilde delimiter', 'delimiter/tilde-plain', input => input.delimiter === '~'],
  ['header: duplicate names', 'header/duplicate-names', input => input.hasHeaderRow && input.csv.startsWith('a,b,a')],
  ['header: empty name', 'header/empty-name', input => input.hasHeaderRow && input.csv.startsWith('a,,c')],
  ['header: __proto__', 'header/proto', input => input.csv.startsWith('__proto__')],
  ['header: numeric names', 'header/numeric-names', input => input.csv.startsWith('10,2,b,1')],
  ['rows shorter than the header', 'header/shorter-row', input => input.hasHeaderRow && input.csv === 'a,b,c\n1,2\n'],
  ['rows longer than the header', 'header/longer-row', input => input.hasHeaderRow && input.csv === 'a,b\n1,2,3,4\n'],
  ['header-only file', 'header/header-only', input => input.hasHeaderRow && input.csv === 'a,b,c\n'],
  ['empty file', 'header/empty-file', input => input.csv === ''],
  ['file of only blank lines', 'blank/only-blank-lines', input => input.csv === '\n\n\n'],
  ['file of only whitespace lines', 'blank/only-whitespace-lines', input => input.csv === ' \n\t\n  \n'],
  ...CSV_OPTION_CHECKLIST,
];

export function checkCsvParseChecklist(cases) {
  const byId = new Map(cases.map(planCase => [planCase.id, planCase]));
  for (const [label, caseId, shows] of CSV_PARSE_CHECKLIST) {
    const planCase = byId.get(`parseCsvRecords/${caseId}`);
    if (!planCase) throw new Error(`csv-parse checklist: no case ${caseId} for ${label}`);
    if (!shows(planCase.input)) throw new Error(`csv-parse checklist: ${caseId} does not exercise ${label}`);
  }
}

// Seeded files from an alphabet weighted toward the characters csv-parse treats specially.
const WEIGHTED = [
  ['"', 5], [',', 8], [';', 5], ['\r', 6], ['\n', 9], [' ', 10], ['\t', 3], ['\u00a0', 3], ['\u2003', 3],
  ['\u200b', 3], ['\ufeff', 3], ['\u3000', 1], ['\u2028', 1], ['\u0085', 1], ['\u00e9', 2], ['e\u0301', 2],
  ['a', 6], ['b', 6], ['c', 4], ['x', 3], ['0', 3], ['1', 3], ['2', 2], ['9', 2], ['_', 1], ['\u{1F600}', 1],
];

function generatedText(random, delimiter) {
  const alphabet = [...WEIGHTED, [delimiter, 10]];
  const total = alphabet.reduce((sum, [, weight]) => sum + weight, 0);
  const choose = () => {
    let roll = random() * total;
    for (const [character, weight] of alphabet) {
      roll -= weight;
      if (roll < 0) return character;
    }
    return alphabet[0][0];
  };
  const length = Math.floor(random() * random() * 90);
  let output = '';
  for (let index = 0; index < length; index += 1) output += choose();
  // About a third of the files start with a well-formed prefix so that most reach later records.
  if (random() < 0.35) {
    const ending = ['\n', '\r\n', '\r'][Math.floor(random() * 3)];
    output = `h1${delimiter}h2${delimiter}h3${ending}x${delimiter}"y"${delimiter}z${ending}${output}`;
  }
  return output;
}

function generatedCases() {
  const random = mulberry32(SEED);
  return Array.from({ length: CSV_PARSE_GENERATED_COUNT }, (_, index) => {
    const delimiter = random() < 0.45 ? ',' : DELIMITERS[Math.floor(random() * DELIMITERS.length)];
    const hasHeaderRow = random() < 0.5;
    return {
      id: `parseCsvRecords/gen-${String(index + 1).padStart(4, '0')}`,
      source: 'generated',
      description: 'seeded file from an alphabet weighted toward quotes, delimiters, line endings and padding characters',
      seed: SEED,
      input: { csv: generatedText(random, delimiter), delimiter, hasHeaderRow },
    };
  });
}

export function parseCsvRecordsCases() {
  return [
    ...lineEndingCases(),
    ...blankLineCases(),
    ...bomCases(),
    ...trimCases(),
    ...quoteCases(),
    ...delimiterCases(),
    ...headerCases(),
    ...textCases(),
    ...generatedCases(),
    ...csvFileOptionCases(),
  ];
}
