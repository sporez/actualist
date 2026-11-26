// Names, pinned sources and the author's structural expectations shared by
// generate.mjs and verify.mjs. The expectations check what kind of answer a
// scenario produced (an envelope with transactions, an error envelope, a
// non-JSON 404); they never state a value the server computes.
import { buildScenarios } from './scenarios.mjs';

export const contractName = 'enablebanking-server-contract.json';
export const manifestName = 'enablebanking-server-manifest.json';
export const helperPaths = [
  'scripts/enablebanking-server-parity/scenarios.mjs',
  'scripts/enablebanking-server-parity/shape.mjs',
  'scripts/enablebanking-server-parity/oracle-runner.template',
  'scripts/parity/lib/oracle-pin.mjs',
  'scripts/parity/lib/fixture-diff.mjs',
];

// The upstream files whose behavior the fixture records.
export const sourceHashes = {
  'packages/sync-server/src/app-enablebanking/app-enablebanking.ts':
    'a549912977f3092b4c226426c1642da35f430cebae4c87c95068dfb8c5290677',
  'packages/sync-server/src/app-enablebanking/services/enablebanking-service.ts':
    '83b8ed373eee3b07b153460d52cccd8b4d1a50927498b1e914e99329769d3cde',
  'packages/sync-server/src/app-enablebanking/utils/errors.ts':
    'f9e1f26267e8f53fd33150896b842d3c946cedf4f64dcba86ebdb600d363623a',
  'packages/sync-server/src/app-gocardless/util/handle-error.ts':
    '0f6a6428c65a15244ddc66ab0aac97731871ad5ea7f5e91263ce8a56813391cd',
  'packages/sync-server/src/util/ssrf.ts':
    'efc03fb3bec5f36885de33aafa80e3c2a44663aee7eb254c656a896d609198cb',
};

const ERROR_SCENARIOS = new Set([
  'expired-session-unauthorized',
  'expired-session-closed',
  'expired-session-on-transactions',
  'rate-limited',
  'account-not-found',
  'wrong-period',
  'provider-error',
  'provider-timeout',
  'not-configured',
  'missing-start-date',
]);

export function expectationFailures(record) {
  const failures = [];
  const scenario = buildScenarios().find(candidate => candidate.id === record.id);
  if (!scenario) return [`no scenario ${record.id}`];
  const { status, body } = record.response ?? {};
  if (record.id === 'routes-missing') {
    if (status !== 404) failures.push(`expected Express's 404, got ${status}`);
    if (body !== null) failures.push('expected a non-JSON body');
    return failures;
  }
  if (status !== 200) failures.push(`expected HTTP 200, got ${status}`);
  if (body?.status !== 'ok') failures.push('expected status ok');
  const data = body?.data ?? {};
  if (scenario.request.path === '/status') {
    if (typeof data.configured !== 'boolean') failures.push('expected data.configured');
    return failures;
  }
  if (ERROR_SCENARIOS.has(record.id)) {
    if (typeof data.error_code !== 'string') failures.push('expected data.error_code');
    if (typeof data.error_type !== 'string') failures.push('expected data.error_type');
    if ('transactions' in data) failures.push('an error envelope carries no transactions');
  } else {
    if (!Array.isArray(data.transactions?.all)) failures.push('expected data.transactions.all');
    if (!Array.isArray(data.balances)) failures.push('expected data.balances');
    if (typeof data.startingBalance !== 'number') failures.push('expected a numeric data.startingBalance');
    if ('error_code' in data) failures.push('a download carries no error_code');
  }
  return failures;
}
