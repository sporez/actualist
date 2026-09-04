# Adaptive iPad implementation

Compact windows retain the existing Budget screen and native tabs. Wider windows use a native sidebar, one vertically scrolling category hierarchy, and an Auto or fixed 1–5 month budget viewport. The inspector and assignment popover use native SwiftUI presentation.

## Ownership

- `AdaptiveBudgetSession` owns each window's compact/wide handoff and rejects stale budget transitions.
- `BudgetViewportModel` owns month snapshots, selection, expansion, refresh generations, keyboard editing, and assignment refresh. Financial reads and writes still use the existing repository/store and assignment workflow.
- `BudgetWorkspaceActions` owns captured month/category actions and existing sheet workflows. Overspending, assignment, templates, and month notes use the captured month. Uncategorized transactions retain the existing store's budget-wide feed.
- `BudgetGridPresentation` and `BudgetLayoutMetrics` own display projection and width resolution. Fixed one-month workspaces cap their width from this pure metrics seam while Auto continues to fill the measured detail width. Views compose these values without computing money commands.
- `RootTransactionEditorPresenter` is window-local at `RootView`; its sheet survives compact/sidebar handoffs. `RootReauthenticationBanner` is shared by both layouts.
- `appSwitcherPrivacyProtected(using:)` explicitly carries `AppState` into separate presentation hosting layers. `BudgetWorkspaceView` owns the presentation-only grid scroll identity and passes it to `BudgetGridView` so inspector and width transitions retain the visible row.
- Accessibility Dynamic Type uses multiline alert and category labels, stacked compact rows, and full-width labeled amounts. Standard-size rows keep the previous layout. Compact iPad navigation uses the native bottom tab bar.
- `BudgetView` presents Add Transaction through a bottom safe-area inset, so SwiftUI measures its Dynamic Type height and reserves matching scroll clearance above it and the native tab bar.
- `TransactionEditorView` keeps editor state in `TransactionEditorViewModel` and uses its existing scroll view without dismissing the keyboard, allowing lower fields and Save to move fully above the keyboard after rotation.
- `AppState` only gains the persisted Months Shown preference setter. It does not own viewport state.

The existing large files stay at their original ownership boundaries: `BudgetView` receives an injected model, `BudgetViewModel` exposes read-only loaded-budget provenance and preserves its selected month, and `AppState` persists an app-wide preference. No new feature responsibility was added to those files. The category detail content was extracted for reuse in the compact sheet and native inspector. All new Swift files use synchronized target membership.

## Verification

- Fresh full unit run: **1,598 tests in 126 suites passed** against the completed compact-layout remediation (`.derivedData/Logs/Test/Test-Actualist-2026.09.04_15-10-53--0400.xcresult`).
- Fresh focused layout/root run: **11 Swift Testing tests and seven XCTest tests passed**, including the fixed one-month maximum scan-width assertion (`.derivedData/Logs/Test/Test-Actualist-2026.09.04_15-17-44--0400.xcresult`).
- Normal simulator build: **zero warnings**.
- Complete-concurrency clean build passes with the same **31 distinct existing diagnostics** and zero diagnostics in the files changed by this remediation. Diagnostics are deduplicated by source file and message, ignoring shifted line numbers. No concurrency suppression or project-wide Swift language setting changed.
- Mechanical gate and Liquid Glass lint pass against the remediation diff.
- All 457 `LocalFirstActualStoreTests` pass, including the existing privacy policy and suppression checks (`.artifacts/ipad/privacy-focused-completion.log`).
- SQLite-backed tests cover an assignment in an earlier month updating later visible balances. Parser tests cover exact minor-unit conversion, decimals, invalid input, and overflow.
- Manual iPad keyboard verification: typed `12.34`, Return saved the selected October cell, Tab/Shift-Tab moved between editable cells, and Escape dismissed. Inspector selection retained its month while Auto reduced the visible count.
- The fresh large-iPad UI suite executed 15 tests: **13 passed, two compact-only tests skipped, and zero failed** (`.derivedData/Logs/Test/Test-Actualist-2026.09.04_15-12-34--0400.xcresult`). It covers portrait, dark/light Appearance and budget, month preference, assignment save/cancel, month navigation, transaction presentation, native resizing, inspector switching, and retained scroll position.
- Dedicated current-destination runs pass on standard and Accessibility XXXL iPhones and on the compact iPad. The tests require complete alert labels, non-overlapping accessibility row frames, a hittable final category above Add Transaction and the native tab bar, and lower transaction-editor fields above the still-visible keyboard after rotation.
- Four additional iPad UI regressions pass: nested category picker returns to the transaction editor, previous/next/Today/named-month navigation, inspector category switching with Add Transaction available, and scroll position retained after closing the inspector. The scroll test exposed a real reset; stable row scroll targets fixed it. Before/after screenshots now match (`.artifacts/ipad/scroll-regression-targets.log`).
- Native Stage Manager window controls exercised Auto at three months, two months, compact bottom tabs, and back to three months. A fixed preference of five survived the compact transition and remained selected after expansion. A measured long-press resize regression then passed across multi-month sidebar, one-month sidebar, compact tabs, and restored wide states while retaining the month anchor (`.artifacts/ipad/stage-manager-resize.log`). Auto was restored afterward.
- Mac Designed for iPad builds and launches. Live smoke testing covered the grid, month picker, transaction editor and nested category picker, inspector, and five visible months after filling the window and hiding the sidebar. Testing exposed a missing `AppState` environment in separate presentation hosts; explicit propagation through the privacy wrapper fixed the crash without changing the privacy policy.

