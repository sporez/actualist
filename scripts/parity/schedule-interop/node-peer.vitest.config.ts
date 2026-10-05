import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Machine-local paths come from the environment; nothing here names a user or
// host. Harness sources import the pinned checkout through `@actual-oracle/`.
const upstream = process.env.ACTUALIST_PARITY_ORACLE_ROOT;
if (!upstream || !path.isAbsolute(upstream)) {
  throw new Error('set ACTUALIST_PARITY_ORACLE_ROOT to the pinned Actual checkout');
}
const bridge = path.dirname(fileURLToPath(import.meta.url));
const { defineConfig } = await import(
  pathToFileURL(`${upstream}/node_modules/vitest/dist/config.js`).href
);
const { peggyLoader } = await import(
  pathToFileURL(`${upstream}/packages/vite-plugin-peggy/index.js`).href
);
const cacheRoot = process.env.SCHEDULE_INTEROP_CACHE_ROOT;
if (!cacheRoot) throw new Error('SCHEDULE_INTEROP_CACHE_ROOT is required');

export default defineConfig({
  root: bridge,
  cacheDir: `${cacheRoot}/vite-cache`,
  plugins: [peggyLoader()],
  resolve: {
    conditions: ['api'],
    alias: [
      { find: /^@actual-oracle\//, replacement: `${upstream}/` },
      {
        find: /^#platform\/server\/fs$/,
        replacement: `${bridge}/node-peer-fs-shim.ts`,
      },
    ],
  },
  ssr: {
    noExternal: true,
    external: ['better-sqlite3'],
    resolve: { conditions: ['api'] },
  },
  server: { fs: { allow: [upstream, bridge] } },
  test: {
    include: [`${bridge}/node-peer.test.ts`],
    environment: 'node',
    fileParallelism: false,
    isolate: true,
    maxWorkers: 1,
    minWorkers: 1,
    passWithNoTests: false,
    testTimeout: 360_000,
    hookTimeout: 30_000,
    reporters: ['default'],
  },
});
