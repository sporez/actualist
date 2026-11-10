// Vitest configuration for the file-import oracle run. It lives outside the pinned
// Actual checkout and points vitest at it; generate.mjs runs it under a sandbox
// profile that denies every write below the checkout, so the cache is redirected.
import assert from 'node:assert/strict';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.env.ACTUALIST_FILE_IMPORT_ORACLE_ROOT;
const harness = process.env.ACTUALIST_FILE_IMPORT_ORACLE_HARNESS;
const cache = process.env.ACTUALIST_FILE_IMPORT_ORACLE_CACHE;
assert.ok(root && harness && cache, 'generate.mjs must configure the checkout, harness and cache paths');
const { defineConfig } = await import(pathToFileURL(path.join(root, 'node_modules/vitest/dist/config.js')).href);

export default defineConfig({
  root,
  cacheDir: cache,
  resolve: { conditions: ['api'] },
  ssr: { resolve: { conditions: ['api'] } },
  server: { fs: { allow: [root, harness] } },
  test: {
    include: [path.join(harness, 'oracle-runner.test.ts')],
    environment: 'node',
    pool: 'forks',
    fileParallelism: false,
    passWithNoTests: false,
    testTimeout: 120_000,
    reporters: ['default'],
  },
});
