// Vitest config for the new-budget schema harness. Lives outside the pinned
// upstream checkout; vitest only reads the checkout. Paths come from the
// environment (see README.md).
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.ACTUAL_UPSTREAM_DIR;
const cacheDir = process.env.NEWBUDGET_VITE_CACHE_DIR;
if (!upstream || !cacheDir) {
  throw new Error('Set ACTUAL_UPSTREAM_DIR and NEWBUDGET_VITE_CACHE_DIR (use run.sh).');
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
      { find: /^#platform\/server\/fs$/, replacement: path.join(here, 'fs-shim.mjs') },
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
  server: { fs: { allow: [upstream, here] } },
  test: {
    globals: true,
    include: [path.join(here, process.env.NEWBUDGET_TEST_FILE ?? 'generate.test.mjs')],
    setupFiles: [path.join(here, 'no-network-setup.mjs')],
    environment: 'node',
    fileParallelism: false,
    maxWorkers: 1,
    minWorkers: 1,
    passWithNoTests: false,
    testTimeout: 120_000,
    reporters: ['default'],
  },
};
