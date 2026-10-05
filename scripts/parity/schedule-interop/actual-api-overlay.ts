import { init as initLootCore } from '@actual-oracle/packages/loot-core/src/server/main.ts';
import type { InitConfig, lib } from '@actual-oracle/packages/loot-core/src/server/main.ts';
import { validateNodeVersion } from '@actual-oracle/packages/api/validateNodeVersion.ts';

export * from '@actual-oracle/packages/api/methods.ts';

export let internal: typeof lib | null = null;

export async function init(config: InitConfig = {}) {
  validateNodeVersion();
  internal = await initLootCore(config);
  return internal;
}

export async function shutdown() {
  if (internal) {
    try {
      await internal.send('sync');
    } catch {
      // No loaded budget is a normal shutdown state for the seed admission pass.
    }
    await internal.send('close-budget');
    internal = null;
  }
}
