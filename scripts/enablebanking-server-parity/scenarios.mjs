// The plan for the Enable Banking server fixture: synthetic raw Enable Banking
// API payloads (shaped per Enable Banking's public API) that the runner feeds
// through Actual's own sync-server routes. Pure data. Nothing here is an
// expected value: every response in the fixture comes from running Actual's
// code (app-enablebanking.ts, enablebanking-service.ts, utils/errors.ts).
//
// Mock data only: account uids, names, references and amounts are invented.

export const TODAY = '2026-10-15';
export const SCHEMA_VERSION = 1;

const balance = (type, amount, currency = 'EUR', referenceDate = '2026-10-14') => ({
  balance_amount: { currency, amount },
  balance_type: type,
  reference_date: referenceDate,
});

const ok = body => ({ status: 200, body });
const fail = (status, body) => ({ status, body });

// A provider route answer: `{ status, body }` (body is JSON), `{ status, text }`
// (a non-JSON body) or `{ abort: true }` (the request timer fired).
const page = (transactions, continuationKey) => ok(
  continuationKey ? { transactions, continuation_key: continuationKey } : { transactions },
);

const transactionsRequest = (accountId, startDate, aspspName) => ({
  path: '/transactions',
  body: aspspName === undefined ? { accountId, startDate } : { accountId, startDate, aspspName },
});

const credit = (fields) => ({ credit_debit_indicator: 'CRDT', status: 'BOOK', ...fields });
const debit = (fields) => ({ credit_debit_indicator: 'DBIT', status: 'BOOK', ...fields });

