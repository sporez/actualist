// Vitest runs the pinned API directly from source. Match the API package's own
// source-test resolution for assets normally copied beside the built module.
export * from '@actual-oracle/packages/loot-core/src/platform/server/fs/index.api.ts';

const upstream = process.env.ACTUALIST_PARITY_ORACLE_ROOT;

export const bundledDatabasePath =
  `${upstream}/packages/loot-core/default-db.sqlite`;
export const migrationsPath =
  `${upstream}/packages/loot-core/migrations`;
export const demoBudgetPath =
  `${upstream}/packages/loot-core/demo-budget`;
