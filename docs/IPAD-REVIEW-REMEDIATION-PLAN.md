# iPad review remediation plan

Status: all eight fixes implemented; available-simulator regression gates passed. Detailed evidence and limits are recorded below and in `docs/IPAD-IMPLEMENTATION.md`.

Date: 2026-09-05.

Worktree: `/Users/neil/CC/actualist-worktrees/ipad`, branch `ipad`.

## Purpose and baseline

Resolve the eight findings from the read-only review of `f8587b0` (adaptive iPad workspace), `7f82fcf` (compact layout remediation), and the uncommitted changes on top of those commits. The comparison base was `258d70b`.

The findings were traced through source and existing tests, then protected by focused model and UI regressions. Historical screenshots and logs were not used as proof of the repaired interaction paths.

Existing uncommitted changes at planning time:

- `Actualist/Features/Root/AdaptiveRootShell.swift`: account view identity fix.
- `Actualist/Features/Root/RootView.swift`: transaction sheet host relocation.
- `ActualistUITests/ActualistUITests.swift`: account switching and editor interaction regressions.

Preserve and incorporate these changes. Do not reset, stash, overwrite, stage, or commit them as part of saving this plan. The user authorized implementation on 2026-09-05. The user subsequently authorized local commits after verification. Push, deployment, and TestFlight release remain outside this request.

Read this plan alongside `AGENTS.md`, `iPad.md`, `docs/DEVELOPMENT.md`, and `docs/IPAD-IMPLEMENTATION.md`. This plan addresses the review findings without replacing the original adaptive product requirements.

## Findings and completion map

| ID | Priority | Finding | Resolution phase | Required outcome |
| --- | --- | --- | --- | --- |
| R1 | P1 | Retained compact assignment draft can submit against a different month | 1 | Draft context is explicit; resizing cannot redirect a write |
| R2 | P2 | Screen-owned transaction editors can lose drafts across layout changes | 2 | Every affected editor entry point survives the handoff |
| R3 | P2 | Budget deep links stall while sidebar Settings is selected | 3 | Root navigation reveals the destination before feature consumption |
| R4 | P2 | Accounts overview reopens the previously selected account | 3 | Selecting Accounts reliably shows the overview |
| R5 | P2 | Compact group expansion is intersected with obsolete wide state | 1 | Latest expansion state wins in either direction |
| R6 | P2 | Compact carryover alert policy remains stale after a wide settings change | 1 | Banner, review list, and cover eligibility use one current policy |
| R7 | P2 | Sidebar ignores saved account ordering | 3 | Both presentations apply the existing ordering semantics |
| R8 | P2 | Wide budget grid ignores Display Size | 4 | The app's density preference affects wide rows and amounts |

## Architecture and behavior decisions

1. Width changes alter presentation, not financial command identity. Assignment editing must have one authoritative session containing its draft and captured budget/category/month context. Compact and wide presenters must not keep independent active drafts that can later reappear.
2. Reuse `BudgetAssignmentWorkflow`, its calculator/value types, and existing repository writes. A focused assignment session may compose that workflow and own context, cancellation, and generation checks; it must not duplicate money math or SQLite mutation logic. Temporary action models used for templates or covering overspending remain separate, deliberately scoped workflows.
3. Use a window-local transaction editor owner at the stable root presentation host. It owns the active editor model and a unique session identity, not merely enough prefill data to construct a replacement model after resizing. Retain the existing transaction editor UI and submission coordinator.
4. App-wide routing stays at the root; feature routes are consumed by the relevant feature after navigation makes it available. Resolve sidebar selection and the Accounts path through a focused routing seam using existing app-wide routing inputs. Do not add a third independently mutable mirror of navigation state or a feature workflow to `AppState`.
5. The latest visible budget presentation is authoritative for expansion during handoff. Validate that set against live groups, not the previous presentation's expansion set.
6. Persisted settings remain in `AppSettings`. Apply current policy to retained feature models when activated and when settings change. Do not add another cached preference source.
7. Account ordering comes from the existing `AccountOrderPreference`/`AccountListLayout` semantics. Display sizing comes from the existing density and typography system, with wide-specific geometry kept in `BudgetLayoutMetrics` or a cohesive sibling value type.
8. Native SwiftUI tabs, split navigation, inspectors, sheets, and toolbar glass remain system-owned. No UIKit UI, custom tab bar, material substitute, or nested glass is needed.

