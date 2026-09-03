# Widgets

## Product direction

Actualist widgets provide glanceable, local-first budget information. The first
widget is **Category Balances**, modeled on the YNAB category-balance widget:
the user chooses ordered categories and sees each category's current available
balance.

Additional widgets should join the same `WidgetBundle` while reusing the App
Group snapshot boundary. A widget extension must not open the imported budget
database, access credentials, or contact an Actual server.

## Category Balances MVP

- Configurable ordered category selection using a `WidgetConfigurationIntent`.
- Medium and large Home Screen families, showing the first 3 or 8 selected
  categories respectively.
- Current-calendar-month balances only.
- Positive, zero, and negative balance treatments.
- Hidden and income categories are omitted from suggestions. An already
  selected hidden category can still resolve until the configuration changes.
- Category rows deep-link to that category's current-month detail screen.
- Missing configuration, unavailable data, and deleted or budget-switched
  categories have explicit empty states.
- The app's sample-values privacy setting projects names and amounts before
  data crosses into the App Group container.

## Architecture

### App-owned publication

`WidgetSnapshotCoordinator` observes app-wide budget selection and local data
revisions. It reads the current month through `LocalFirstActualStore`, maps the
domain model with `WidgetSnapshotBuilder`, atomically saves one versioned JSON
snapshot, and asks WidgetKit to reload the affected kind.

An uncached store read is used when the Budget screen is displaying a different
month. This keeps `loadedBudgetMonthsByBudget` owned by the Budget feature and
prevents widget publication from changing visible screen state.

### Shared boundary

Only dependency-free widget boundary files under `Actualist/Widgets/` compile
into both targets:

- App Group and widget-kind constants.
- Versioned `Codable` snapshot DTOs.
- Atomic snapshot persistence.
- Category row/state projection.
- Month and deep-link helpers.

The extension does not link GRDB, sync transport, Keychain code, or the app's
feature state.

### Extension-owned presentation

`ActualistWidget/` owns AppIntent entities, timeline creation, widget views, and
the `WidgetBundle`. Category configuration resolves entirely from the shared
snapshot, so the picker remains local and fast.

## Refresh behavior

The app republishes after budget restore/switch, foreground refresh, local
mutations, privacy-setting changes, and loaded-month changes. Widget timelines
also request a refresh just after the next month boundary. If a current-month
snapshot is not available, the widget asks the user to open Actualist rather
than showing an old month as current.

## Next iterations

1. Validate row density, colors, and category reordering on a physical device.
2. Add lock-screen privacy behavior if Actualist supports accessory widgets.
3. Add theme-aware snapshot palette values if product testing favors matching
   the selected app theme over a stable widget palette.
4. Add other widget kinds behind the same versioned snapshot boundary, using
   kind-specific payloads rather than growing one catch-all DTO.
5. Consider background snapshot publication only if measured WidgetKit staleness
   warrants the extra background-work coordination.
