import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const overlay = process.env.ACTUALIST_CSV_INTEROP_ACTUAL_OVERLAY;
const harness = process.env.ACTUALIST_CSV_INTEROP_OVERLAY_HARNESS;
const evidence = process.env.ACTUALIST_CSV_INTEROP_EVIDENCE_DIR;
assert.ok(overlay && harness && evidence, 'The owned runner must configure overlay, harness, and evidence paths');
const importFromOverlay = (relativePath: string) =>
  import(/* @vite-ignore */ pathToFileURL(path.join(overlay, relativePath)).href);
const { defineConfig } = await importFromOverlay('node_modules/vitest/dist/config.js');
const { peggyLoader } = await importFromOverlay('packages/vite-plugin-peggy/index.js');

export default defineConfig({
  root: overlay,
  cacheDir: `${evidence}/vite-cache`,
  plugins: [peggyLoader()],
  resolve: { conditions: ['api'] },
  ssr: {
    noExternal: true,
    external: ['better-sqlite3'],
    resolve: { conditions: ['api'] },
  },
  server: { fs: { allow: [overlay, harness, evidence] } },
  test: {
    include: [`${harness}/csv-export-interop.test.ts`],
    environment: 'node',
    fileParallelism: false,
    isolate: true,
    maxWorkers: 1,
    minWorkers: 1,
    passWithNoTests: false,
    testTimeout: 120_000,
    hookTimeout: 10_000,
    reporters: ['default'],
  },
});