## Screenshots

- [Standard iPhone top](../.artifacts/ipad/screenshots/remediation-iphone-top.png)
- [Standard iPhone final category](../.artifacts/ipad/screenshots/remediation-iphone-bottom.png)
- [iPhone Accessibility XXXL top](../.artifacts/ipad/screenshots/remediation-iphone-accessibility-top.png)
- [iPhone Accessibility XXXL final category](../.artifacts/ipad/screenshots/remediation-iphone-accessibility-bottom.png)
- [Compact iPad Accessibility XXXL top](../.artifacts/ipad/screenshots/remediation-ipad-accessibility-top.png)
- [Compact iPad Accessibility XXXL final category](../.artifacts/ipad/screenshots/remediation-ipad-accessibility-bottom.png)
- [Compact Stage Manager final category](../.artifacts/ipad/screenshots/remediation-stage-manager-bottom.png)
- [Keyboard-visible transaction editor after rotation](../.artifacts/ipad/screenshots/remediation-transaction-editor-rotation.png)
- [Compact iPad after editor rotation](../.artifacts/ipad/screenshots/remediation-compact-ipad-after-rotation.png)
- [Wide fixed one-month grid](../.artifacts/ipad/screenshots/remediation-wide-fixed-one-month.png)
- [Wide Auto multi-month grid](../.artifacts/ipad/screenshots/remediation-wide-auto.png)
- [Wide native category inspector](../.artifacts/ipad/screenshots/remediation-wide-inspector.png)
- [Light compact budget](../.artifacts/ipad/screenshots/remediation-light-compact.png)
- [Light wide budget](../.artifacts/ipad/screenshots/remediation-light-wide.png)
- [Scrolled grid before inspector](../.artifacts/ipad/screenshots/inspector-scroll-before.png)
- [Scrolled grid after closing inspector](../.artifacts/ipad/screenshots/inspector-scroll-after.png)

Additional screenshots and full xcresult evidence remain under `.artifacts/ipad/` and `.derivedData/Logs/Test/` (gitignored).

## Verification boundary

Automated builds, full unit tests, targeted UI tests, architecture review, and mechanical checks pass. The completed diff keeps state and workflows in focused owners; no new feature responsibility was added to the large existing view model or AppState. No new Swift files were required. Normal compact appearance, native bottom tabs, portrait/landscape, inspector layout, light mode, bottom-content clearance, keyboard-safe editing, and accessibility rows have screenshot evidence.

Native window resizing, the Mac smoke check, and the complete large-iPad UI suite have run. Five-column rendering was visually inspected on Mac; a physical iPad external display was unavailable.

The adaptive implementation, compact-layout remediation, and available-device verification are complete. No commit or push has been made.
