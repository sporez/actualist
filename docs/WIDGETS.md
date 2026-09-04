# Widgets

## Product direction

Actualist provides seven native widgets. Configuration lives in Apple's
**Edit Widget** interface; there is no Widgets page in Settings.

| Widget | Contents | Configuration |
| --- | --- | --- |
| Category Balances | Current-month available balances | Choose and order up to 16 categories |
| Account Balances | Account balances, using the same layout as categories | Choose and order up to 16 accounts |
| Needs Attention | Overspent categories and budget-wide uncategorized transactions | Current budget |
| Month Overview | Income, spending, To Budget; larger sizes add totals and a chart | Current month |
| Recent Transactions | Latest activity across accounts; rows open the account register | Current budget |
| Net Worth | Balance, change, and a six-month trend | Current budget |
| Quick Actions | Four shortcuts into screens and reviewed editor flows | Choose and order four actions |

## Appearance

All seven widgets follow the theme selected in Settings → Appearance, including
background, text, accent, and balance colors. Light themes stay light and dark
themes stay dark in full-color Home Screen rendering. Apple controls colors and
background treatment in tinted, Clear, and accessory rendering modes. Theme
changes request a refresh of every widget; WidgetKit schedules the actual update.

## Sizes and selection

The six data widgets register small, medium, large, and extra-large Home Screen
families. Builds made with the iOS 27 SDK also register the new extra-large
portrait family on iOS 27. Device and system support determine which sizes
appear in the widget gallery; the app's existing iPhone device target remains
unchanged. Quick Actions stays medium-sized to provide four distinct links.

Balance widgets show up to 1, 3, 8, or 16 selections as space increases. Selection
order is retained when resizing. Wide layouts use two columns; portrait layouts
use a longer list. Larger accessibility text reduces row counts. Recent
Transactions publishes up to 16 grouped transactions and shows up to 12 in its
largest layouts. Small sizes prioritize a single balance or compact summary.

Balances, Needs Attention, Month Overview, and Net Worth also provide inline and
rectangular accessory summaries. Recent Transactions provides a rectangular
summary; Needs Attention also provides a circular count. Financial views are
marked privacy-sensitive for system redaction.

Hidden and income categories are excluded from picker suggestions. Already
selected hidden categories still resolve. Closed accounts are excluded from
suggestions but remain visible when already selected. Missing configuration,
unavailable data, and removed selections have explicit empty states. Unavailable
amounts are never presented as zero.

Category rows open current-month category details. Account and recent-transaction
rows open account registers. Needs Attention opens budget review or the global
uncategorized queue, including transactions from older months.

## Quick Actions

A medium Home Screen widget displays four action buttons from left to right.
Long-press the widget and choose **Edit Widget** to select and order four actions
from a searchable catalog. Each widget keeps its own selection. Defaults are
Add Expense, Budget, Spending, and Accounts. No Widgets page is needed in the
app's Settings.

The catalog includes 20 screen/editor destinations grouped under Transactions,
Budget, Accounts, Reports, and Settings. Search matches titles, descriptions,
and group names. Balance and Quick Actions widgets use native per-widget configuration.

Buttons open the app directly. Add Expense and Add Income open the existing
transaction editor for review and save; Bank Sync opens its review workflow.
The widget does not perform financial writes. These links work independently
of the Shortcuts and Siri enablement preference.

`QuickActionsConfigurationIntent` exposes an ordered entity array with native
four-item limits. WidgetKit owns persistence for each widget instance.
`WidgetQuickActions` preserves order, removes duplicates, and fills missing
slots from the defaults. The configuration contains only static action
identifiers and needs no App Group preference file or budget data. The timeline updates when the native configuration changes or the app requests
a refresh after a theme change.

The extension owns the entity query, timeline, and action row.
`WidgetQuickActionRoute` maps the catalog into existing app routes and Settings
destinations. `AppRouteCoordinator.settingsPath` owns Settings navigation for
both widget links and simulator launch paths. Widget navigation waits for an
active Settings cover to finish dismissing before applying the destination.

## Architecture

### App-owned publication

`WidgetSnapshotCoordinator` observes app-wide budget selection and local data
revisions. `LocalFirstActualStore.fetchWidgetSource` reads the current month,
accounts, grouped transactions, attention counts, and the existing net-worth
report calculation from SQLite. `WidgetFinancialSnapshotBuilder` applies the
app's sample-values privacy projection before serializing typed payloads.
`WidgetSnapshotCoordinator` atomically saves a schema-2 JSON snapshot and asks
WidgetKit to reload all six data kinds. Budget or privacy changes clear the
previous snapshot before a replacement read. A schema-1 snapshot asks to reopen
the app; it is not silently treated as complete fleet data.

Optional sections preserve partial-read failures separately from legitimate
empty lists and zero totals. Widgets never read SQLite or credentials and never
contact the server.

An uncached store read is used when the Budget screen is displaying a different
month. This keeps `loadedBudgetMonthsByBudget` owned by the Budget feature and
prevents widget publication from changing visible screen state.

### Shared boundary

Standalone widget boundary files under `Actualist/Widgets/` and the immutable
`ActualistThemePalette` design-system definitions compile into both targets:

- App Group and widget-kind constants.
- Versioned `Codable` snapshot DTOs.
- Atomic snapshot persistence.
- Shared theme identifier preference and rendering palette.
- Category row/state projection.
- Month and deep-link helpers.
- Quick Actions catalog and ordered four-action projection.

The extension does not link GRDB, sync transport, Keychain code, or the app's
feature state.

`WidgetSnapshotCoordinator` observes the theme separately from budget reads.
`WidgetThemeStore` shares only the selected theme identifier through App Group
preferences, so appearance also works with no budget or financial snapshot.
Providers capture it in timeline entries, and the extension applies the same
immutable palette as the app. It never uses the app process's active-theme global.

### Extension-owned presentation

`ActualistWidget/` owns AppIntent entities, timeline creation, widget views, and
the `WidgetBundle`. Balance configuration resolves entirely from the shared
snapshot, so the picker remains local and fast.

## Refresh behavior

The app republishes after budget restore/switch, foreground refresh, local
mutations, privacy-setting changes, and loaded-month changes. Widget timelines
also request a refresh just after the next month boundary. If a current-month
snapshot is not available, the widget asks the user to open Actualist rather
than showing an old month as current.

## Verification boundary

Unit fixtures cover amount units, privacy projection, ordering, schema changes,
missing sections, native configuration metadata, and SQLite read parity.
Simulator renders cover layout sizes, light/dark appearances, and enlarged text.
Rendered views do not replace native Home Screen checks of the picker, reorder
controls, system redaction, and link interactions.