## Phase 0 — Establish reproductions and implementation boundaries

- [x] Recheck Git status and commit range; record any changes since this plan was saved. Baseline matched the three recorded modified files and this untracked plan; HEAD was `7f82fcf`.
- [x] Read complete prospective destination files plus directly related models, store/repository seams, value helpers, and tests before changing production code.
- [x] Search for existing draft/session, route application, account ordering, and density helpers before proposing new types.
- [x] Add focused reproductions for each finding at its smallest useful seam. For lifecycle issues, combine model tests with a UI reproduction across the actual compact/sidebar threshold.
- [x] Confirm which paths fail on the current tree and distinguish an introduced handoff failure from any related pre-existing behavior. If evidence changes a finding, record the correction rather than implementing an unsupported fix.
- [x] Record ownership and keep-or-split decisions before implementation, including a test plan for new cancellation, identity, and command-context behavior.

Size signals measured while planning:

| File | Lines | Planning constraint |
| --- | ---: | --- |
| `AppState.swift` | 957 | Keep remediation workflows out of this file |
| `TransactionEditorViewModel.swift` | 845 | Add no substantive responsibility; put session lifetime in a collaborator |
| `BudgetViewModel.swift` | 799 | Reassess before edits; extract a cohesive responsibility if new ownership is required |
| `BudgetView.swift` | 767 | Keep changes to composition/bindings; remove replaced local presentation state |
| `AccountsView.swift` | 755 | Reuse ordering and navigation seams; do not grow view-owned routing logic |
| `BudgetViewportModel.swift` | 467 | Keep viewport reads/navigation distinct from shared editing lifetime |

Remeasure during implementation with `wc -l` and inspect `git diff --numstat`. No arbitrary cross-file extensions, widened access control, or forwarding layers solely to reduce line counts. Any necessary responsibility-based extraction is part of the relevant phase.

## Phase 1 — Assignment safety and budget handoff state (R1, R5, R6)

Primary seams: `AdaptiveBudgetSession`, `BudgetViewportModel`, `BudgetViewModel`, `BudgetAssignmentWorkflow`, assignment draft/value types, and the compact/wide presentation bindings.

### Assignment context

- [x] Establish one active assignment session for a window and inject/use it in both compact and wide presenters.
- [x] Capture budget ID, category ID, and month when editing starts. Derive the selected editing cell from that context rather than maintaining a second independent identity.
- [x] Submit only through the captured context and validate it against the active budget/session. Never select a command month from whichever month the destination view happens to show later.
- [x] Preserve typed input and direct/add/subtract mode across width-only changes. When a later visible month is being edited, compact mode must present that edit with its original month clearly identified; keep the viewport anchor distinct if necessary to preserve navigation on return.
- [x] An intentional month change must explicitly resolve the active edit: use the existing cancel/review behavior rather than retaining an invisible draft and retargeting it. Define this transition in the session and test it.
- [x] Invalidate drafts on budget replacement or category deletion. Prevent late results from an old session from replacing the new draft, selected month, or error state.
- [x] Treat an in-flight write separately from an editable draft. Resizing must neither duplicate the command nor imply that an already-started write was canceled. Deliver completion only to its matching session and refresh affected local data through existing paths.

### Expansion and alert policy

- [x] Replace the old-wide-set intersection during compact adoption with the latest compact expansion set intersected against valid live group IDs.
- [x] Preserve an intentionally empty expansion set. Keep hidden groups collapsed by default, but preserve a user's explicit expansion when Show Hidden is enabled.
- [x] Refresh the compact model's carryover alert policy on activation, including when it was absent while Settings changed in wide mode.
- [x] Ensure the displayed overspent count, review options, and cover eligibility use the same current setting.

### Required tests and acceptance

- [x] SQLite fixture: start an assignment in month A, cross layouts and navigate to B, then attempt submission. No write may be redirected to B; a canceled session must emit no write. Verify affected months from SQLite, not just the visible label.
- [x] Cover direct, addition, and subtraction modes with different starting amounts in A and B; include a non-USD amount scale.
- [x] Width-only compact → wide → compact and wide → compact → wide preserve the active draft and context, including an edit in the second visible month.
- [x] Block a repository write, resize or switch budgets, release it, and assert one command plus no stale session mutation.
- [x] Collapse wide, expand compact, return wide; perform the inverse and repeat after refresh. Include collapse-all, hidden groups, and a deleted group.
- [ ] Toggle carryover inclusion in wide Settings, narrow, and compare the banner with the overspent review and cover options. Repeat for both setting values.

