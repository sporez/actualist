// Whether Actual has published a release newer than the oracle pin. Reads the
// release tags of the pinned repository with `git ls-remote`, so it needs the
// network but no GitHub token. Only plain vX.Y.Z tags count as releases.
import { spawnSync } from 'node:child_process';
import { oraclePin } from './oracle-pin.mjs';

const RELEASE_TAG = /^v(\d+)\.(\d+)\.(\d+)$/;

function versionOf(tag) {
  const match = RELEASE_TAG.exec(tag);
  return match ? match.slice(1).map(Number) : null;
}

function compareVersions(left, right) {
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

// { pinned, newer: [tags, oldest first] } or { pinned, error }.
export function checkUpstreamReleases({ timeoutMs = 20000 } = {}) {
  const pinned = oraclePin.tag;
  const pinnedVersion = versionOf(pinned);
  if (!pinnedVersion) return { pinned, error: `pin tag ${pinned} is not a vX.Y.Z release tag` };
  if (!oraclePin.repository) return { pinned, error: 'config/parity/oracle-pin.json has no repository' };
  const result = spawnSync('git', ['ls-remote', '--tags', '--refs', oraclePin.repository, 'refs/tags/v*'], {
    encoding: 'utf8',
    timeout: timeoutMs,
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' },
  });
  if (result.status !== 0) {
    const reason = (result.stderr ?? '').trim().split('\n').pop() || result.error?.message || `exit ${result.status}`;
    return { pinned, error: reason };
  }
  const newer = result.stdout
    .split('\n')
    .map((line) => line.split('\t')[1]?.replace('refs/tags/', ''))
    .filter((tag) => tag && versionOf(tag))
    .filter((tag) => compareVersions(versionOf(tag), pinnedVersion) > 0)
    .sort((left, right) => compareVersions(versionOf(left), versionOf(right)));
  return { pinned, newer };
}

// One line for the upstream command and the verify notice.
export function describeUpstream(check) {
  if (check.error) return `Could not check for a newer Actual release (pin ${check.pinned}): ${check.error}`;
  if (check.newer.length === 0) return `Oracle pin ${check.pinned} is the latest Actual release.`;
  return `Actual ${check.newer.at(-1)} is out; the oracle is pinned to ${check.pinned} ` +
    `(newer: ${check.newer.join(', ')}). Re-pin config/parity/oracle-pin.json and regenerate the fixtures.`;
}
