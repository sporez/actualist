// pipeline/bank-layout/<bank>[/configured]: reconstructions of the CSV export layouts of widely
// used banks and card issuers, run through the modal's CSV import for one account.
//
// These are NOT real exports. Each layout reproduces what is commonly documented about a bank's
// export (header names and order, quoting, date and number style, sign convention, separate
// debit/credit or in/out columns, preamble and summary lines, delimiter, encoding) with made-up
// payees, made-up amounts, dates in 2026 and fake or zeroed account and card fields. A bank can
// change its export at any time; the point is to learn what Actual's import does with each shape.
//
// `<bank>` is the file as a new user imports it (no saved settings). `<bank>/configured` adds the
// preferences a user would save in Actual's import dialog for that layout: delimiter, skipped
// lines, header row, encoding, the field mapping (including Debit/Credit or in/out columns),
// date format and flip. Pure data: no expected output lives here.
import { base64, encodeText } from './case-kit.mjs';
import { ACCOUNT_ID, PREF, PIPELINE_CATEGORIES } from './saved-settings-cases.mjs';

const MAPPING_KEYS = ['date', 'amount', 'payee', 'notes', 'inOut', 'category', 'outflow', 'inflow'];

// Every field quoted, as several banks write them.
const quotedAll = (rows, delimiter = ',', newline = '\r\n') =>
  rows.map(row => row.map(value => `"${value.replaceAll('"', '""')}"`).join(delimiter)).join(newline) + newline;