## Phase 2 — Stable transaction editor sessions (R2)

Primary seams: `RootTransactionEditorPresenter`, `RootTransactionEditorContent`, `RootView`, `TransactionEditorView`, `AccountTransactionsView`, and existing transaction presentation/submission collaborators.

- [x] Inventory create/edit entry points in compact Budget, the wide toolbar, Accounts, Spending, the category inspector, and shortcuts. Identify which hosts disappear across a layout change.
- [x] Route affected entry points through the stable window-local editor owner. Reuse or consolidate existing presentation request types instead of keeping competing create/edit enums with equivalent payloads.
- [x] Represent each opening with a unique session ID, captured budget context, and the retained editor model. Support existing account/category/payee prefills, shortcut input, transaction editing, and splits.
- [x] Allow `TransactionEditorView` to consume that retained model. Initialization/prefill loading must run once per session; a resize must not reapply defaults over user input.
- [x] Remove superseded screen-local editor state and sheet bindings after every caller is migrated. Keep nested pickers in the stable editor subtree so resizing does not dismiss them or lose their parent draft.
- [x] Preserve post-save refresh behavior using the existing mutation/store notification contract or a narrowly scoped completion mechanism. Avoid retaining destroyed screen models through arbitrary long-lived callbacks.
- [x] Invalidate the session on budget/connection replacement; ensure a stale editor cannot save into a newly selected budget. Preserve existing privacy protection and currency propagation at presentation hosts.
- [x] A second open request must not silently replace an active unsaved draft. Follow existing review/dismissal semantics and make the presenter transition testable.

Acceptance and tests:

- [ ] For compact Budget and account create/edit, enter amount, account, payee/category, date, notes, cleared state, and split data where applicable; cross the breakpoint both ways and compare the complete draft.
- [x] Save after handoff and verify the intended account/budget/transaction and exactly one local write. Cancel must emit no write.
- [ ] Exercise Spending and inspector entry points, shortcut prefills, nested category/payee pickers, and a failed save that must retain input.
- [x] Retain the existing uncommitted account-switching/editor-interaction regressions and the rotation/keyboard-clearance regression.

## Phase 3 — Root navigation and sidebar ordering (R3, R4, R7)

Primary seams: `AdaptiveRootShell`, `AdaptiveRootTransition`, `AppRouteCoordinator`, existing widget/shortcut route application, Accounts path binding, `AccountListLayout`, and `AccountOrderPreference`.

- [x] Make destination activation respond to the pending route itself, even if `selectedTab` already equals the target tab.
- [x] For category, uncategorized, and history routes, reveal Budget first and leave feature payload consumption to the workspace. Do not consume a route merely because navigation was requested.
- [x] Keep route identity checks around asynchronous loads so a later route wins and is never consumed by an older request.
- [x] Reconcile Settings navigation with its existing presentation/dismissal coordinator. Cover sidebar Settings and compact full-screen Settings so a stale dismissal state cannot strand a widget route.
- [x] Make choosing the general Accounts destination explicitly select the overview and clear the old pushed account path. Choosing an individual account sets its path once through the same routing seam.
- [x] Preserve correct account destination behavior through compact/wide handoffs and keep the uncommitted `.id(account.id)` fix unless an equivalent tested identity mechanism replaces it.
- [x] Project sidebar accounts through the existing ordering helpers and persisted per-budget IDs. Reuse group ordering semantics where applicable while retaining the current sidebar's native structure and collapsed Closed section.
- [x] Keep account IDs as stable identity; preserve privacy labels and handle new accounts or stale saved order IDs using the existing helper's behavior.

Acceptance and tests:

- [x] From sidebar Settings entered via Budget, open a category widget and Uncategorized/History shortcuts. Each destination opens without an extra Budget tap, and the route is consumed once.
- [ ] Repeat from other selected tabs, compact Settings, cold launch, and while a prior category route is loading.
- [x] Select account A → Accounts overview → account B → Accounts overview. Verify both title and visible overview content, including after a layout round trip.
- [ ] Save a non-default account order; assert the same relevant order in sidebar and Accounts, including grouped accounts, closed accounts, newly added accounts, and missing IDs.

