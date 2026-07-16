# Native Reports Dashboard Plan

Status: implemented on 2026-07-16. The final Airy interaction check remains a
device-availability release check, not an implementation dependency.

## Implementation Result

- Settings now opens as a native sheet from the Budget toolbar ellipsis menu;
  the fourth native tab is Reports.
- `BudgetDatabase+Reports.swift` produces one consistent local SQLite snapshot
  for Net Worth, Cash Flow, This Month, Budget Overview, Three-Month Average,
  and Transaction Calendar.
- `LocalFirstActualStore` owns the cached report snapshot and invalidates it for
  local mutations, remote sync reloads, reset, and budget changes.
- `ReportsViewModel` provides cached-first/offline behavior, empty/error/loading
  states, app money formatting, accessibility summaries, and privacy-mode chart
  sanitization.
- `ReportsView` renders all six cards with SwiftUI and Swift Charts; it contains
  no REST or write path and uses native tab/toolbar chrome.
- `ReportsTests` covers transaction semantics, date boundaries, cache behavior,
  offline retention, privacy, sign/tone behavior, empty state, a 5,000-row
  performance guard, and phone-width rendering of the complete card stack.

## Goal

Replace the fourth `Settings` tab with a read-only `Reports` tab. Move Settings
behind a `Settings` item in the existing Budget toolbar ellipsis menu. Build a
mobile-native dashboard with Swift Charts that carries the information density
and visual hierarchy of the supplied Actual PWA references without copying the
PWA layout literally.

All report values must be calculated from the opened local Actual SQLite budget.
Reports must remain useful offline and must never depend on a REST reporting
endpoint or introduce a second source of truth.

## Product Decisions

- Keep the native four-item `TabView`: Budget, Spending, Accounts, Reports.
- Replace `AppTab.settings` with `AppTab.reports`, titled `Reports`, using an SF
  Symbol such as `chart.xyaxis.line`.
- Add `Settings` to the existing top-right Budget `Menu`, after the budget
  actions and a divider.
- Present `SettingsView` as a native sheet with its own navigation title and a
  plain toolbar close button. Do not add glass styling to the toolbar button.
- Keep first-launch connection and budget selection in the existing onboarding
  flow. Moving Settings does not change setup routing.
- Start with one `Main` dashboard. Do not render a dead dashboard picker merely
  to match the reference; add a native picker later when a second dashboard or
  preset exists.
- Render graphs with Apple's `Charts` framework and SwiftUI marks. Do not draw
  charts with web content, screenshots, or a custom canvas.
- Use solid theme-backed report cards. The native tab bar and navigation toolbar
  own their Liquid Glass; report cards are content, not floating glass controls.
- Reports are read-only. No report interaction may create or enqueue CRDT
  messages.

## Main Dashboard

The dashboard is a vertical `ScrollView` of compact cards. Each card has a title,
date/range subtitle, headline value or comparison, chart, loading placeholder,
empty state, and accessible textual summary.

### 1. Net Worth

- Default range: trailing six calendar months through today.
- Series: end-of-day cumulative balance across included accounts.
- Default account scope: all non-tombstoned accounts, including off-budget and
  closed accounts for the dates on which they had balances.
- Display the latest balance and change from the first point in the range.
- Use a `LineMark` plus `AreaMark`; positive and negative regions must remain
  legible without relying only on color.
- Transfers between included accounts naturally net to zero. If account filters
  are added later, calculate from the selected account set instead of trying to
  reclassify transfers.

### 2. Cash Flow

- Default range: selected/current calendar month.
- Show Income and Expenses as two bars and show net cash flow as the headline.
- Income is positive categorized activity in income categories.
- Expenses are the positive magnitude of negative categorized activity in
  expense categories; refunds reduce the expense total.
- Reuse the budget engine's category-mapping behavior so on-budget transfers are
  excluded while a transfer to or from an off-budget account is treated the same
  way the local budget treats that mapped category.
- Show uncategorized activity as a warning/footnote when present rather than
  silently classifying it as income or expense.

### 3. This Month

- Compare cumulative daily net cash flow for the current month with the previous
  month, aligned by day number.
- Render current month as a solid line/area and the prior month as a dashed line.
- Headline comparison is current net cash flow minus prior-month net cash flow at
  the comparable day. If the current month is incomplete, do not compare it with
  future days from the prior month.

