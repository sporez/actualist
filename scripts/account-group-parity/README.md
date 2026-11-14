# Account group parity harness

Generates the account group fixture from Actual's own handlers at the pinned release
(`config/parity/oracle-pin.json`, v26.11.0). This directory holds only the generator
side. `AccountGroupOracleReplayTests` replays every case through the production store's
account group commands and the Accounts screen's grouped sections.

- `generate.mjs`: runs the plan inside the oracle checkout under vitest, in two runs, and
  writes the fixture. `--check` regenerates into a temporary directory and diffs against the
  committed fixture. The Actual sources it depends on are pinned by sha256 in the file.
- `verify.mjs`: checks the committed fixture against the manifest and `cases.mjs`.
  Needs no oracle.
- `cases.mjs`: the seed world and the 20 case ids with their user input. Pure input, no
  expectations.
- `oracle-runner.template`: the loot-core vitest test (handlers) copied into the oracle for
  run 1 and removed afterwards.
- `tree-runner.template`: the desktop-client vitest test for run 2 (the sidebar tree builder),
  also removed afterwards. Both are removed in a `finally`.
- Fixture: `ActualistTests/Fixtures/ActualCore26_11_0/AccountGroups/`
  (`account-groups-contract.json`, `account-groups-manifest.json`).

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<clean checkout of the pinned tag> node scripts/account-group-parity/generate.mjs [--check]
node scripts/account-group-parity/verify.mjs
```

The oracle checkout must be at the pinned commit with a clean tree and `yarn install`
done. It is checked before and after the run and is never written to except for the
temporary runners. Synthetic data only; nothing touches a server, a real budget or
Actualist persistence.

## What a case is

The world is seeded through upstream's own db functions (`insertAccountGroup`,
`insertAccount`, `db.update`, `db.delete_`) with explicit ids: four live groups (Banks,
Cards, Investments, Empty) at `sort_order` 16384 to 65536 and one tombstoned group
(`grp-gone`); seven accounts (on-budget Checking, Savings in Banks, Card in Cards, Orphan
pointing at the tombstoned group, closed Old Account in Banks; off-budget Brokerage in
Investments and House). `insertAccountGroup` and `insertAccount` append, so the runner pins
each `sort_order` after inserting. No account has a transfer payee: the handlers under test
never read one. The clock is frozen at 2026-09-27 (`TODAY` in `cases.mjs`). The world's raw
rows are dumped once as the contract's top-level `world`.

Each case does what Actual's UI sends and calls the real handler through `runHandler`:

| Action | Actual source | Sent |
| --- | --- | --- |
| Create group | `AccountGroupsModal.tsx` ("Find or create a group…", `onSelect`) + `useCreateAccountGroupMutation` | `account-group-create {name: raw.trim()}`; the server refuses an upper-case duplicate (recorded as `handlerError`). The modal then assigns the new group to the open account; no case models that |
| Rename group | `AccountGroupRow.tsx` `onRename` + `useUpdateAccountGroupMutation` | nothing when the trimmed name is empty or equals the group's current name; else `account-group-update {id, name: trimmed}`; the server refuses an upper-case duplicate of another group |
| Move group | `AccountGroupsModal.tsx` move buttons + `useMoveAccountGroupMutation`, over the live groups in `sort_order, id` order (`account-groups-get`) | up: `account-group-move {id, targetId: groups[index - 1].id}`; down: `{id, targetId: groups[index + 2]?.id ?? null}` |
| Delete group | `AccountGroupRow.tsx` confirm + `useDeleteAccountGroupMutation` | `account-group-delete {id}` |
| Assign an account | `AccountGroupsModal.tsx` `onSelect` + `useUpdateAccountMutation` (`accounts/mutations.ts`) | `account-update {id, account_group_id}`; picking the already selected group still sends it, "None" sends `null` |
| Read groups | `accountGroupQueries.list` | `account-groups-get` (ordered `id`, `name`, `sort_order`) |
| Read tree | `useSidebarAccountTree.ts` `buildAccountSide` over `accountQueries.listOnBudget/listOffBudget/listClosed` (`accounts/queries.ts`, over `accounts-get`, ordered `sort_order, name` by `getAccounts`) | no write |

Per case the contract records `input`, `handlerCall` (method and payload sent, or `null`),
`handlerResult`, `handlerError` (an observation, never an expectation), `messages` (every CRDT
message in order), `writes` (the net cell writes: the last value per dataset, row and column,
sorted), `rows` (`account_groups`: id, name, sort_order, tombstone; `accounts`: id, name,
account_group_id, sort_order, offbudget, closed, tombstone; each sorted by id), `order` (live
group ids by `sort_order, id`) and `undo` (loot-core's `undo()` called once after the action:
its messages, rows and order; `null` when nothing was sent).

The two read cases record `read`. `read-groups` is the group list. `read-tree` is the desktop
client's sidebar tree: for on-budget and off-budget, `buckets` as `[{groupId or null,
accountIds}]` (ungrouped first, then each live group with members, in group order), and the
closed accounts as a flat id list. An account whose group is tombstoned lands in the ungrouped
bucket. The tree run's per-side `failedCount` is checked to be 0 (no account has a failed bank
sync) and dropped.

The loot-core run reads `accounts-get` and `account-groups-get` for `read-tree` and writes them
to a temporary file; the desktop-client run feeds them to Actual's own selectors and
`buildAccountSide`.

Ids Actual mints (`id1`, ... from the loot-core uuid mock) are `uuid-N` by first appearance in
the case. Names and values are never normalized.

## Swift replay

`AccountGroupOracleReplayTests` seeds the `world` into a starter-schema database (starter rows
of the seeded tables are deleted first), calls the production store method for the case and
compares:

- `writes`: the net writes derived from the outbox messages the action appended, with the id the
  store mints aliased to `uuid-1`;
- `rows` and `order`: the same tables, and the store's cached `accountGroups(budgetID:)` ids;
- `outcome`: `ok` or `refused`, only for a case where Actual's UI sends a call.

Production calls are `createAccountGroupAndRefresh`, `renameAccountGroupAndRefresh`,
`moveAccountGroupAndRefresh` (with the recorded `targetId`), `deleteAccountGroupAndRefresh` and
`moveAccountToGroupAndRefresh`. The typed text goes through as typed.

Reads: `read-groups` compares `store.accountGroups(budgetID:)` (loaded by
`refreshAccountsWithBalances`, which reads `fetchAccountGroups`). `read-tree` compares
`AccountListLayout.sections(displays:groups:preferredIDs: [])` over the store's cached account
displays and groups: each of the `.budget`, `.offBudget` and `.closed` sections' buckets as `groupId`
and account ids. Actual's closed list is flat, so the replay's expected value (not the fixture) turns
it into one ungrouped bucket `{groupId: null, accountIds}` in Actual's order; Actualist's closed
section keeps its buckets as they are.

The recorded `undo` is not replayed by this suite.
