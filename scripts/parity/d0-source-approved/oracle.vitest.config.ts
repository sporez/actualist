import { defineConfig } from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/node_modules/vitest/dist/config.js';
import { peggyLoader } from '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual/packages/vite-plugin-peggy/index.js';

const upstream =
  '/Users/neil/CC/actualist/.artifacts/parity-sprint-20260927/upstream-actual';
const research =
  '/Users/neil/CC/actualist-dev/scripts/parity/d0-source-approved';
const evidence =
  process.env.ACTUAL_ORACLE_EVIDENCE_DIR ?? `${research}/evidence`;

export default defineConfig({
  root: upstream,
  cacheDir: `${evidence}/vite-cache/${process.env.ACTUAL_ORACLE_RUN_ID ?? 'unset'}`,
  plugins: [peggyLoader()],
  resolve: {
    conditions: ['api'],
    alias: [
      {
        find: /^#platform\/server\/fs$/,
        replacement: `${research}/oracle-fs-shim.ts`,
      },
    ],
  },
  ssr: {
    noExternal: true,
    external: ['better-sqlite3'],
    resolve: { conditions: ['api'] },
  },
  server: {
    fs: {
      allow: [upstream, research],
    },
  },
  test: {
    include: [`${research}/zip-registration-oracle.test.ts`],
    setupFiles: [`${research}/oracle-setup.ts`],
    environment: 'node',
    fileParallelism: false,
    isolate: true,
    maxWorkers: 1,
    minWorkers: 1,
    passWithNoTests: false,
    testTimeout: 240_000,
    hookTimeout: 30_000,
    reporters: ['default'],
    onConsoleLog() {
      return false;
    },
  },
});
