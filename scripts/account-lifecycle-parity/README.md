# Account lifecycle parity oracle

This tool overlays a focused Vitest harness into an **isolated** checkout of
Actual Budget v26.9.0, executes the real loot-core account handlers against the
normal in-memory SQLite test database, and promotes normalized CRDT/domain
evidence into Actualist's fixture directory.

It is intentionally not a reimplementation of account lifecycle behavior. The
harness calls `account-update`, `account-reopen`, `account-close`,
`account-unlink`, schedule creation/advancement, and History undo through the
pinned loot-core handler/mutator stack. Provider HTTP calls remain mocked by
loot-core's normal node-test setup. No Actual server URL, token, bank account,
or personal budget is used.

## Ownership and prerequisites

Only the sprint coordinator may run this oracle. The checkout passed to
`--actual-checkout` must be an isolated disposable clone/worktree under that
coordinator's sole ownership. Never point the generator at the shared
read-only source checkout.

Required inputs:

- Actual `v26.9.0` at commit
  `59fe126f637d858c061e1eeedbef5436c8f2225a`;
- Node 24.x (the prepared checkout used Node 24.21.x);
- the repository-pinned Yarn `4.17.1` release;
- a completed focused `@actual-app/core` dependency setup, including its native
  SQLite module;
- a clean tracked Actual checkout. The generator refuses tracked changes and
  refuses to overwrite an unowned harness overlay.

The generator creates only these temporary untracked files in the isolated
Actual checkout and removes them after a successful or failed invocation:

```text
packages/loot-core/src/server/accounts/account-lifecycle-parity.test.ts
packages/loot-core/src/server/accounts/account-lifecycle-parity-support.ts
.actualist-account-lifecycle-oracle.json
.actualist-account-lifecycle-vitest.json
```

## Predetermined invocation

From the Actualist repository root:

```sh
node scripts/account-lifecycle-parity/generate.mjs \
  --actual-checkout /absolute/path/to/isolated-actual-v26.9.0
```

The generator performs exactly one runtime command, from the isolated Actual
checkout root:

```sh
node .yarn/releases/yarn-4.17.1.cjs workspace @actual-app/core run test:node \
  src/server/accounts/account-lifecycle-parity.test.ts \
  --reporter=json \
  --outputFile=.actualist-account-lifecycle-vitest.json
```

`ACTUALIST_ACCOUNT_LIFECYCLE_ORACLE_OUTPUT` is set to the absolute temporary
raw-output path for that process. The exact argv, normalized working directory,
environment variable name, tool versions, source hashes, harness hashes, and
generation date are written to the generated manifest.

The intended generated files are:

```text
ActualistTests/Fixtures/ActualCore26_9_0/AccountLifecycle/
  account-lifecycle-oracle.json
  manifest.json
```

An alternative destination may be supplied with `--output`. Promotion uses a
temporary directory and rename only after Vitest exits zero and every
predetermined case is present exactly once.

## Predetermined cases and assertions

The harness has no case filter. One invocation must complete all of these
groups:

- open/closed rename and History inverse, plus the core handler's unchanged,
  whitespace, exact-duplicate, and case-variant input boundary;
- reopen plus repeated reopen behavior and History inverse;
- empty-account deletion and History restoration;
- nonempty zero-balance close;
- positive and negative nonzero closes;
- on-budget → on-budget, on-budget → off-budget (hidden category), off-budget
  → on-budget, and off-budget → off-budget transfer/category behavior;
- self-transfer refusal with zero CRDT/domain change;
- split-parent balance exclusion and split-child inclusion;
- forced simple deletion and a forced split/paired-transfer graph deletion;
- SimpleFIN local unlink;
- GoCardless last-reference remote removal, shared-bank suppression, absent
  token behavior, and swallowed remote failure;
- an active schedule reference before close, after close, and after reopen,
  including automatic-posting eligibility;
- rename, reopen, empty/zero/nonzero close undo boundaries, including proof
  that local provider unlink is outside the close undo group.

Every case asserts normalized raw CRDT cells and selected relational rows. The
fixture stores synthetic IDs and amounts only. CRDT timestamps and SQLite
message IDs are deliberately omitted because they are transport ordering noise;
the remaining message order is preserved.

## Stop conditions and correction budget

The generator stops without promoting fixtures if any of these occurs:

- the commit, tag, package version, Node major, or Yarn version differs;
- pinned source or harness files are missing;
- the isolated checkout has tracked changes;
- an overlay/output path already exists and is not owned by this invocation;
- Vitest exits nonzero or its JSON report does not describe a passing run;
- the raw output schema, case IDs, case count, or synthetic-data declaration
  differs from the reviewed contract;
- a generated file fails manifest-schema validation or a recorded SHA-256 does
  not match.

The approved execution budget is one coordinator-owned generation/investigation
and, only after a concrete correction, at most one post-correction generation.
Do not retry unchanged code, broaden to the upstream suite, run another worker's
checkout, or count source inspection as oracle proof.
