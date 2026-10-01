// Vitest runs the pinned API directly from source. The source API filesystem
// expects built assets beside index.api.ts, so point only those three constants
// at the pinned source assets, matching packages/api/methods.test.ts.
export * from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/loot-core/src/platform/server/fs/index.api.ts';

export const bundledDatabasePath =
  '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/loot-core/default-db.sqlite';
export const migrationsPath =
  '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/loot-core/migrations';
export const demoBudgetPath =
  '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/loot-core/demo-budget';