export function buildScenarios() {
  return [
    {
      id: 'booked-and-pending',
      description: 'Booked credit and debit plus a pending debit; CLAV is preferred over the first balance.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('ITAV', '1250.40'), balance('CLAV', '1300.15'), balance('XPCD', '1310.00')] }),
        transactions: [page([
          credit({
            entry_reference: 'eb-ref-1001',
            transaction_id: 'eb-tx-1001',
            transaction_amount: { currency: 'EUR', amount: '2500.00' },
            debtor: { name: 'Synthetic Employer' },
            creditor: { name: 'Account Holder' },
            booking_date: '2026-10-01',
            value_date: '2026-10-01',
            transaction_date: '2026-09-30',
            remittance_information: ['Salary October'],
          }),
          debit({
            entry_reference: 'eb-ref-1002',
            transaction_amount: { currency: 'EUR', amount: '42.17' },
            creditor: { name: 'Synthetic Grocer' },
            debtor: { name: 'Account Holder' },
            booking_date: '2026-10-05',
            value_date: '2026-10-06',
            remittance_information: ['Card payment 4471'],
          }),
          debit({
            status: 'PDNG',
            transaction_id: 'eb-tx-pend-1',
            transaction_amount: { currency: 'EUR', amount: '12.50' },
            creditor: { name: 'Synthetic Cafe' },
            value_date: '2026-10-13',
            transaction_date: '2026-10-12',
          }),
        ])],
      },
    },
    {
      id: 'missing-ids',
      description: 'A row with only transaction_id, one with an empty entry_reference, and two identical rows with neither.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '400.00')] }),
        transactions: [page([
          debit({
            transaction_id: 'eb-tx-only-2001',
            transaction_amount: { currency: 'EUR', amount: '25.00' },
            creditor: { name: 'Synthetic Bakery' },
            booking_date: '2026-10-02',
          }),
          debit({
            entry_reference: '',
            transaction_id: 'eb-tx-after-empty-ref',
            transaction_amount: { currency: 'EUR', amount: '7.25' },
            creditor: { name: 'Synthetic Kiosk' },
            booking_date: '2026-10-03',
          }),
          debit({
            transaction_amount: { currency: 'EUR', amount: '9.99' },
            creditor: { name: 'Synthetic Streaming' },
            booking_date: '2026-10-04',
          }),
          debit({
            transaction_amount: { currency: 'EUR', amount: '9.99' },
            creditor: { name: 'Synthetic Streaming' },
            booking_date: '2026-10-04',
          }),
        ])],
      },
    },
    {
      id: 'date-fallbacks',
      description: 'booking_date, then value_date, then transaction_date; rows with no usable date or amount are dropped.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '88.00')] }),
        transactions: [page([
          debit({
            entry_reference: 'eb-ref-3001',
            transaction_amount: { currency: 'EUR', amount: '11.00' },
            creditor: { name: 'Synthetic Booking Date' },
            booking_date: '2026-10-07',
            value_date: '2026-10-08',
            transaction_date: '2026-10-06',
          }),
          debit({
            entry_reference: 'eb-ref-3002',
            transaction_amount: { currency: 'EUR', amount: '12.00' },
            creditor: { name: 'Synthetic Value Date' },
            value_date: '2026-10-08',
            transaction_date: '2026-10-06',
          }),
          debit({
            entry_reference: 'eb-ref-3003',
            transaction_amount: { currency: 'EUR', amount: '13.00' },
            creditor: { name: 'Synthetic Transaction Date' },
            transaction_date: '2026-10-09',
          }),
          debit({
            status: 'PDNG',
            entry_reference: 'eb-ref-3004-no-date',
            transaction_amount: { currency: 'EUR', amount: '14.00' },
            creditor: { name: 'Synthetic No Date' },
          }),
          debit({
            entry_reference: 'eb-ref-3005-slash-date',
            transaction_amount: { currency: 'EUR', amount: '15.00' },
            creditor: { name: 'Synthetic Slash Date' },
            booking_date: '2026/10/10',
          }),
          debit({
            entry_reference: 'eb-ref-3006-bad-amount',
            transaction_amount: { currency: 'EUR', amount: 'n/a' },
            creditor: { name: 'Synthetic Bad Amount' },
            booking_date: '2026-10-10',
          }),
          debit({
            entry_reference: 'eb-ref-3007-empty-amount',
            transaction_amount: { currency: 'EUR', amount: '  ' },
            creditor: { name: 'Synthetic Empty Amount' },
            booking_date: '2026-10-10',
          }),
        ])],
      },
    },
    {
      id: 'payee-and-sign',
      description: 'Payee from the counterparty, the first cleaned remittance line, or nothing; sign from the indicator or the bank.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '5000.00')] }),
        transactions: [page([
          {
            status: 'BOOK',
            entry_reference: 'eb-ref-4001',
            transaction_amount: { currency: 'EUR', amount: '-15.00' },
            creditor: { name: 'Synthetic No Indicator Creditor' },
            debtor: { name: 'Account Holder' },
            booking_date: '2026-10-02',
          },
          {
            status: 'BOOK',
            entry_reference: 'eb-ref-4002',
            transaction_amount: { currency: 'EUR', amount: '30.00' },
            debtor: { name: 'Synthetic No Indicator Debtor' },
            booking_date: '2026-10-03',
          },
          debit({
            entry_reference: 'eb-ref-4003',
            transaction_amount: { currency: 'EUR', amount: '950.00' },
            remittance_information: ['SVWZ+Synthetic Rent October', 'EREF+synthetic-ref-77', '   '],
            booking_date: '2026-10-04',
          }),
          credit({
            entry_reference: 'eb-ref-4004',
            transaction_amount: { currency: 'EUR', amount: '+20.00' },
            debtor: { name: null },
            creditor: { name: 'Account Holder' },
            remittance_information: ['Refund 991'],
            booking_date: '2026-10-05',
          }),
          debit({
            entry_reference: 'eb-ref-4005',
            transaction_amount: { currency: 'EUR', amount: '-3.40' },
            creditor: null,
            booking_date: '2026-10-06',
          }),
        ])],
      },
    },
    {
      id: 'non-eur-account',
      description: 'A GBP account: amounts and balances keep their currency.',
      configured: true,
      request: transactionsRequest('eb-acct-gbp', '2026-07-18', 'Synthetic UK Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '980.55', 'GBP')] }),
        transactions: [page([
          debit({
            entry_reference: 'eb-ref-5001',
            transaction_amount: { currency: 'GBP', amount: '19.99' },
            creditor: { name: 'Synthetic London Shop' },
            booking_date: '2026-10-08',
          }),
        ])],
      },
    },
    {
      id: 'zero-decimal-currency',
      description: 'A JPY account: the server scales balances by 100 whatever the currency.',
      configured: true,
      request: transactionsRequest('eb-acct-jpy', '2026-07-18', 'Synthetic JP Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '125000', 'JPY')] }),
        transactions: [page([
          debit({
            entry_reference: 'eb-ref-6001',
            transaction_amount: { currency: 'JPY', amount: '3200' },
            creditor: { name: 'Synthetic Tokyo Store' },
            booking_date: '2026-10-09',
          }),
        ])],
      },
    },
    {
      id: 'balances-without-clav',
      description: 'No CLAV balance: the first balance is the starting balance.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('ITAV', '10.05'), balance('XPCD', '12.00')] }),
        transactions: [page([])],
      },
    },
    {
      id: 'balances-empty',
      description: 'The bank lists no balance: the starting balance is 0.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [] }),
        transactions: [page([
          debit({
            entry_reference: 'eb-ref-7001',
            transaction_amount: { currency: 'EUR', amount: '5.00' },
            creditor: { name: 'Synthetic Vending' },
            booking_date: '2026-10-10',
          }),
        ])],
      },
    },
    {
      id: 'pagination',
      description: 'Two pages joined through continuation_key.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '61.00')] }),
        transactions: [
          page([debit({
            entry_reference: 'eb-ref-8001',
            transaction_amount: { currency: 'EUR', amount: '1.00' },
            creditor: { name: 'Synthetic Page One' },
            booking_date: '2026-10-11',
          })], 'synthetic-page-2'),
          page([debit({
            entry_reference: 'eb-ref-8002',
            transaction_amount: { currency: 'EUR', amount: '2.00' },
            creditor: { name: 'Synthetic Page Two' },
            booking_date: '2026-10-10',
          })]),
        ],
      },
    },
    {
      id: 'empty-download',
      description: 'No transactions in the window.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '321.09')] }),
        transactions: [page([])],
      },
    },
    {
      id: 'no-aspsp-name',
      description: 'A request without aspspName (a bank row with no name).',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '1.00')] }),
        transactions: [page([])],
      },
    },
    // Pending later booked under a different id (bank-sync-matching case input).
    {
      id: 'pending-before-booking',
      description: 'A pending card payment with only a transaction_id.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '500.00')] }),
        transactions: [page([debit({
          status: 'PDNG',
          transaction_id: 'eb-tx-pend-77',
          transaction_amount: { currency: 'EUR', amount: '18.40' },
          creditor: { name: 'Synthetic Pharmacy' },
          value_date: '2026-10-10',
        })])],
      },
    },
    {
      id: 'pending-after-booking',
      description: 'The same card payment booked a day later under an entry_reference.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '481.60')] }),
        transactions: [page([debit({
          entry_reference: 'eb-ref-book-77',
          transaction_id: 'eb-tx-book-77',
          transaction_amount: { currency: 'EUR', amount: '18.40' },
          creditor: { name: 'Synthetic Pharmacy' },
          booking_date: '2026-10-11',
          value_date: '2026-10-10',
        })])],
      },
    },
    // Errors. The provider answers with an HTTP error; the server turns it into an HTTP 200 envelope.
    {
      id: 'expired-session-unauthorized',
      description: 'The balances call answers 401: the consent has expired.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: fail(401, { message: 'Unauthorized', error: 'UNAUTHORIZED' }),
        transactions: [],
      },
    },
    {
      id: 'expired-session-closed',
      description: 'The balances call answers 400 with a closed session error.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: fail(400, { message: 'Session is closed', error: 'CLOSED_SESSION' }),
        transactions: [],
      },
    },
    {
      id: 'expired-session-on-transactions',
      description: 'Balances answer, then the transactions call answers 403.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '10.00')] }),
        transactions: [fail(403, { message: 'Forbidden', error: 'ACCESS_DENIED' })],
      },
    },
    {
      id: 'rate-limited',
      description: 'The bank answers 429.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: fail(429, { message: 'Too many requests', error: 'ASPSP_RATE_LIMIT_EXCEEDED' }),
        transactions: [],
      },
    },
    {
      id: 'account-not-found',
      description: 'The account uid is unknown to Enable Banking (404).',
      configured: true,
      request: transactionsRequest('eb-acct-unknown', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: fail(404, { message: 'Account not found', error: 'NOT_FOUND' }),
        transactions: [],
      },
    },
    {
      id: 'wrong-period',
      description: 'Another 4xx from the bank.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: ok({ balances: [balance('CLAV', '10.00')] }),
        transactions: [fail(422, { message: 'Wrong transactions period requested', error: 'WRONG_TRANSACTIONS_PERIOD' })],
      },
    },
    {
      id: 'provider-error',
      description: 'Enable Banking answers 500 with a non-JSON body.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: { status: 502, text: '<html>Bad gateway</html>' },
        transactions: [],
      },
    },
    {
      id: 'provider-timeout',
      description: 'The request to Enable Banking times out.',
      configured: true,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: {
        balances: { abort: true },
        transactions: [],
      },
    },
    {
      id: 'not-configured',
      description: 'The server has no Enable Banking credentials.',
      configured: false,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: { balances: null, transactions: [] },
    },
    {
      id: 'missing-start-date',
      description: 'A request without startDate.',
      configured: true,
      request: { path: '/transactions', body: { accountId: 'eb-acct-checking' } },
      provider: { balances: null, transactions: [] },
    },
    // Status probe.
    {
      id: 'status-configured',
      description: 'POST /status on a configured server.',
      configured: true,
      request: { path: '/status', body: {} },
      provider: { balances: null, transactions: [] },
    },
    {
      id: 'status-not-configured',
      description: 'POST /status on a server without credentials.',
      configured: false,
      request: { path: '/status', body: {} },
      provider: { balances: null, transactions: [] },
    },
    // An older server that has no Enable Banking routes: Express's own 404.
    {
      id: 'routes-missing',
      description: 'POST /transactions on an Express app without the Enable Banking routes mounted.',
      configured: true,
      mountRoutes: false,
      request: transactionsRequest('eb-acct-checking', '2026-07-18', 'Synthetic Bank'),
      provider: { balances: null, transactions: [] },
    },
  ];
}
