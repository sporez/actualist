# Payee parity harness

Generates the payee fixture from Actual's own handlers at the pinned release
(`config/parity/oracle-pin.json`, v26.11.0). This directory holds only the generator
side. `PayeeOracleReplayTests` replays every case through the production store's payee
commands.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest and writes the
  fixture. `--check` regenerates into a temporary directory and diffs against the
  committed fixture. The Actual sources it depends on are pinned by sha256 in the file.
- `verify.mjs`: checks the committed fixture against the manifest and `cases.mjs`.
  Needs no oracle.
- `cases.mjs`: the seed world and the 31 case ids with their user input. Pure input, no
  expectations.
- `oracle-runner.template`: the vitest test copied into the oracle for one run and
  removed afterwards.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/Payees/`
  (`payees-contract.json`, `payees-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/payee-parity/generate.mjs [--check]
node scripts/payee-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and `yarn install`
done. It is checked before and after the run and is never written to except for the
temporary runner, which is removed in a `finally`. Synthetic data only; nothing touches
a server, a real budget or Actualist persistence.

## What a case is

The world (accounts, transfer payees, regular payees, one category, transactions,
rules, one completed schedule) is seeded through upstream's own db functions
(`insertAccount`, `insertPayee`, `insertTransaction`, `insertRule`, `createSchedule`)
with explicit ids, and its raw physical rows are dumped once as the contract's
top-level `world`. Each case then does what Actual's UI sends and calls the real
handler through `runHandler`:

| Action | Actual source | Sent |
| --- | --- | --- |
| Create | `desktop-client/src/payees/mutations.ts` (`useCreatePayeeMutation`) | `payee-create {name: name.trim()}` |
| Create gate | `components/autocomplete/PayeeAutocomplete.tsx` (`filterSuggestions`) | nothing when the top match normalizes to the typed text and is not a transfer payee |
| Rename | `components/mobile/payees/MobilePayeeEditPage.tsx` (`handleSave`) | `payees-batch-change {updated:[{id, name: trimmed}]}`, nothing when the trimmed name is empty |
| Merge | `components/payees/ManagePayees.tsx` | `payees-merge {targetId, mergeIds}` |
| Delete | `ManagePayees.tsx` / `MobilePayeesPage.tsx` | `payees-batch-change {deleted:[{id}]}` |
| Favorite, learning (one row) | `ManagePayees.tsx` `onUpdate` | `payees-batch-change {updated:[{id,[field]:value}]}` only when the value differs |
| Favorite, learning (selection) | `ManagePayees.tsx` `onFavorite` / `onLearn` | every selected payee already on: all set off; otherwise all set on |
| Global learning | `components/payees/CategoryLearning.tsx` through `useSyncedPref('learn-categories')` | `preferences/save {id:'learn-categories', value: String(!enabled)}` |

The create gate is modelled with loot-core's own `getNormalisedString` over the live
non-transfer payees, comparing the typed text unmodified (so `"Grocer "` is not an
exact match). It assumes the fzf ranking puts an exact match first. A gated case has
`handlerCall: null` and `selectedExisting: <id>`.

Per case the contract records `input`, `handlerCall` (method and payload sent, or
`null`), `handlerResult`, `handlerError` (an observation, never an expectation),
`messages` (every CRDT message in order), `writes` (the net cell writes: the last value
per dataset, row and column, sorted), `rows` (payees, payee_mapping and, for the global
learning cases, preferences, after the action) and `undo` (loot-core's `undo()` called
once after the action: its messages and the same rows; `null` when nothing was sent).
`read-seed` records `payees-get` (ordered id and name), `payees-get-rule-counts` and
`payees-get-orphaned`.

Ids Actual mints (`id1`, ... from the loot-core uuid mock) are `uuid-N` by first
appearance in the case. Names and values are never normalized.

## Swift replay

`PayeeOracleReplayTests` seeds the `world` into a starter-schema database (starter rows
of the seeded tables and of `preferences` are deleted first), calls the production
store method for the case and compares:

- `writes`: the net writes derived from the outbox messages the action appended, with
  the id the store mints aliased to `uuid-1`;
- `rows`: the same payee, payee_mapping and preference tables;
- `outcome`: `ok` or `refused` (the refusal text is not compared), only for a case where
  Actual's UI sends a call. For a case where it sends nothing, only `writes` and `rows`
  are compared;
- `read-seed`: `fetchPayeeManagementSnapshot()` against the three reads: ordered id and
  display name, the nonzero rule reference counts, and the sorted ids of non-transfer
  payees with `isUnused`.

The recorded `undo` is not replayed by this suite; it is kept for a later undo oracle.