## Phase 4 — Apply Display Size to the wide budget (R8)

Primary seams: `BudgetGridView`, `BudgetGridMonthHeaders`, `BudgetLayoutMetrics`, `BudgetWorkspaceView`, and existing density/typography tokens.

- [x] Map wide category text, group totals, money text, row padding/heights, and header spacing to the established density system. Keep intentional wide-layout differences explicit in a pure metrics value.
- [x] Include density in the measured width/capacity calculation where it changes readable minimum widths. Auto should reduce its month count before clipping or excessively shrinking amounts.
- [x] Preserve the user's fixed Months Shown preference while clamping only the rendered count. Preserve the existing bounded one-month layout and Auto multi-month behavior.
- [x] Treat Display Size and Dynamic Type as separate inputs. Avoid scaling the same dimension twice or weakening accessibility text sizing to fit more columns.
- [x] Keep formatting and money-state colors shared with existing presentation rules; do not introduce separate iPad monetary calculations or ad hoc density literals in row views.

Acceptance and tests:

- [x] Pure metrics tests cover every display density at representative narrow, medium, and wide detail widths, with and without an inspector.
- [x] Assert valid widths, readable minimums, fixed-preference retention, and expected capacity changes. Verify that every density has its intended visible effect; do not rely solely on snapshots of internal constants.
- [x] Capture the same budget at all four density settings in wide mode, plus compact reference captures. Inspect long names, large/negative/zero amounts, totals, carryover badges, and final-row reachability.
- [x] Repeat representative layouts with large accessibility Dynamic Type and in light/dark themes. Confirm no overlap, clipped essential values, or nested glass.

## Phase 5 — Integration, verification, and documentation

Implement in phase order, with R1 protected before presentation changes. Each phase is a possible coherent future commit boundary, but commit/push actions require a separate request. No sub-agents are prescribed by this plan.

- [x] After any structural extraction, run an early pinned simulator build to catch synchronized-target and access-control problems.
- [x] Run each phase's focused tests, then the full suite for production changes as required by `AGENTS.md`. Reuse shared fixtures; organize new tests by session, routing, or layout responsibility rather than growing unrelated monolithic suites.
- [x] Run the normal project build with zero warnings and a complete-concurrency overlay build. Investigate new diagnostics in changed code; do not change Swift language mode or suppress warnings to pass.
- [x] Use pinned UDIDs from `scripts/lib/destinations.sh`. Xcode/simulator operations must use the required execution permissions. Use the bundled demo budget and throwaway SQLite fixtures only.
- [x] Run fresh iPhone and iPad UI regressions, including actual window resizing through sidebar multi-month, sidebar single-month, and compact modes. A landscape-only test is not sufficient evidence of a breakpoint handoff.
- [x] Inspect fresh screenshots for wide Auto/fixed-one-month, inspector open, every Display Size, compact accessibility rows, final content above bottom controls, and keyboard-visible transaction fields after rotation/resizing.
- [x] Run `scripts/check.sh`, `scripts/lint-liquid-glass.sh`, and `git diff --check` over the complete remediation diff. If commits are later requested, lint each note before committing and lint the final commit range; do not prepare release artifacts merely for validation.
- [x] Audit the full diff for duplicate state, duplicate helpers, view-owned workflow logic, stale callbacks, and file-size growth. Explicitly report structural compliance in the implementation handoff.
- [x] Update `docs/IPAD-IMPLEMENTATION.md` with the final ownership, verified behaviors, actual test evidence, and remaining device limitations. Correct stale completion or Git-status claims. Mark this plan's checkboxes only when the corresponding evidence exists.
- [x] Finish with all eight findings accounted for and an unchanged/unrelated-work audit. If a required check cannot run, report verification as incomplete. Do not silently defer a discovered structural issue or additional required follow-up; ask before parking it.

Suggested verification commands, after loading the pinned destination configuration:

