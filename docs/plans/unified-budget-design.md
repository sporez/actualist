# Unified envelope and tracking budget design

Approved design addendum, 2026-09-08. Implementation is present; verification is **in progress after Mac unlock** (2026-09-08).
This addendum supersedes the original tracking presentation requirements for
three expense columns, stacked tracking rows, and tracking-specific grid widths.
It preserves tracking financial semantics and all completed backend work.
Resolve the verification blockers below before final tracking acceptance.

## Progress Tracker

- [x] **Planning — completed 2026-09-08.** User approved sharing the envelope
  design on iPhone and iPad. Scope, ownership, verification and checkpoint
  strategy are recorded here; documentation review and mechanical gate passed.
  Recorded by the documentation commit introducing this file.
- [ ] **Shared presentation — implemented, checkpoint authorized 2026-09-11; verification pending.** Replace mode-specific row/grid
  layouts with the shared two-value design described below. Preserve native
  editing, navigation, selection, details and accessibility behavior.
- [ ] **Verification and handoff — in progress, Escape-key investigation (2026-09-08).** Validate both budget modes on
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

## Implementation record

Baseline: clean `a15bf837f10bf60f9c2508e5f7d27de30a30a613`.
Ownership: BudgetModePresentation selects the second value and labels; a shared
amount pill owns theme rendering. Existing compact rows and grid cells retain
interaction owners. Group headers label both values in both modes. Layout inputs
lose budget mode entirely. All destinations are below 800 lines; keep their
current responsibilities. BudgetViewModel, store, and AppState need no changes.
Verification: presentation/formatting/privacy and layout unit coverage, full UI
suite, iPhone light/dark/accessibility and iPad adaptive screenshots.

## Verification record — 2026-09-08

Implementation was uncommitted during this verification. On 2026-09-11 the user explicitly requested committing all pending work; the checkpoint preserves the open Escape-key acceptance item.

- Normal simulator build and subsequent test builds passed with zero warnings.
- Full unit coverage passed: 1,765 tests in 150 suites, including display labels,
  selected amounts, tones, currency formatting, private group/category totals,
  assignment baselines, layout density/capacity and existing keyboard workflows.
- Full UI coverage was attempted in separate envelope/tracking demo groups.
  The first mixed run found a retained tracking fixture; clean installs were used
  for the fixture groups. All six tracking iPhone tests passed. Envelope iPhone
  coverage passed after an isolated theme-menu retry; device-specific tests skip
  on the phone and were exercised on iPad.
- iPad tracking income save/details and past-month rollover/themes/privacy passed.
  The new shared-column/cancel/month-preference/portrait regression passed.
  Full-screen and direct simulator captures verify a three-month tracking grid,
  single-month layout and portrait rendering. iPhone dark/light, income Received,
  expense Balance and accessibility captures were inspected.
- The iPad envelope run exercised all wide/adaptive suites. Density passed on
  retry. Five remaining failures reproduce on untouched checkpoint `a15bf83`
  using the same simulator: Accounts editor dismissal, sidebar account editor
  dismissal, Budget transaction category picker, nested picker/resize, and the
  inspector scroll-position check (19-point drift on the checkpoint too).
  The user authorized resolving all genuine failures here on 2026-09-08 and
  required root-cause fixes. Investigation is in progress; baseline reproduction
  does not waive acceptance. No thresholds or assertions will be weakened to pass.
- Direct hardware-key dispatch is still unverified: XCTest's typeText cannot
  synthesize into this non-text focus target, and computer control reports the
  Mac is locked. Existing keyboard domain/viewport tests passed; no keyboard
  production code changed. An unlock has been requested.
- Structural audit passed: shared pure display projection and one pill renderer;
  no money calculations or command values added to views, no new view state,
  and no changes to AppState, store, database or sync. BudgetRows shrank from
  458 to 396 lines; BudgetGridView from 267 to 238. The new pill has 43 lines
  and mode presentation has 63. The retired tracking component and mode-specific
  width input are removed. Final mechanical gate and full diff review passed.