### 4. Budget Overview

- Default range: current budget month.
- Compare cumulative actual expense activity with cumulative budgeted expense
  categories for the month.
- Headline variance is actual expenses minus budgeted expenses. Positive
  variance is caution/danger; remaining budget is positive.
- The chart uses a solid actual series and a clearly labelled dashed budget
  reference. A flat monthly budget should be represented as a day-proportional
  reference so the two cumulative series are comparable.
- Exclude income category groups. Preserve hidden-category amounts in totals
  unless a later explicit filter says otherwise.

### 5. Three-Month Average

- Compare current-month cumulative expenses with the average cumulative expense
  curve from the previous three complete months, aligned by day number.
- Headline variance is current comparable-to-date expenses minus the historical
  average. Spending above average is danger; below average is positive.
- Months with fewer days contribute through their last day without fabricating
  transactions on nonexistent dates.

### 6. Transaction Calendar

- Default range: current month plus the prior two months.
- Each day cell shows separate income and expense intensity, with the monthly
  income/expense totals shown beside the month label.
- Use a real Gregorian calendar grid, locale-aware weekday labels, and correct
  month starts/lengths. Do not position cells from transaction count.
- Empty days remain visible. Color intensity is normalized within the visible
  range and is supplemented by accessibility labels containing date, income,
  and expenses.

## Shared Financial Semantics

Create one report-query layer rather than letting each card reinterpret raw
transactions independently.

- Keep values as Actual integer minor units through SQL, models, and chart
  calculations. Convert only for display/axis labels.
- Include only live transactions and accounts.
- Exclude split parent rows and include their live child rows.
- Exclude children whose parent is tombstoned.
- Respect `category_mapping` exactly as the existing budget-month spending
  queries do.
- Avoid double-counting same-budget transfers in income/expense reports.
- Include starting-balance transactions in net worth.
- Use calendar dates/month keys, not device-local timestamps, because Actual
  transaction dates are date-only values.
- Define the treatment of uncategorized, off-budget, closed, hidden, refund,
  transfer, split, and future-dated transactions in fixture tests before a card
  ships.

## Architecture

### Domain and repository seam

Add typed, `Sendable` report models, for example:

- `ReportsDashboardSnapshot`
- `NetWorthPoint`
- `CashFlowSummary`
- `DailyComparisonPoint`
- `BudgetVariancePoint`
- `TransactionCalendarMonth` / `TransactionCalendarDay`
- `ReportDateRange`

Add `ReportsRepositoryProtocol` as the dependency-injection seam. Production
uses `LocalFirstActualStore`; tests inject a fake. The repository should expose a
cached snapshot and an async refresh for a budget/range.

### SQLite queries

Add `BudgetDatabase+Reports.swift`. Perform grouped SQL reads inside one database
read transaction so all cards describe one consistent snapshot. Prefer a small
number of range queries that return daily/category/account aggregates over one
query per chart point.

Reuse or extract the existing schema-defensive helpers from
`BudgetDatabase+Reads.swift`: live-row predicates, parent filtering, normalized
month/date expressions, flexible columns, category mapping, and Actual amount
conversion. Do not duplicate subtly different transaction semantics in the new
file.

### Store and caching

`LocalFirstActualStore` owns the in-memory report cache keyed by budget and date
range. On report load:

1. Publish the cached snapshot immediately.
2. Read a fresh snapshot from the open local database.
3. Opportunistically run the normal coalesced sync refresh when appropriate.
4. Re-query and publish only if the local database changed.

Keep the last successful local snapshot visible when the server is offline or a
background pull fails. Clear report caches in `reset()` and after budget switch,
connection change, reimport, or local erase. Local transaction/budget writes may
invalidate the affected report range instead of synchronously rebuilding every
chart before the write returns.

### View model and views

Add `ReportsViewModel` to own date range, cached-first loading, refresh state,
errors, empty state, card display values, and chart-ready series. `ReportsView`
and card views only lay out prepared state and send intents.

Suggested feature shape:

```text
Actualist/Features/Reports/
  ReportsView.swift
  ReportsViewModel.swift
  ReportModels.swift
  ReportCards.swift
Actualist/Repositories/
  ReportsRepository.swift
Actualist/LocalFirst/
  LocalFirstActualStore+Reports.swift
Actualist/LocalFirst/Database/
  BudgetDatabase+Reports.swift
```

