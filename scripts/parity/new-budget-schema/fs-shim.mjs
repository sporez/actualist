// The source API filesystem expects built assets beside index.api.ts; point its
// three asset constants at the pinned source tree (same trick as
// packages/api/methods.test.ts and the D0 harness).
import path from 'node:path';

const upstream = process.env.ACTUAL_UPSTREAM_DIR;
const lootCore = path.join(upstream, 'packages/loot-core');

export * from '#actual-upstream-fs-index-api';
export const bundledDatabasePath = path.join(lootCore, 'default-db.sqlite');
export const migrationsPath = path.join(lootCore, 'migrations');
export const demoBudgetPath = path.join(lootCore, 'demo-budget');
