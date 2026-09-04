# Adaptive iPad implementation

Compact windows retain the existing Budget screen and native tabs. Wider windows use a native sidebar, one vertically scrolling category hierarchy, and an Auto or fixed 1–5 month budget viewport. The inspector and assignment popover use native SwiftUI presentation.

## Ownership

- `AdaptiveBudgetSession` owns each window's compact/wide handoff and rejects stale budget transitions.
- `BudgetViewportModel` owns month snapshots, selection, expansion, refresh generations, keyboard editing, and assignment refresh. Financial reads and writes still use the existing repository/store and assignment workflow.
- `BudgetWorkspaceActions` owns captured month/category actions and existing sheet workflows. Overspending, assignment, templates, and month notes use the captured month. Uncategorized transactions retain the existing store's budget-wide feed.
- `BudgetGridPresentation` and `BudgetLayoutMetrics` own display projection and width resolution. Views compose these values without computing money commands.
- `RootTransactionEditorPresenter` is window-local at `RootView`; its sheet survives compact/sidebar handoffs. `RootReauthenticationBanner` is shared by both layouts.
- `appSwitcherPrivacyProtected(using:)` explicitly carries `AppState` into separate presentation hosting layers. `BudgetWorkspaceView` owns the presentation-only grid scroll identity and passes it to `BudgetGridView` so inspector and width transitions retain the visible row.
- Accessibility Dynamic Type uses stacked compact rows with full-width labeled amounts. Standard-size rows keep the previous layout. Compact iPad navigation uses the native bottom tab bar.
- `AppState` only gains the persisted Months Shown preference setter. It does not own viewport state.

The existing large files stay at their original ownership boundaries: `BudgetView` receives an injected model, `BudgetViewModel` exposes read-only loaded-budget provenance and preserves its selected month, and `AppState` persists an app-wide preference. No new feature responsibility was added to those files. The category detail content was extracted for reuse in the compact sheet and native inspector. All new Swift files use synchronized target membership.

## Verification

- Full unit run: **1,597 tests in 126 suites passed** against the final production diff (`.artifacts/ipad/full-completion.log`), plus seven XCTest root tests and two iPhone UI tests. The earlier Reports/BackgroundBankSync timing failures did not recur.
- Final correction tests: **11 Swift Testing tests and seven XCTest tests passed** (`.artifacts/ipad/last-fixes-focused.log`): initial-load retry, stale reads/writes, root transaction routes, sidebar account privacy, and settings/compact transitions.
- Normal simulator build: **zero warnings** (`.artifacts/ipad/normal-completion.log`).
- Complete-concurrency build passes with 31 distinct existing diagnostics, compared with 32 in the initial run, and zero new diagnostics (`.artifacts/ipad/strict-completion.log`). Diagnostics are deduplicated by source file and message, ignoring shifted line numbers. No concurrency suppression or project-wide Swift language setting changed.
- Mechanical gate and Liquid Glass lint pass (`.artifacts/ipad/mechanical-completion.log`).
- All 457 `LocalFirstActualStoreTests` pass, including the existing privacy policy and suppression checks (`.artifacts/ipad/privacy-focused-completion.log`).
- SQLite-backed tests cover an assignment in an earlier month updating later visible balances. Parser tests cover exact minor-unit conversion, decimals, invalid input, and overflow.
- Manual iPad keyboard verification: typed `12.34`, Return saved the selected October cell, Tab/Shift-Tab moved between editable cells, and Escape dismissed. Inspector selection retained its month while Auto reduced the visible count.
- The final large-iPad UI run executed 15 tests: **13 passed, two compact-only tests skipped, and zero failed** (`.artifacts/ipad/ipad-ui-completion.log`). It covers portrait, dark/light Appearance and budget, month preference, assignment save/cancel, month navigation, transaction presentation, native resizing, inspector switching, and retained scroll position. Screenshots have been inspected.
- The smaller-iPad tests and final iPhone compact/accessibility tests pass: a typed transaction amount survives rotation from sidebar landscape to compact portrait, native bottom tabs appear, and accessibility amounts remain readable. Screenshots are in `.artifacts/ipad/screenshots/`.
- Four additional iPad UI regressions pass: nested category picker returns to the transaction editor, previous/next/Today/named-month navigation, inspector category switching with Add Transaction available, and scroll position retained after closing the inspector. The scroll test exposed a real reset; stable row scroll targets fixed it. Before/after screenshots now match (`.artifacts/ipad/scroll-regression-targets.log`).
- Native Stage Manager window controls exercised Auto at three months, two months, compact bottom tabs, and back to three months. A fixed preference of five survived the compact transition and remained selected after expansion. A measured long-press resize regression then passed across multi-month sidebar, one-month sidebar, compact tabs, and restored wide states while retaining the month anchor (`.artifacts/ipad/stage-manager-resize.log`). Auto was restored afterward.
- Mac Designed for iPad builds and launches. Live smoke testing covered the grid, month picker, transaction editor and nested category picker, inspector, and five visible months after filling the window and hiding the sidebar. Testing exposed a missing `AppState` environment in separate presentation hosts; explicit propagation through the privacy wrapper fixed the crash without changing the privacy policy.

## Screenshots

- [iPhone compact](../.artifacts/ipad/screenshots/iphone-compact.png)
- [iPhone accessibility](../.artifacts/ipad/screenshots/iphone-accessibility.png)
- [Compact iPad after rotation](../.artifacts/ipad/screenshots/compact-ipad-after-rotation.png)
- [Preserved transaction draft](../.artifacts/ipad/screenshots/transaction-draft-after-rotation.png)
- [iPad accessibility](../.artifacts/ipad/screenshots/ipad-accessibility-xxxl-budget.png)
- [Landscape multi-month grid](../.artifacts/ipad/screenshots/wide-budget.png)
- [Native category inspector](../.artifacts/ipad/screenshots/wide-category-inspector-open.png)
- [Light-mode budget](../.artifacts/ipad/screenshots/ipad-budget-light.png)
- [Stage Manager compact window](../.artifacts/ipad/screenshots/stage-manager-compact.png)
- [Scrolled grid before inspector](../.artifacts/ipad/screenshots/inspector-scroll-before.png)
- [Scrolled grid after closing inspector](../.artifacts/ipad/screenshots/inspector-scroll-after.png)

Additional screenshots and full xcresult evidence remain under `.artifacts/ipad/` and `.derivedData/Logs/Test/` (gitignored).

## Verification boundary

Automated builds, full unit tests, targeted UI tests, architecture review, and mechanical checks pass. The completed diff keeps state and workflows in focused owners; no new feature responsibility was added to the large existing view model or AppState. New Swift files compile through synchronized groups. Normal compact appearance, native bottom tabs, portrait/landscape, inspector layout, light mode, and accessibility rows have screenshot evidence.

Native window resizing, the Mac smoke check, and the complete large-iPad UI suite have run. Five-column rendering was visually inspected on Mac; a physical iPad external display was unavailable.

The planned implementation and available-device verification are complete. No commit or push has been made.
