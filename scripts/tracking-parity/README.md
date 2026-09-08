# Tracking contract fixtures

`node scripts/tracking-parity/generate.mjs <Actual checkout>` requires Actual
v26.9.0 commit `59fe126f637d858c061e1eeedbef5436c8f2225a`. It reads the
committed source via git, executes the original tracking cell callbacks with a
minimal sheet registry, and emits synthetic integer-amount fixtures. The registry
supplies finite safe integer arithmetic; it does not implement a second balance
formula. The 36 cases cover income/expense, activity signs, previous balance
signs, and previous carryover. Hidden dependencies and both savings totals are
also captured. It does not simulate the entire Actual server.

Run `scripts/test.sh unit TrackingBudgetContractTests TrackingBudgetDatabaseContractTests`.
The Phase 0 checkpoint records existing read defects as known issues; Phase 1
must remove those markers as it fixes the production path.

Conversion contract: the effective `preferences.budgetType` value alone cannot
identify an editing epoch. Persisted CRDT metadata retains the newer preference
revision after tracking → envelope → tracking, including reopening the database.
The next write phase must capture table plus that revision (and a trustworthy
import/session identity when no revision exists), and check it inside commit.
Legacy History payloads decode without an identity; they must remain visible
and conservatively lose budget Undo eligibility under approved D1. This fixture
checkpoint proves legacy decoding, not the future eligibility implementation.

Outbox contract: a committed tracking assignment keeps its original dataset and
timestamp after conversion. Two local SQLite clients receiving conversion and
assignment in different orders converge; duplicate delivery is a no-op. The
required server-backed two-client acceptance exercise remains Phase 5.

Horizon contract: Actual `actions.ts:getAllMonths` iterates to the maximum
`sheet.meta().createdMonths`, not a fixed offset from today's date. The SQLite
fixture proves the existing writer accepts an explicit December 2029 endpoint.
Phase 1 discovers that endpoint from the active table; Phase 2 must connect the
caller to it. This does not claim that today's caller chooses that endpoint.

Acceptance ownership:

| Contract area | Executable owner / remaining integration phase |
| --- | --- |
| Detection, recurrence, income, aggregation, money | TrackingBudgetDatabaseContractTests and upstream contract.json; Phase 1 read coverage |
| Calendar and discovery | Tracking read suite; Phase 1 discovery, Phase 4 lifecycle |
| Write integrity, failure, sync, conversion races | Tracking database contract suite plus existing store sync tests; Phase 2 atomic guards, Phase 5 server exercise |
| History | TrackingBudgetContractTests legacy fixture, BudgetActionUndoTests; Phase 2 mode-aware eligibility |
| Actions | Existing assignment/move/template suites; Phase 2 capability and stale-entry coverage |
| Templates | Existing tracking apply-single and template database suites; Phase 1 recurrence regression, Phase 2 identity |
| Consumers | Existing widget and Shortcut suites; Phase 4 shared typed metrics |
| Native UI/privacy | Existing grid/privacy suites; Phase 3 deterministic tracking demo and UI coverage |
