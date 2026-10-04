// The harness needs no server. Fail loudly if anything tries to use the network.
globalThis.fetch = async input => {
  throw new Error(`Network access is disabled in this harness: ${String(input)}`);
};
