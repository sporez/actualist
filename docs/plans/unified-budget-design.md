# Unified envelope and tracking budget design

Approved design addendum, 2026-09-08. Implementation is **not started**.
This addendum supersedes the original tracking presentation requirements for
three expense columns, stacked tracking rows, and tracking-specific grid widths.
It preserves tracking financial semantics and all completed backend work.
The next session should implement this addendum before final tracking acceptance.

## Progress Tracker

- [x] **Planning — completed 2026-09-08.** User approved sharing the envelope
  design on iPhone and iPad. Scope, ownership, verification and checkpoint
  strategy are recorded here; documentation review and mechanical gate passed.
  Recorded by the documentation commit introducing this file.
- [ ] **Shared presentation — not started.** Replace mode-specific row/grid
  layouts with the shared two-value design described below. Preserve native
  editing, navigation, selection, details and accessibility behavior.
- [ ] **Verification and handoff — not started.** Validate both budget modes on
  iPhone and iPad, update affected tests and the governing tracker, and record
  implementation commits and evidence before marking complete.

## Checkpoint and starting procedure

Start from the clean checkpoint immediately preceding implementation. The
tracking feature commit `37041fb` immediately before this addendum records the existing
working design, shared consumers, lifecycle behavior and rollover fix. Record
that baseline in the local tracking plan before implementation. The addendum
commit itself is the complete pre-refactor checkpoint including these instructions.

Confirm `git status --short` is empty and record `git rev-parse HEAD`. Create a
`codex/unified-budget-design` branch if a separate branch is useful. Do not reset,
rewrite or discard the checkpoint. Keep implementation commits separate so the
new design can be compared with the old design or reverted independently.

Read AGENTS.md, the local roadmap/tracking plan when present, and learned
mistakes before editing. Mark the shared-presentation tracker in progress.
Read complete destination files and related models/tests, measure their sizes,
and search for existing presentation helpers before choosing the implementation.

## One shared design

Use the existing envelope Budget screen as the visual and interaction baseline.
Budget mode must not select a separate row family, vertical arrangement, spacing
system or adaptive width policy. Device width and Dynamic Type may still select
shared adaptive layouts in both modes.

| Surface | Envelope | Tracking expenses | Tracking income |
| --- | --- | --- | --- |
| First amount | Assigned | Budgeted | Budgeted |
| Second amount | Available | Balance | Received |
| Second amount source | Category balance | Category balance | Income activity |
| Detail activity | Existing activity | Spent | Received |

On iPhone, retain the compact category name plus two trailing amount columns.
Put labels once in each group header rather than repeating them under every
category name. Use the existing colored amount-pill treatment for the second
value, including tracking income Received, with the same positive/zero/negative
theme policy. Only expense balance pills show the existing rollover indicator.
Preserve density settings, category icons, note/template markers, hidden-state
styling and shared accessibility-size fallback layouts.

On iPad, retain the existing category column, month headers, two values per
month, group totals, multi-month preference, selection, assignment popover,
keyboard navigation and category inspector/detail behavior. Tracking must not
reserve a third money column or show fewer months solely because of budget
mode. Header labels for income and expense groups must identify the second
value correctly; avoid a misleading global Balance label over income Received.
Use one shared group/cell header solution when row kinds need different labels.

First-value taps continue the existing assignment flow. Second-value taps open
category details/activity, including income Received. On compact layouts,
preserve the existing assignment panel and its Details action. Spent remains
available in category details; removing its main-grid column must not remove
transaction access or change expense activity calculation.

## Tracking specifics that remain

- Projected Savings for current/future months; Saved/Overspent for completed
  months. Preserve the existing planned/actual breakdown and summary behavior.
- Editable tracking income and expense categories, including past months.
- Expense rollover with tracking reset semantics. Income has no balance or
  rollover control. Repeated rollover toggles must preserve the open feed.
- Tracking deficit review opens activity; no envelope Move Money/Cover actions.
- Synced budget-mode identity, conversion invalidation, offline local writes,
  outbox, templates, widget/Shortcut meanings and calendar refresh stay intact.
- Sample-value privacy remains consistent between rows, group totals, summaries,
  accessibility text and edit baselines. Display projections never decide writes.

This is a presentation refactor. Do not change shared money calculations,
SQLite/table routing, budget conversion, sync, widget design, Shortcuts, settings
or marketing copy merely to unify the screen.

## Ownership and likely touch points

Use `BudgetModePresentation` or a narrowly scoped pure presentation value for
labels, displayed second-value selection and action semantics. Views should
consume formatted display values; do not move activity signs, money conversion,
command construction or feature state into SwiftUI actions/bindings.

Inspect `BudgetRows`, `BudgetTrackingAmounts`, `BudgetGridView`,
`BudgetGridMonthHeaders`, `BudgetGridPresentation`, `BudgetLayoutMetrics`,
`BudgetWorkspaceView`, assignment presentation and their tests. Reuse the common
row/value/pill components. Remove `BudgetTrackingAmounts` if it becomes unused;
do not keep the old tracking layout behind a dormant flag. Remove mode-specific
width inputs only after checking every caller.

Keep screen state in existing feature models/workflows and cache ownership in
the store. Add no feature workflow to AppState. Reassess large files before any
net growth, following the architectural size rules rather than arbitrary splits.

## Verification

Plan verification before editing. Replace tests asserting the retired three-column
layout with tests for the shared contract; retain live financial and lifecycle
assertions. At minimum:

- Pure presentation: both expense modes and tracking income labels/values,
  negative/zero/positive tones, formatting and privacy-safe edit baselines.
- Layout: identical month capacity and column widths for equivalent envelope
  and tracking containers, density settings and Dynamic Type. No clipping with
  long names, large currency amounts or the inspector open.
- iPhone UI: both modes, light/dark, category assignment and Details, tracking
  income Received, expense rollover on/off with transactions still visible,
  deficit review, hidden/collapsed groups and accessibility-size layout.
- iPad UI: both modes in portrait/landscape, one/multiple months, available
  narrow-width fallback, assignment save/cancel, keyboard navigation and
  category details. Update retired activity-cell test selectors intentionally.
- Use the bundled envelope/tracking demos and pinned simulator UDIDs. Inspect
  screenshots of the affected layouts, not only test pass/fail results.
- Run affected unit suites and full UI coverage for this broad Budget layout
  change under AGENTS.md. Run the full unit suite if shared money/database
  logic or a broad model refactor becomes necessary. Complete-concurrency
  overlay is required if async/state isolation changes; otherwise reuse the
  unchanged checkpoint's strict-build evidence.
- Run `scripts/check.sh`, inspect the entire completed diff, and report the
  architecture/duplication audit. Normal builds must remain warning-free.

Record completion date, commits, exact checks, screenshots and any outstanding
required validation in both this tracker and the local governing plan. Final
tracking acceptance, including synthetic two-client convergence, remains a
separate required phase; this layout change does not silently complete it.
