// Vitest runs the pinned API directly from source. The source API filesystem
// expects built assets beside index.api.ts, so point only those three constants
// at the pinned source assets, matching packages/api/methods.test.ts.
export * from '@actual-oracle/packages/loot-core/src/platform/server/fs/index.api.ts';

const upstream = process.env.ACTUALIST_PARITY_ORACLE_ROOT;

export const bundledDatabasePath =
  `${upstream}/packages/loot-core/default-db.sqlite`;
export const migrationsPath =
  `${upstream}/packages/loot-core/migrations`;
export const demoBudgetPath =
  `${upstream}/packages/loot-core/demo-budget`;
