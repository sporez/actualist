import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Machine-local paths come from the environment; nothing here names a user or
// host. Harness sources import the pinned checkout through `@actual-oracle/`.
const upstream = process.env.ACTUALIST_PARITY_ORACLE_ROOT;
if (!upstream || !path.isAbsolute(upstream)) {
  throw new Error('set ACTUALIST_PARITY_ORACLE_ROOT to the pinned Actual checkout');
}
const research = path.dirname(fileURLToPath(import.meta.url));
const { defineConfig } = await import(
  pathToFileURL(`${upstream}/node_modules/vitest/dist/config.js`).href
);
const { peggyLoader } = await import(
  pathToFileURL(`${upstream}/packages/vite-plugin-peggy/index.js`).href
);
const evidence =
  process.env.ACTUAL_ORACLE_EVIDENCE_DIR ?? `${research}/evidence`;

export default defineConfig({
  root: upstream,
  cacheDir: `${evidence}/vite-cache/${process.env.ACTUAL_ORACLE_RUN_ID ?? 'unset'}`,
  plugins: [peggyLoader()],
  resolve: {
    conditions: ['api'],
    alias: [
      { find: /^@actual-oracle\//, replacement: `${upstream}/` },
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
