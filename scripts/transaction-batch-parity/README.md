# Transaction batch clear-target oracle fixtures

These inputs isolate Actual v26.9.0's clear-target choice when the batch hook
loads explicitly selected rows plus family context. They are synthetic and
contain no asserted outcomes. Source prediction is not a runtime observation.

Pinned source: `packages/desktop-client/src/hooks/useTransactionBatchActions.ts`
at commit `59fe126f637d858c061e1eeedbef5436c8f2225a`. The hook computes the
target from any uncleared row in the loaded, ungrouped transaction set, then
filters to explicit IDs and skips explicitly selected reconciled rows. These
fixtures distinguish those steps, especially when unselected family context is
uncleared. An oracle runner must invoke the real pinned handler with a
deterministic synthetic SQLite budget and record loaded rows, selected IDs,
target, changed IDs, skipped IDs, CRDT diff, and action/confirmation behavior.

Do not exercise Actualist persistence, a server, a real budget, or user data.
Do not promote context-sensitive target behavior until observed output and the
product owner accepts its effects. No oracle or network command was run for
these fixtures.
