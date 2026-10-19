// The live-lab peer config (pinned upstream as root, api conditions, fs shim)
// with this harness's test file. The peer also imports the desktop import
// modal helpers from the pinned checkout, which the base already allows.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import base from '../live-lab-interop/vitest.config.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

export default {
  ...base,
  server: { fs: { allow: [...base.server.fs.allow, here] } },
  test: { ...base.test, include: [path.join(here, 'peer.test.mjs')] },
};