## Navigation and Settings Changes

1. Add `isSettingsPresented` presentation state to `BudgetView`.
2. Add a `Settings` label/button to the existing ellipsis `Menu`.
3. Present `SettingsView` as a sheet and give sheet presentation a native close
   affordance without nesting `NavigationStack`s.
4. Replace the Settings entry in `MainTabView` with `ReportsView`.
5. Replace `.settings` in `AppTab` with `.reports` and update tab-routing tests.
   `selectedTab` is currently in-memory only, so no persisted-tab migration is
   required.
6. Keep notification routing to Spending and Budget refresh-on-selection
   behavior unchanged.

## Privacy, Accessibility, and Formatting

- Apply the existing randomized-display/privacy setting to every headline,
  tooltip, chart axis, annotation, and accessibility value. A chart must not leak
  real amounts after its labels have been randomized.
- Use the app's currency formatting and theme tokens.
- Support Dynamic Type without truncating headline amounts or chart summaries.
- Provide VoiceOver summaries and point/bar descriptions; never convey positive
  versus negative state through red/green alone.
- Respect Reduce Motion and Increased Contrast. Chart animation is optional and
  should not delay first paint.

## Implementation Phases and Commit Boundaries

### Phase 1 — Navigation shell

- Move Settings into the Budget menu/sheet.
- Replace the fourth tab and `AppTab` case with a Reports empty/loading shell.
- Update navigation tests and current docs that enumerate tabs.

Suggested commit: `refactor: move settings into budget menu`

### Phase 2 — Report data foundation

- Add typed models, repository protocol, database aggregate queries, store cache,
  and fixture tests for all shared financial semantics.
- Add timing assertions or measurements for a long-history fixture to prevent
  accidental per-day/per-row query loops.

Suggested commit: `feat: add local report aggregates`

### Phase 3 — Core charts

- Ship Net Worth, Cash Flow, and This Month cards with cached-first/offline
  behavior.
- Add privacy, accessibility, empty, loading, and partial-refresh states.

Suggested commit: `feat: add reports dashboard`

### Phase 4 — Budget comparison and calendar

- Add Budget Overview, Three-Month Average, and Transaction Calendar.
- Add date-range controls only where they produce meaningful choices.
- Tune card density and chart labels on iPhone-sized screens.

Suggested commit: `feat: complete report comparison cards`

## Verification

- `git diff --check`.
- Unit-test SQL fixtures containing:
  - normal income and expense rows;
  - refunds;
  - same-budget and off-budget transfers;
  - split parents/children and tombstones;
  - uncategorized activity;
  - hidden, closed, and off-budget accounts/categories;
  - starting balances and future-dated rows;
  - 28/29/30/31-day months and year boundaries.
- Unit-test `ReportsViewModel` cached-first, offline-error, refresh, empty, date
  comparison, sign/color, and privacy behavior with a fake repository.
- Run the full relevant `ActualistTests` suites and
  `scripts/lint-liquid-glass.sh`.
- Verify first paint and scroll performance with a multi-year transaction
  fixture in an iPhone simulator.
- Inspect all six cards in dark mode, Dynamic Type, Increased Contrast, Reduce
  Motion, privacy mode, and VoiceOver.
- Compare fixture totals with direct SQL totals and the equivalent Actual PWA
  report for the same throwaway budget before shipping.
- Perform a final physical-device check on Airy for chart rendering, tab
  behavior, Settings presentation/dismissal, and offline cached reports.

## Acceptance Criteria

- The bottom tabs are Budget, Spending, Accounts, and Reports, using native
  `TabView` chrome.
- Settings opens from the Budget ellipsis menu and every existing Settings action
  remains reachable and functional.
- Reports show all six planned cards from local SQLite data and remain visible
  without a network connection after first load.
- Split, transfer, tombstone, and category-mapping behavior is covered by fixture
  tests and does not double-count money.
- No report path calls a REST endpoint or performs a write.
- Privacy mode, accessibility, and Liquid Glass lint pass without financial data
  leaking through charts.

## Deferred

- Custom dashboard/report builder.
- Saved report presets and a `Main` dashboard picker.
- Per-account/category/payee filtering UI.
- Sankey, balance forecast, and drill-down interactions from chart marks.
- Export/share and cross-budget reporting.
