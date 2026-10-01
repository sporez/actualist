import { defineConfig } from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/node_modules/vitest/dist/config.js';
import { peggyLoader } from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/vite-plugin-peggy/index.js';

const upstream =
  '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual';
const bridge =
  '/Users/neil/CC/actualist-dev/scripts/parity/schedule-interop';
const cacheRoot = process.env.SCHEDULE_INTEROP_CACHE_ROOT;
if (!cacheRoot) throw new Error('SCHEDULE_INTEROP_CACHE_ROOT is required');

export default defineConfig({
  root: bridge,
  cacheDir: `${cacheRoot}/vite-cache`,
  plugins: [peggyLoader()],
  resolve: {
    conditions: ['api'],
    alias: [
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
