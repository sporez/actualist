// Vitest config for the live-lab Node peer. Like new-budget-schema's config it
// lives outside the pinned upstream checkout (read-only), but unlike it there
// is no network stub: the peer talks to the server named by ACTUAL_LAB_URL.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const upstream = process.env.ACTUAL_UPSTREAM_DIR;
const cacheDir = process.env.LAB_VITE_CACHE_DIR;
if (!upstream || !cacheDir) {
  throw new Error('Set ACTUAL_UPSTREAM_DIR and LAB_VITE_CACHE_DIR (use run.sh).');
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
        replacement: path.join(here, '../new-budget-schema/fs-shim.mjs'),
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
  server: { fs: { allow: [upstream, here, path.join(here, '../new-budget-schema')] } },
  test: {
    globals: true,
    include: [path.join(here, 'peer.test.mjs')],
    environment: 'node',
    fileParallelism: false,
    maxWorkers: 1,
    minWorkers: 1,
    passWithNoTests: false,
    testTimeout: 180_000,
    reporters: ['default'],
  },
};
