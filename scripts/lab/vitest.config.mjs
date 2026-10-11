// Vitest config for the lab budget tool. Lives outside the pinned upstream
// checkout (read-only); talks to the server named by ACTUAL_LAB_URL (no stub).
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.ACTUALIST_PARITY_ORACLE_ROOT;
const cacheDir = process.env.LAB_VITE_CACHE_DIR;
if (!upstream || !cacheDir) {
  throw new Error('Set ACTUALIST_PARITY_ORACLE_ROOT and LAB_VITE_CACHE_DIR (use budgets.sh).');
}

const { peggyLoader } = await import(
  path.join(upstream, 'packages/vite-plugin-peggy/index.js')
);

export default {
  root: upstream,
  cacheDir,
  plugins: [peggyLoader()],
  resolve: {
    conditions: ['api'],
    alias: [
      {
        find: /^#platform\/server\/fs$/,
        replacement: path.join(here, '../parity/new-budget-schema/fs-shim.mjs'),
      },
      {
        find: /^#actual-upstream-fs-index-api$/,
        replacement: path.join(upstream, 'packages/loot-core/src/platform/server/fs/index.api.ts'),
      },
      { find: /^@harness\/api$/, replacement: path.join(upstream, 'packages/api/index.ts') },
    ],
  },
  ssr: {
    noExternal: true,
    external: ['better-sqlite3'],
    resolve: { conditions: ['api'] },
  },
  server: { fs: { allow: [upstream, here, path.join(here, '../parity/new-budget-schema')] } },
  test: {
    globals: true,
    include: [path.join(here, 'lab.test.mjs')],
    environment: 'node',
    fileParallelism: false,
    maxWorkers: 1,
    minWorkers: 1,
    passWithNoTests: false,
    testTimeout: 180_000,
    reporters: ['default'],
  },
};