- No concurrency boundaries changed. The checkpoint strict-overlay evidence
  remains applicable to the unchanged async code; no new overlay was required.

Evidence: `.artifacts/unified-budget-design/` contains build/test logs, exported
captures and the retained final iPad result bundle. `baseline-ipad-ui.log`
records the five pre-existing failures. Phase 5 convergence and final tracking
acceptance remain separate and are not marked complete by this UI adjustment.

### Root-cause resolution in progress — 2026-09-08

The user required fixing genuine failures here and tracing causes rather than
masking them. The grid's unused row-ID/top-anchor binding causes the inspector
round trip to move both axes. Removing it passes the unchanged vertical check;
the final regression also checks horizontal position. Scroll offset remains
owned by the native retained ScrollView; unused presentation state is removed.

The four editor failures have a different cause: iPadOS 26 presents a modal
number-pad popover with an outside-tap dismissal layer. Tests attempted controls
underneath it. A diagnostic repeated three launches, demonstrated blocked hit
testing with the popover, dismissed it by tapping outside, and verified editor
hit testing and Category navigation without product changes. The shared UI test
helper handles that native dismissal only when the number-pad popover exists;
all original editor interaction assertions remain. Docked keyboard runs proceed
without dismissal. This replaces the earlier speculative coordinate diagnosis.
Focused final validation is running; no failure threshold is weakened.

### Verified causes and remaining keyboard check — 2026-09-08

- Scroll regression passes with the original vertical tolerance and an added
  one-point horizontal assertion (`root-fixes-five.xcresult`). The native scroll
  view now owns its offset; no delayed restoration or compensation was added.
- All four original editor interaction failures clear after native number-pad
  dismissal. The nested-picker native-resize case reaches its existing platform
  availability skip, so that resize is not counted as passed. Both main-grid and
  assignment native-resize tests pass (`native-resize-final.xcresult`), and the
  nested picker/draft passes actual compact/wide rotation on the pinned iPad mini
  (`mini-editor-rotation.xcresult`).
- Hardware digits 7 then 8 reach the existing assignment handler and render
  7.00 then 78.00. Escape does not reach it. Temporary event instrumentation,
  an explicit Escape subscription and a native cancel shortcut did not resolve
  event delivery; all diagnostic production edits were removed. The failing
  `testWideHardwareKeyboardInputAndEscape` remains separate from layout tests.
  Direct Simulator keyboard verification needs an unlocked Mac; requested again.
  This unresolved failure keeps verification incomplete. No failure is waived.
- Final structure: BudgetGridView 235 lines, BudgetWorkspaceView 176 lines;
  no additional production responsibility, state, async change or money logic.
  The number-pad helper is UI-test support only. Existing 1,765-unit evidence
  remains applicable; final mechanical/diff review passed. Final grid presentation/portrait test passed
  (`grid-presentation-final.xcresult`), with screenshots inspected and zero normal
  build warnings. The isolated Escape test still fails (`escape-unresolved.xcresult`).

### Mac-unlocked comparison — 2026-09-08

The user unlocked the Mac. The isolated test still fails in
`escape-unlocked.xcresult`. Desktop control can operate Simulator menus and
assignment buttons but did not forward ordinary digits reliably, so it cannot
establish an independent Escape result. Simulator keyboard connection and
capture routing were inspected; capture mode explicitly reserves Escape to
release capture. No product change was made. Requested an actual keyboard
comparison on the visible demo (7, then Escape) to distinguish real app behavior
from synthesized input. Verification remains open pending that observation.

### September 11 checkpoint

The user requested committing all pending work and publishing a fresh device build.
This checkpoint reuses the unchanged-source evidence above and preserves the
unresolved iPad Escape-key check. The fresh normal test build and signed iPhone
archive/export passed without warnings; mechanical and structural review passed.
No product code changed during this checkpoint. Final UI acceptance remains open.
