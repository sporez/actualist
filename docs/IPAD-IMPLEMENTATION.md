# Adaptive iPad implementation

Compact windows use native tabs and the compact Budget screen. Wider windows use a native sidebar and an Auto or fixed 1–5 month viewport. Native inspectors, sheets, and toolbar glass remain system-owned.

## Integration into main — 2026-09-05

Integration combines iPad commit `7425270` with main commit `5ada9ce` in an isolated worktree. The shared assignment workflow and retained transaction session remain authoritative. Main's picker cleanup, hidden-overspending selection fix, database optimizations, sync retry recovery, and version/build settings are preserved.

The loader-owned initial rule preview from main was removed because the retained session already owns that step behind its context and cancellation checks. A new SQLite regression first reproduced duplicate appended notes, then passed with exactly one preview across repeated preparation. No feature state or workflow was added to `AppState`; its only iPad addition persists the month-display setting.

The full unit suite passed 1,652 Swift Testing tests plus eight XCTest tests. Normal build has zero warnings. Complete-concurrency build passes with the same 30 unique file/message signatures as main (including two compiler key-path signatures); repeated batch diagnostics and shifted line numbers are deduplicated. The mechanical and structural gates pass; models retain their existing responsibilities and remain below 800 lines. AppState remains at 938 lines with only the existing settings seam extended.

On newly created demo-only simulators, 19 large-iPad, three iPad mini, and four iPhone UI tests passed. Five large-iPad tests skipped for platform or simulator limitations. Captures were inspected for native chrome, readable values, light/dark appearance, accessibility sizing, window resizing, retained assignment/editor/picker context, and keyboard clearance. Existing simulators and real budget data were untouched. Logs and result bundles are retained locally under `.artifacts/ipad-integration/`. No physical iPad or external-display verification is claimed.

The unfiltered shared Xcode scheme also passes on the isolated iPhone: all 1,660 unit tests and four UI tests passed, with 20 expected iPad-only UI skips. The native-resize test now checks the window size before its wide-grid assertion; its previous iPhone failure was reproduced first, and the corrected test passed again on the large iPad.

## Review remediation — 2026-09-05

All eight findings in [the review plan](IPAD-REVIEW-REMEDIATION-PLAN.md) are implemented. The remediation is recorded in a code-and-tests commit and a documentation commit on top of `7f82fcf`. The user authorized these local commits after verification. No push, release preparation, or deployment was performed.

| Finding | Final ownership and outcome |
| --- | --- |
| R1: assignment context | `AdaptiveBudgetSession` injects one `BudgetAssignmentWorkflow` into both models. The workflow captures a unique budget/category/month context. Width changes preserve input and mode; deliberate month navigation invalidates the edit. Already-started writes retain their command and cannot overwrite a replacement draft. Completion refreshes the currently displayed data. |
| R2: editor lifetime | `RootTransactionEditorPresenter` owns a unique `TransactionEditorSession` and retained editor model. Budget, Accounts, Spending, category feeds, and shortcuts share the root sheet. Preparation runs once; replacement requests do not overwrite unsaved input. Budget/connection changes invalidate the session. Existing mutation notifications refresh affected screens. |
| R3: budget routes | `AdaptiveRootRouting` reveals Budget without consuming feature payloads. `BudgetWorkspaceActions` loads the workspace before applying category routes and checks route identity after suspension. Settings host removal releases its existing dismissal coordinator. |
| R4: Accounts overview | Selecting Accounts clears its pushed path. Sidebar account destinations retain explicit account identity. Sidebar selection does not push into a disappearing compact stack; root routing transfers the selected account when compact mode becomes active. |
| R5: expansion | The latest compact expansion set is validated against live group IDs. Empty sets and explicit hidden-group expansion survive handoffs and refresh. |
| R6: carryover policy | Each activation copies the persisted policy into the retained compact model. Banner and cover/review projections continue to use that model's single policy. |
| R7: account order | Sidebar and Accounts both use `AccountListLayout` with the saved per-budget order and existing group/closed-account rules. |
| R8: Display Size | `BudgetGridDensityMetrics` connects existing density/typography tokens to row geometry and column capacity. Density and Dynamic Type remain separate inputs. Fixed preferences remain persisted while rendered counts clamp to space. |

## iPad branch structural review before integration

The complete diff was reviewed for duplicate state, stale callbacks, view-owned commands, and file growth. New owners are cohesive session, routing, and geometry types. No feature workflow was added to `AppState` (957 lines, unchanged). `BudgetViewModel` is 798 lines (799 before); its responsibilities remain unchanged. `TransactionEditorViewModel` is 836 lines (845 before), with only its unused AppState submission wrapper removed. `AccountsView` is 756 lines (755 before), adding only account destination identity. No access control was widened for file splitting.

Changed view state remains presentation-only. Money calculation, command identity, submission, loading, and route application remain in models/workflows. The repository/store, SQLite mutation, sync, credentials, and privacy policy implementations are unchanged. New Swift files are under synchronized target directories.

## iPad branch verification before integration

- Full unit suite: **1,616 Swift Testing tests in 128 suites plus eight XCTest tests passed** (`.artifacts/ipad-review/full-unit-final.log`). The final repeat after removing the unused wrapper also passed all 1,624 tests (`full-unit-handoff.log`).
- Focused handoff/session/routing tests passed. SQLite fixtures verify direct/add/subtract assignments affect only the captured month, canceled edits produce no write, and a retained split draft saves one transaction. Tests also cover JPY input, blocked writes, stale completion, expansion, policy activation, route replacement, and density capacity.
- Normal build: zero warnings (`normal-build-handoff.log`). Complete-concurrency build succeeds with the same **31 existing diagnostics** as the prior baseline: 29 source-file/message pairs and two compiler key-path diagnostics. No new warning or suppression was introduced (`concurrency-build.log`, `concurrency-comparison.txt`).
- Large iPad: **19 UI tests passed, five platform-specific tests skipped, zero failures** (`large-ipad-final.log`). Includes real native resizing across multi-month/sidebar-one-month/compact layouts, assignment retention/save, all four densities, Settings routes, Accounts navigation, inspector, light/dark appearance, and accessibility.
- Small iPad: **two final UI tests passed**, including account editor/picker retention, account-path round trips, and compact category-editor presentation (`small-ipad-final.log`). The separate keyboard-visible rotation regression also passed (`small-ipad-ui.log`).
- iPhone: **four UI tests passed** for standard/Accessibility XXXL layout, light/dark appearance, and category editor (`iphone-ui-final.log`).
- Mechanical gate, Liquid Glass lint, and whitespace checks pass. Commit TestFlight notes were linted; no release artifact was created.

Logs are under `.artifacts/ipad-review/`. The large-iPad captures are exported to `final-large-captures/`; earlier density and handoff captures are in `ui-attachments/`. The images were inspected for readable money values, layout clearance, native chrome, and retained edit context. Xcode may prune older result bundles; the saved text logs remain the run evidence.

## Verification boundary

Available simulator gates pass. Four large-iPad skips are exercised on the appropriately sized iPhone/small iPad. The fifth is native window dragging while a nested modal is open, which the simulator did not permit; the same editor/picker handoff passes through real small-iPad rotation. Physical iPad and external-display testing were unavailable. Historical Mac/device evidence from the original implementation is not treated as verification of this remediation.