// Only fields holding the delimiter, a quote or a line break are quoted.
const plain = (rows, delimiter = ',', newline = '\r\n') =>
  rows.map(row => row.map(value => (value.includes(delimiter) || /["\r\n]/.test(value) ? `"${value.replaceAll('"', '""')}"` : value)).join(delimiter)).join(newline) + newline;

// The preferences a user's saved import settings would hold for the layout.
function settings({ delimiter, skipStart, skipEnd, header, encoding, mapping, dateFormat, flip, inOut }) {
  const prefs = [];
  if (delimiter !== undefined) prefs.push([PREF.delimiter, delimiter]);
  if (skipStart !== undefined) prefs.push([PREF.skipStart, String(skipStart)]);
  if (skipEnd !== undefined) prefs.push([PREF.skipEnd, String(skipEnd)]);
  if (header !== undefined) prefs.push([PREF.header, String(header)]);
  if (encoding !== undefined) prefs.push([PREF.encoding, encoding]);
  if (mapping !== undefined) {
    prefs.push([PREF.mappings, JSON.stringify(Object.fromEntries(MAPPING_KEYS.map(key => [key, mapping[key] ?? null])))]);
  }
  if (dateFormat !== undefined) prefs.push([PREF.parseDate, dateFormat]);
  if (flip !== undefined) prefs.push([PREF.flip, String(flip)]);
  if (inOut !== undefined) {
    prefs.push([PREF.inOutMode, 'true']);
    prefs.push([PREF.outValue, inOut]);
  }
  return prefs;
}

const LAYOUTS = [
  {
    id: 'chase-checking',
    source: 'Chase US checking CSV: layout as commonly documented (Details, Posting Date, Description, Amount, Type, Balance, Check or Slip #; MM/DD/YYYY; signed amounts; each data row ends with an extra comma)',
    text: [
      'Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #,',
      'DEBIT,01/15/2026,SAMPLE GROCER #0001,-54.20,DEBIT_CARD,1245.80,,',
      'CREDIT,01/16/2026,EXAMPLE EMPLOYER PAYROLL,1500.00,ACH_CREDIT,2745.80,,',
      'DEBIT,01/20/2026,EXAMPLE UTILITY CO,-82.15,ACH_DEBIT,2663.65,,',
      'DEBIT,01/22/2026,EXAMPLE CAFE,-6.75,DEBIT_CARD,2656.90,,',
      'CREDIT,01/27/2026,SAMPLE MARKETPLACE REFUND,19.99,ACH_CREDIT,2676.89,,',
      '',
    ].join('\r\n'),
    configured: settings({
      header: true,
      mapping: { date: 'Posting Date', amount: 'Amount', payee: 'Description', notes: 'Type' },
      dateFormat: 'mm dd yyyy',
    }),
    configuredNote: 'amount mapped to Amount, date format MM DD YYYY',
  },
  {
    id: 'chase-card',
    source: 'Chase US credit card CSV: layout as commonly documented (Transaction Date, Post Date, Description, Category, Type, Amount, Memo; MM/DD/YYYY; purchases negative, payments positive)',
    text: [
      'Transaction Date,Post Date,Description,Category,Type,Amount,Memo',
      '01/14/2026,01/15/2026,SAMPLE GROCER #0001,Groceries,Sale,-48.12,',
      '01/17/2026,01/18/2026,EXAMPLE CAFE,Food & Drink,Sale,-5.40,',
      '01/20/2026,01/21/2026,EXAMPLE AIRLINE,Travel,Sale,-312.00,',
      '01/25/2026,01/26/2026,Payment Thank You - Web,,Payment,400.00,',
      '01/28/2026,01/29/2026,SAMPLE MARKETPLACE,Shopping,Return,22.50,',
      '',
    ].join('\r\n'),
    configured: settings({
      mapping: { date: 'Transaction Date', amount: 'Amount', payee: 'Description', notes: 'Memo' },
      dateFormat: 'mm dd yyyy',
    }),
    configuredNote: 'Transaction Date, MM DD YYYY',
  },
  {
    id: 'amex',
    source: 'American Express US CSV: layout as commonly documented (Date, Description, Card Member, Account #, Amount; MM/DD/YYYY; charges positive, payments negative)',
    text: plain([
      ['Date', 'Description', 'Card Member', 'Account #', 'Amount'],
      ['01/13/2026', 'SAMPLE GROCER 0001', 'A SAMPLE', '-00000', '63.40'],
      ['01/15/2026', 'EXAMPLE CAFE', 'A SAMPLE', '-00000', '4.85'],
      ['01/19/2026', 'EXAMPLE HOTEL GROUP', 'A SAMPLE', '-00000', '1,204.00'],
      ['01/24/2026', 'ONLINE PAYMENT - THANK YOU', 'A SAMPLE', '-00000', '-500.00'],
      ['01/26/2026', 'SAMPLE MARKETPLACE CREDIT', 'A SAMPLE', '-00000', '-35.00'],
    ]),
    configured: settings({
      mapping: { date: 'Date', amount: 'Amount', payee: 'Description' },
      dateFormat: 'mm dd yyyy',
      flip: true,
    }),
    configuredNote: 'flip amount on, MM DD YYYY',
  },
  {
    id: 'capital-one',
    source: 'Capital One US card CSV: layout as commonly documented (Transaction Date, Posted Date, Card No., Description, Category, Debit, Credit; YYYY-MM-DD; separate Debit and Credit columns holding positive numbers)',
    text: plain([
      ['Transaction Date', 'Posted Date', 'Card No.', 'Description', 'Category', 'Debit', 'Credit'],
      ['2026-01-12', '2026-01-13', '0000', 'SAMPLE GROCER', 'Merchandise', '41.37', ''],
      ['2026-01-14', '2026-01-15', '0000', 'EXAMPLE FUEL STOP', 'Gas/Automotive', '36.00', ''],
      ['2026-01-18', '2026-01-19', '0000', 'EXAMPLE DINER', 'Dining', '18.25', ''],
      ['2026-01-23', '2026-01-24', '0000', 'CAPITAL PAYMENT - THANK YOU', 'Payment/Credit', '', '250.00'],
      ['2026-01-26', '2026-01-27', '0000', 'SAMPLE MARKETPLACE', 'Merchandise', '', '12.99'],
    ]),
    configured: settings({
      mapping: { date: 'Transaction Date', payee: 'Description', notes: 'Category', outflow: 'Debit', inflow: 'Credit' },
      dateFormat: 'yyyy mm dd',
    }),
    configuredNote: 'Debit mapped to outflow and Credit to inflow',
  },
  {
    id: 'bank-of-america',
    source: 'Bank of America US checking CSV: layout as commonly documented (summary lines and a blank line before the Date, Description, Amount, Running Bal. header; MM/DD/YYYY; thousands separators in quoted amounts; signed)',
    text: [
      'Description,,Summary Amt.',
      'Beginning balance as of 01/01/2026,,"2,000.00"',
      'Total credits,,"1,500.00"',
      'Total debits,,"-210.50"',
      'Ending balance as of 01/31/2026,,"3,289.50"',
      '',
      'Date,Description,Amount,Running Bal.',
      '01/01/2026,Beginning balance as of 01/01/2026,,"2,000.00"',
      '01/05/2026,SAMPLE GROCER 0001 CARD 0000,"-64.50","1,935.50"',
      '01/09/2026,EXAMPLE EMPLOYER DES:PAYROLL,"1,500.00","3,435.50"',
      '01/15/2026,EXAMPLE UTILITY DES:AUTOPAY,"-120.00","3,315.50"',
      '01/21/2026,EXAMPLE CAFE CARD 0000,"-26.00","3,289.50"',
      '',
    ].join('\r\n'),
    configured: settings({
      skipStart: 6,
      mapping: { date: 'Date', amount: 'Amount', payee: 'Description' },
      dateFormat: 'mm dd yyyy',
    }),
    configuredNote: 'skip the first 6 lines, MM DD YYYY',
  },
  {
    id: 'wells-fargo',
    source: 'Wells Fargo US checking CSV: layout as commonly documented (no header row; five quoted fields: date MM/DD/YYYY, signed amount, an asterisk, an empty check number, description)',
    text: quotedAll([
      ['01/06/2026', '-37.80', '*', '', 'SAMPLE GROCER 0001'],
      ['01/08/2026', '2100.00', '*', '', 'EXAMPLE EMPLOYER PAYROLL'],
      ['01/12/2026', '-95.00', '*', '', 'EXAMPLE INSURANCE CO'],
      ['01/19/2026', '-9.50', '*', '', 'EXAMPLE CAFE'],
      ['01/23/2026', '45.00', '*', '', 'SAMPLE FRIEND TRANSFER'],
    ]),
    configured: settings({
      header: false,
      mapping: { date: '0', amount: '1', payee: '4' },
      dateFormat: 'mm dd yyyy',
    }),
    configuredNote: 'no header row, columns 0, 1 and 4',
  },
  {
    id: 'discover',
    source: 'Discover US card CSV: layout as commonly documented (Trans. Date, Post Date, Description, Amount, Category; MM/DD/YYYY; purchases positive, payments negative)',
    text: plain([
      ['Trans. Date', 'Post Date', 'Description', 'Amount', 'Category'],
      ['01/10/2026', '01/11/2026', 'SAMPLE GROCER 0001', '58.90', 'Supermarkets'],
      ['01/13/2026', '01/14/2026', 'EXAMPLE BOOKSTORE', '24.00', 'Merchandise'],
      ['01/17/2026', '01/18/2026', 'EXAMPLE FUEL STOP', '40.25', 'Gasoline'],
      ['01/22/2026', '01/23/2026', 'DIRECTPAY FULL BALANCE', '-300.00', 'Payments and Credits'],
      ['01/27/2026', '01/28/2026', 'SAMPLE MARKETPLACE REFUND', '-14.99', 'Payments and Credits'],
    ]),
    configured: settings({
      mapping: { date: 'Trans. Date', amount: 'Amount', payee: 'Description', notes: 'Category' },
      dateFormat: 'mm dd yyyy',
      flip: true,
    }),
    configuredNote: 'flip amount on, MM DD YYYY',
  },
  {
    id: 'citi',
    source: 'Citi US card CSV: layout as commonly documented (Status, Date, Description, Debit, Credit; MM/DD/YYYY; debits written as negative numbers in the Debit column)',
    text: quotedAll([
      ['Status', 'Date', 'Description', 'Debit', 'Credit'],
      ['Cleared', '01/07/2026', 'SAMPLE GROCER 0001', '-52.10', ''],
      ['Cleared', '01/11/2026', 'EXAMPLE PHARMACY', '-17.45', ''],
      ['Cleared', '01/16/2026', 'EXAMPLE RIDE SERVICE', '-23.00', ''],
      ['Cleared', '01/21/2026', 'ONLINE PAYMENT, THANK YOU', '', '200.00'],
      ['Cleared', '01/28/2026', 'SAMPLE MARKETPLACE RETURN', '', '31.20'],
    ]),
    configured: settings({
      mapping: { date: 'Date', payee: 'Description', outflow: 'Debit', inflow: 'Credit' },
      dateFormat: 'mm dd yyyy',
    }),
    configuredNote: 'Debit as outflow, Credit as inflow (Citi writes debits negative)',
  },
  {
    id: 'us-bank',
    source: 'U.S. Bank checking CSV: layout as commonly documented (Date, Transaction, Name, Memo, Amount; all fields quoted; YYYY-MM-DD; Transaction is DEBIT or CREDIT; signed amount)',
    text: quotedAll([
      ['Date', 'Transaction', 'Name', 'Memo', 'Amount'],
      ['2026-01-05', 'DEBIT', 'SAMPLE GROCER', 'POS PURCHASE 0001', '-44.60'],
      ['2026-01-09', 'CREDIT', 'EXAMPLE EMPLOYER', 'PAYROLL', '1800.00'],
      ['2026-01-14', 'DEBIT', 'EXAMPLE LANDLORD', 'ONLINE BILL PAY', '-950.00'],
      ['2026-01-20', 'DEBIT', 'EXAMPLE CAFE', 'POS PURCHASE 0002', '-8.30'],
      ['2026-01-26', 'CREDIT', 'SAMPLE MARKETPLACE', 'REFUND', '27.40'],
    ]),
    configured: settings({
      mapping: { date: 'Date', amount: 'Amount', payee: 'Name', notes: 'Memo' },
      dateFormat: 'yyyy mm dd',
    }),
    configuredNote: 'Amount, Name and Memo mapped',
  },
  {
    id: 'revolut',
    source: 'Revolut personal account CSV: layout as commonly documented (Type, Product, Started Date, Completed Date, Description, Amount, Fee, Currency, State, Balance; dates with a time of day; signed amounts)',
    text: plain([
      ['Type', 'Product', 'Started Date', 'Completed Date', 'Description', 'Amount', 'Fee', 'Currency', 'State', 'Balance'],
      ['CARD_PAYMENT', 'Current', '2026-01-04 09:12:45', '2026-01-05 03:20:10', 'Sample Grocer', '-23.40', '0.00', 'EUR', 'COMPLETED', '476.60'],
      ['TOPUP', 'Current', '2026-01-06 18:00:02', '2026-01-06 18:00:03', 'Top-Up by *0000', '200.00', '0.00', 'EUR', 'COMPLETED', '676.60'],
      ['CARD_PAYMENT', 'Current', '2026-01-10 12:41:19', '2026-01-11 02:15:00', 'Example Cafe', '-4.20', '0.00', 'EUR', 'COMPLETED', '672.40'],
      ['TRANSFER', 'Current', '2026-01-15 20:05:30', '2026-01-15 20:05:31', 'To Sample Friend', '-50.00', '0.00', 'EUR', 'COMPLETED', '622.40'],
      ['EXCHANGE', 'Current', '2026-01-21 08:00:00', '2026-01-21 08:00:01', 'Exchanged to GBP', '-100.00', '0.50', 'EUR', 'COMPLETED', '521.90'],
    ]),
    configured: settings({
      mapping: { date: 'Completed Date', amount: 'Amount', payee: 'Description', notes: 'Type' },
      dateFormat: 'yyyy mm dd',
    }),
    configuredNote: 'Completed Date, Amount, Description, Type',
  },
  {
    id: 'n26',
    source: 'N26 CSV: layout as commonly documented (Booking Date, Value Date, Partner Name, Partner Iban, Type, Payment Reference, Account Name, Amount (EUR), Original Amount, Original Currency, Exchange Rate; quoted; YYYY-MM-DD; signed)',
    text: quotedAll([
      ['Booking Date', 'Value Date', 'Partner Name', 'Partner Iban', 'Type', 'Payment Reference', 'Account Name', 'Amount (EUR)', 'Original Amount', 'Original Currency', 'Exchange Rate'],
      ['2026-01-05', '2026-01-05', 'Sample Grocer', '', 'MasterCard Payment', '', 'Main Account', '-31.80', '', '', ''],
      ['2026-01-09', '2026-01-09', 'Example Employer GmbH', 'DE00000000000000000000', 'Income', 'Salary January', 'Main Account', '2200.00', '', '', ''],
      ['2026-01-13', '2026-01-13', 'Example Landlord', 'DE00000000000000000001', 'Outgoing Transfer', 'Rent January', 'Main Account', '-780.00', '', '', ''],
      ['2026-01-19', '2026-01-19', 'Example Cafe', '', 'MasterCard Payment', '', 'Main Account', '-3.90', '', '', ''],
      ['2026-01-24', '2026-01-24', 'Sample Friend', 'DE00000000000000000002', 'Incoming Transfer', 'Dinner share', 'Main Account', '25.00', '', '', ''],
    ]),
    configured: settings({
      mapping: { date: 'Booking Date', amount: 'Amount (EUR)', payee: 'Partner Name', notes: 'Payment Reference' },
      dateFormat: 'yyyy mm dd',
    }),
    configuredNote: 'Amount (EUR), Partner Name, Payment Reference',
  },
  {
    id: 'monzo',
    source: 'Monzo CSV: layout as commonly documented (Transaction ID, Date, Time, Type, Name, Emoji, Category, Amount, Currency, Local amount, Local currency, Notes and #tags, Address, Receipt, Description, Category split, Money Out, Money In; DD/MM/YYYY; signed Amount plus Money Out written negative)',
    text: plain([
      ['Transaction ID', 'Date', 'Time', 'Type', 'Name', 'Emoji', 'Category', 'Amount', 'Currency', 'Local amount', 'Local currency', 'Notes and #tags', 'Address', 'Receipt', 'Description', 'Category split', 'Money Out', 'Money In'],
      ['tx_0000000000000000000001', '03/01/2026', '10:15:00', 'Card payment', 'Sample Grocer', '', 'Groceries', '-18.60', 'GBP', '-18.60', 'GBP', '', '', '', 'SAMPLE GROCER', '', '-18.60', ''],
      ['tx_0000000000000000000002', '13/01/2026', '08:00:00', 'Faster payment', 'Example Employer Ltd', '', 'Income', '1650.00', 'GBP', '1650.00', 'GBP', 'January pay', '', '', 'EXAMPLE EMPLOYER', '', '', '1650.00'],
      ['tx_0000000000000000000003', '17/01/2026', '19:42:10', 'Card payment', 'Example Cafe', '', 'Eating out', '-4.50', 'GBP', '-4.50', 'GBP', '', '', '', 'EXAMPLE CAFE', '', '-4.50', ''],
      ['tx_0000000000000000000004', '25/01/2026', '12:00:00', 'Faster payment', 'Sample Friend', '', 'General', '30.00', 'GBP', '30.00', 'GBP', 'Tickets', '', '', 'SAMPLE FRIEND', '', '', '30.00'],
    ]),
    configured: settings({
      mapping: { date: 'Date', amount: 'Amount', payee: 'Name', notes: 'Notes and #tags', category: 'Category' },
      dateFormat: 'dd mm yyyy',
    }),
    configuredNote: 'Date, Amount, Name, Notes and #tags, DD MM YYYY',
  },
  {
    id: 'ing-netherlands',
    source: 'ING Netherlands CSV: layout as commonly documented (semicolon delimiter and quoted fields; Datum as YYYYMMDD; Af/Bij column giving the direction; unsigned comma-decimal Bedrag (EUR))',
    text: quotedAll([
      ['Datum', 'Naam / Omschrijving', 'Rekening', 'Tegenrekening', 'Code', 'Af Bij', 'Bedrag (EUR)', 'Mutatiesoort', 'Mededelingen'],
      ['20260105', 'Sample Supermarkt', 'NL00BANK0000000000', '', 'BA', 'Af', '23,45', 'Betaalautomaat', 'Pasvolgnr: 000'],
      ['20260109', 'Example Werkgever BV', 'NL00BANK0000000000', 'NL00BANK0000000001', 'OV', 'Bij', '2100,00', 'Overschrijving', 'Salaris januari'],
      ['20260112', 'Example Verhuurder', 'NL00BANK0000000000', 'NL00BANK0000000002', 'IC', 'Af', '850,00', 'Incasso', 'Huur januari'],
      ['20260118', 'Example Cafe', 'NL00BANK0000000000', '', 'BA', 'Af', '4,80', 'Betaalautomaat', 'Pasvolgnr: 000'],
      ['20260124', 'Sample Vriend', 'NL00BANK0000000000', 'NL00BANK0000000003', 'OV', 'Bij', '1.250,50', 'Overschrijving', 'Terugbetaling'],
    ], ';'),
    configured: settings({
      delimiter: ';',
      mapping: { date: 'Datum', amount: 'Bedrag (EUR)', payee: 'Naam / Omschrijving', notes: 'Mededelingen', inOut: 'Af Bij' },
      dateFormat: 'yyyy mm dd',
      inOut: 'Af',
    }),
    configuredNote: 'semicolon, in/out column Af Bij with out value Af, YYYY MM DD',
  },
  {
    id: 'sparkasse-de',
    source: 'German Sparkasse CSV-CAMT style: layout as commonly documented (semicolon, quoted, Auftragskonto/Buchungstag/Valutadatum/Buchungstext/Verwendungszweck/Beguenstigter/Zahlungspflichtiger/Kontonummer/IBAN/BIC (SWIFT-Code)/Betrag/Waehrung/Info; DD.MM.YY; 1.234,56 signed; Windows-1252 bytes)',
    bytes: encodeText(quotedAll([
      ['Auftragskonto', 'Buchungstag', 'Valutadatum', 'Buchungstext', 'Verwendungszweck', 'Beguenstigter/Zahlungspflichtiger', 'Kontonummer/IBAN', 'BIC (SWIFT-Code)', 'Betrag', 'Waehrung', 'Info'],
      ['DE00000000000000000000', '05.01.26', '05.01.26', 'KARTENZAHLUNG', 'Einkauf Bäckerei Beispiel', 'Bäckerei Beispiel', '', '', '-12,80', 'EUR', 'Umsatz gebucht'],
      ['DE00000000000000000000', '09.01.26', '09.01.26', 'GEHALT/RENTE', 'Gehalt Januar', 'Beispiel Arbeitgeber GmbH', 'DE00000000000000000001', 'EXAMPLEXXX', '2.350,00', 'EUR', 'Umsatz gebucht'],
      ['DE00000000000000000000', '14.01.26', '14.01.26', 'FOLGELASTSCHRIFT', 'Miete Januar', 'Beispiel Vermieter', 'DE00000000000000000002', 'EXAMPLEXXX', '-1.045,50', 'EUR', 'Umsatz gebucht'],
      ['DE00000000000000000000', '21.01.26', '21.01.26', 'KARTENZAHLUNG', 'Café Müller Beispiel', 'Café Müller', '', '', '-6,40', 'EUR', 'Umsatz gebucht'],
      ['DE00000000000000000000', '28.01.26', '28.01.26', 'GUTSCHRIFT', 'Erstattung', 'Beispiel Shop AG', 'DE00000000000000000003', 'EXAMPLEXXX', '19,99', 'EUR', 'Umsatz gebucht'],
    ], ';'), 'latin1'),
    configured: settings({
      delimiter: ';',
      encoding: 'windows-1252',
      mapping: { date: 'Buchungstag', amount: 'Betrag', payee: 'Beguenstigter/Zahlungspflichtiger', notes: 'Verwendungszweck' },
      dateFormat: 'dd mm yy',
    }),
    configuredNote: 'semicolon, windows-1252, DD MM YY',
  },
  {
    id: 'deutsche-bank-de',
    source: 'Deutsche Bank style German CSV: layout as commonly documented (semicolon, preamble lines before the header, DD.MM.YYYY, separate Soll and Haben columns in 1.234,56 style, a closing balance line, Windows-1252 bytes)',
    bytes: encodeText([
      'Kontoumsätze;;;;;;;;;;;;;;;;;',
      'Kontonummer;DE00000000000000000000;;;;;;;;;;;;;;;;',
      'Zeitraum;01.01.2026 - 31.01.2026;;;;;;;;;;;;;;;;',
      ';;;;;;;;;;;;;;;;;',
      'Buchungstag;Wert;Umsatzart;Begünstigter / Auftraggeber;Verwendungszweck;IBAN;BIC;Kundenreferenz;Mandatsreferenz;Gläubiger ID;Fremde Gebühren;Betrag;Abweichender Empfänger;Anzahl der Aufträge;Anzahl der Schecks;Soll;Haben;Währung',
      '05.01.2026;05.01.2026;Kartenzahlung;Beispiel Supermarkt;Einkauf;;;;;;;;;;;-38,15;;EUR',
      '09.01.2026;09.01.2026;Gutschrift;Beispiel Arbeitgeber GmbH;Gehalt Januar;DE00000000000000000001;EXAMPLEXXX;;;;;;;;;;2.500,00;EUR',
      '15.01.2026;15.01.2026;Lastschrift;Beispiel Stadtwerke;Abschlag Strom;DE00000000000000000002;EXAMPLEXXX;;;;;;;;;-72,00;;EUR',
      '22.01.2026;22.01.2026;Kartenzahlung;Beispiel Café;Kaffee;;;;;;;;;;;-4,60;;EUR',
      'Kontostand;31.01.2026;;;;;;;;;;;;;;;2.385,25;EUR',
      '',
    ].join('\r\n'), 'latin1'),
    configured: settings({
      delimiter: ';',
      encoding: 'windows-1252',
      skipStart: 4,
      skipEnd: 2,
      mapping: { date: 'Buchungstag', payee: 'Begünstigter / Auftraggeber', notes: 'Verwendungszweck', outflow: 'Soll', inflow: 'Haben' },
      dateFormat: 'dd mm yyyy',
    }),
    configuredNote: 'semicolon, windows-1252, skip 4 lines at the start and 2 at the end, Soll as outflow and Haben as inflow, DD MM YYYY',
  },
  {
    id: 'uk-money-in-out',
    source: 'Generic UK bank CSV: layout as commonly documented (Date, Type, Description, Money Out, Money In, Balance; DD/MM/YYYY; both money columns hold positive numbers)',
    text: plain([
      ['Date', 'Type', 'Description', 'Money Out', 'Money In', 'Balance'],
      ['05/01/2026', 'DEB', 'SAMPLE GROCER LONDON', '27.30', '', '972.70'],
      ['13/01/2026', 'FPI', 'EXAMPLE EMPLOYER LTD', '', '1800.00', '2772.70'],
      ['16/01/2026', 'DD', 'EXAMPLE ENERGY SUPPLIER', '64.00', '', '2708.70'],
      ['20/01/2026', 'DEB', 'EXAMPLE CAFE', '3.80', '', '2704.90'],
      ['27/01/2026', 'FPI', 'SAMPLE FRIEND', '', '40.00', '2744.90'],
    ]),
    configured: settings({
      mapping: { date: 'Date', payee: 'Description', notes: 'Type', outflow: 'Money Out', inflow: 'Money In' },
      dateFormat: 'dd mm yyyy',
    }),
    configuredNote: 'Money Out as outflow, Money In as inflow, DD MM YYYY',
  },
  {
    id: 'barclays-uk',
    source: 'Barclays UK CSV: layout as commonly documented (Number, Date, Account, Amount, Subcategory, Memo; DD/MM/YYYY; signed Amount)',
    text: plain([
      ['Number', 'Date', 'Account', 'Amount', 'Subcategory', 'Memo'],
      ['1', '06/01/2026', '00-00-00 00000000', '-21.40', 'PURCHASE', 'SAMPLE GROCER LONDON ON 05 JAN'],
      ['2', '12/01/2026', '00-00-00 00000000', '1750.00', 'PAYMENT', 'EXAMPLE EMPLOYER LTD'],
      ['3', '19/01/2026', '00-00-00 00000000', '-60.00', 'DIRECT DEBIT', 'EXAMPLE BROADBAND'],
      ['4', '23/01/2026', '00-00-00 00000000', '-5.20', 'PURCHASE', 'EXAMPLE CAFE ON 22 JAN'],
      ['5', '30/01/2026', '00-00-00 00000000', '15.00', 'PAYMENT', 'SAMPLE FRIEND'],
    ]),
    configured: settings({
      mapping: { date: 'Date', amount: 'Amount', payee: 'Memo', notes: 'Subcategory' },
      dateFormat: 'dd mm yyyy',
    }),
    configuredNote: 'Amount, Memo as payee, DD MM YYYY',
  },
  {
    id: 'uk-money-in-out/ambiguous-dates',
    source: 'Generic UK bank CSV (same layout as uk-money-in-out) in a month where every day of the month is 12 or less, so DD/MM/YYYY also reads as MM/DD/YYYY',
    text: plain([
      ['Date', 'Type', 'Description', 'Money Out', 'Money In', 'Balance'],
      ['05/02/2026', 'DEB', 'SAMPLE GROCER LONDON', '27.30', '', '972.70'],
      ['09/02/2026', 'FPI', 'EXAMPLE EMPLOYER LTD', '', '1800.00', '2772.70'],
      ['10/02/2026', 'DD', 'EXAMPLE ENERGY SUPPLIER', '64.00', '', '2708.70'],
      ['12/02/2026', 'DEB', 'EXAMPLE CAFE', '3.80', '', '2704.90'],
    ]),
    configured: settings({
      mapping: { date: 'Date', payee: 'Description', notes: 'Type', outflow: 'Money Out', inflow: 'Money In' },
      dateFormat: 'dd mm yyyy',
    }),
    configuredNote: 'Money Out as outflow, Money In as inflow, DD MM YYYY',
  },
];

export const BANK_LAYOUT_IDS = LAYOUTS.map(layout => layout.id);

export function bankLayoutCases() {
  const cases = [];
  for (const layout of LAYOUTS) {
    const source = layout.bytes === undefined ? { csv: layout.text } : { bytesBase64: base64(layout.bytes) };
    const input = prefs => ({ accountId: ACCOUNT_ID, fileName: `${layout.id.replaceAll('/', '-')}.csv`, prefs, ...source, categories: PIPELINE_CATEGORIES });
    cases.push({
      id: `pipeline/bank-layout/${layout.id}`,
      source: 'named',
      description: `${layout.source}; synthetic values; no saved settings`,
      input: input([]),
    });
    cases.push({
      id: `pipeline/bank-layout/${layout.id}/configured`,
      source: 'named',
      description: `${layout.source}; synthetic values; saved settings: ${layout.configuredNote}`,
      input: input(layout.configured),
    });
  }
  return cases;
}