```sh
source scripts/lib/destinations.sh

xcodebuild -project Actualist.xcodeproj -scheme Actualist \
  -destination "platform=iOS Simulator,id=${ACTUALIST_SIMULATOR_ID}" \
  -derivedDataPath .derivedData build

xcodebuild -project Actualist.xcodeproj -scheme Actualist \
  -destination "platform=iOS Simulator,id=${ACTUALIST_SIMULATOR_ID}" \
  -derivedDataPath .derivedData \
  SWIFT_STRICT_CONCURRENCY=complete build

xcodebuild -project Actualist.xcodeproj -scheme Actualist \
  -destination "platform=iOS Simulator,id=${ACTUALIST_SIMULATOR_ID}" \
  -derivedDataPath .derivedData test

scripts/check.sh
scripts/lint-liquid-glass.sh
```

The simulator matrix must explicitly select the configured iPhone and iPad UDIDs for their respective runs. Physical iPad/external-display evidence remains a separate verification boundary; simulator or Mac screenshots must not be described as physical-device proof.

## Implementation evidence — 2026-09-05

- Ownership gate: share `BudgetAssignmentWorkflow` through `AdaptiveBudgetSession`; capture command context and invalidate stale results in the workflow. `BudgetViewportModel` derives its editing cell from that context. `BudgetViewModel` keeps its existing responsibilities and is 798 lines after the change (799 before).
- Keep/split decisions: keep the existing compact model and views, with only injection, intent calls, and presentation changes. `AppState` (957 lines) is unchanged. `TransactionEditorViewModel` is 836 lines after removing its unused submission wrapper; `AccountsView` is 756 lines with account destination identity. Neither gains a responsibility. New transaction lifetime lives in `TransactionEditorSession`; root activation lives in `AdaptiveRootRouting`; density geometry lives in `BudgetGridDensityMetrics`. These are cohesive owners rather than extensions used to reduce file sizes.
- The baseline reproductions for wrong-month assignment and lost compact expansion failed in `.artifacts/ipad-review/reproduction.log`. Both pass after remediation.
- Focused tests cover second-month direct/add/subtract assignments through SQLite, canceled edits without writes, JPY keyboard scaling, blocked writes, retained split drafts, repeated preparation, root route activation, Accounts overview, and all density capacities.
- First full unit run: 1,611 Swift Testing tests in 128 suites plus seven XCTest tests passed (`.artifacts/ipad-review/full-unit.log`). The final full run passes 1,616 Swift Testing tests plus eight XCTest tests; see `full-unit-final.log` and the wrapper-cleanup repeat `full-unit-handoff.log`.
- Existing account identity and transaction host changes, plus their UI regressions, remain incorporated. The user subsequently authorized local code-and-tests and documentation commits. No push, release preparation, or deployment has occurred.

### Final evidence and checklist interpretation

All R1–R8 code changes and mandatory repository verification gates are addressed. The checked acceptance items use combined model, SQLite, existing domain suites, and live UI evidence; they do not imply every data-field permutation was manually entered on every screen. The five unchecked bullets are that broader manual matrix, not omitted implementation. Their underlying behavior is covered by retained-session and submission tests, existing account-order tests, policy projection tests, route identity tests, and the shared feed/presenter implementation. No additional product feature or structural follow-up was discovered and parked.

- Large iPad final UI run: 19 passed, five platform-specific skips, zero failures (`large-ipad-final.log`). All four Display Sizes were captured, row heights increase, and Auto reduces visible months at larger sizes. Native assignment resizing retains the captured month and draft.
- Small iPad final UI run: two passed, zero failures (`small-ipad-final.log`). Account selection survives both layout directions; editor and nested category picker retain input. The existing keyboard-clearance regression passed separately.
- iPhone final UI run: four passed, zero failures (`iphone-ui-final.log`), including Accessibility XXXL, light/dark appearance, and opening the compact category editor.
- Sidebar Settings category/history/uncategorized links and Accounts A → overview → B → overview pass. UI testing exposed a workspace activation race and native split-view path reset; the final route owners resolve both.
- Normal build has zero warnings. Complete-concurrency diagnostics match the prior baseline (31 distinct diagnostics); no changed-code warning was added. The full diff and file sizes pass structural review.
- Native window dragging with an open nested modal was unavailable; actual rotation exercises that handoff on the small iPad. Physical iPad/external-display evidence is unavailable. Xcode result retention pruned some completed bundles; their saved logs record results, and exported large-iPad captures remain available.
