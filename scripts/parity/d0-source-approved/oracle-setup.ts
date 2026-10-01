const originalFetch = globalThis.fetch.bind(globalThis);
const startedAt = Date.now();
const requestCeilingMS = 15_000;
const investigationCeilingMS = 180_000;
const cleanupCeilingMS = 225_000;

declare global {
  // The test changes only this phase marker before its finally cleanup.
  // eslint-disable-next-line no-var
  var ACTUAL_ORACLE_FETCH_PHASE: 'investigation' | 'cleanup';
}

globalThis.ACTUAL_ORACLE_FETCH_PHASE = 'investigation';

globalThis.fetch = async (input, init = {}) => {
  const phaseCeiling =
    globalThis.ACTUAL_ORACLE_FETCH_PHASE === 'cleanup'
      ? cleanupCeilingMS
      : investigationCeilingMS;
  const remainingMS = startedAt + phaseCeiling - Date.now();
  if (remainingMS <= 0) {
    throw new DOMException('Oracle phase deadline exceeded', 'TimeoutError');
  }

  const timeoutSignal = AbortSignal.timeout(
    Math.max(1, Math.min(requestCeilingMS, remainingMS)),
  );
  const signal = init.signal
    ? AbortSignal.any([init.signal, timeoutSignal])
    : timeoutSignal;

  return originalFetch(input, { ...init, signal });
};
