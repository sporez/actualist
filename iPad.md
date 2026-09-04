# Actualist — Adaptive iPad Budget Interface
Status: Planned
Target: iPadOS
Scope: Native iPad interface for Actualist, preserving the existing compact/iPhone experience
Mac scope: Compatibility only. Do not attempt to create a Mac-native interface as part of this work.

---

# 1. Objective

Build a genuinely native iPad presentation for Actualist rather than scaling the existing iPhone interface across a large canvas.

The large iPad interface should combine:

- Actual Budget's useful desktop-style information density.
- Actualist's existing visual language and interaction model.
- Standard iPadOS navigation and sidebar behavior.
- Multiple budget months visible simultaneously.
- Pointer and hardware-keyboard support suitable for Magic Keyboard use.
- Progressive adaptation all the way down to the existing compact Actualist interface.

The intended result is NOT a port of Actual's web UI.

It should feel like:

"Actual's desktop budget concept, redesigned as a first-class Actualist/iPadOS interface."

The existing iPhone design remains authoritative for compact widths.

The iPad interface should emerge progressively as space becomes available rather than existing as a separate hard-coded "iPad app."

---

# 2. Core Design Principles

## 2.1 Width-driven, not device-driven

Do not implement this using:

    UIDevice.current.userInterfaceIdiom == .pad

as the primary layout decision.

Modern iPadOS windows can range from roughly iPhone-sized windows to enormous full-screen canvases.

Layout decisions must be based primarily on usable container width.

Size classes may be used as supporting information, but not as the sole layout switch.

A single iPad should be capable of transitioning naturally through:

    Compact Actualist
        ↓
    Sidebar + single-month Actualist
        ↓
    Sidebar + multi-month desktop-style Actualist

as the user resizes the window.

---

# 3. Layout Modes

Implement three conceptual presentation modes.

Names are illustrative and can be changed internally.

    enum BudgetPresentationMode {
        case compact
        case splitSingleMonth
        case multiMonth
    }

The transition should be progressive.

There should not be a sudden concept of:

    iPhone UI
    vs.
    iPad UI

Instead, features should disappear in priority order as width becomes constrained.

---

## 3.1 Mode A — Compact

This is essentially the existing Actualist interface.

Examples:

- iPhone
- narrow iPad window
- narrow Stage Manager window
- any container where the sidebar cannot coexist comfortably with budget content

Use:

- Existing bottom TabView/navigation.
- Existing single-month Budget UI.
- Existing bottom Add Transaction accessory.
- Existing category navigation.
- Existing assignment editor presentation.
- Existing sheets/popovers/navigation behavior unless otherwise required.

This work must NOT redesign the compact experience.

The compact mode is already considered a valid design.

Regression prevention here is a major requirement.

---

## 3.2 Mode B — Sidebar + Single Month

When enough width exists for proper iPad navigation but not enough to present multiple months comfortably:

    [ Sidebar ] [ Single Month Budget ]

Differences from compact mode:

- Standard iPad sidebar replaces bottom tabs.
- Bottom tab bar disappears.
- Bottom Add Transaction accessory disappears.
- Add Transaction moves to the top toolbar.
- Budget remains fundamentally a single-month interface.
- The budget should use additional width intelligently rather than simply stretching phone controls.
- Category names should have more room.
- Assigned and Available columns should align cleanly.
- Existing summary UI can remain relatively prominent because only one month is being displayed.
- Category details can use the iPad inspector when practical.

This mode is the bridge between phone and full desktop-style budget presentation.

---

## 3.3 Mode C — Sidebar + Multi-Month Budget

At sufficiently large widths:

    [ Sidebar ] [ Category Column ] [ Month ] [ Month ] [ Month ] ...

This is the primary new iPad experience.

The layout should feel substantially closer to Actual's desktop budgeting workflow while remaining visually Actualist.

The number of visible months can vary based on width and user preference.

No horizontal month scrolling in v1.

Months occupy a fixed, anchored viewport.

---

# 4. Standard iPad Sidebar

Use the native SwiftUI/iPadOS sidebar architecture.

Preferred foundation:

    NavigationSplitView

Do not create a custom navigation rail pretending to be a sidebar.

Use standard system behavior for:

- Sidebar visibility.
- Overlay behavior at narrower widths.
- Sidebar collapse.
- Dragging/resizing where supported.
- Keyboard navigation.
- Pointer interaction.
- iPadOS visual treatment.
- Future iPadOS appearance changes.

The sidebar should naturally inherit Apple's current system appearance, including modern iPadOS/Liquid Glass behavior where applicable.

---

## 4.1 Sidebar Information Architecture

Initial structure:

    Budget
    Spending
    Reports

    Accounts
        All Accounts / Accounts Overview
        Checking
        Savings
        Credit Card
        ...
        [individual Actual accounts]

    Settings

Exact labels should follow existing Actualist terminology.

Individual accounts should be directly selectable from the sidebar.

The sidebar replaces the compact bottom tabs when active.

Do not show both simultaneously.

---

## 4.2 Sidebar State

Sidebar visibility should behave like standard iPadOS navigation.

User collapse/expand state can remain window-local.

Do not invent a permanent custom sidebar toggle state if NavigationSplitView already provides appropriate behavior.

---

# 5. Add Transaction

Compact mode:

Preserve the existing Actualist Add Transaction bottom accessory.

Sidebar modes:

Move Add Transaction to the native top toolbar.

Preferred initial implementation:

    ToolbarItem(placement: .primaryAction) {
        AddTransactionButton()
    }

The sidebar should remain primarily navigational.

Do NOT put Add Transaction into the sidebar as a navigation destination merely because there is available space.

A toolbar action is semantically cleaner and matches native iPad conventions.

This is an implementation default and can be revisited after using the prototype.

Keyboard shortcut should be considered:

    Command-N

if it does not conflict with existing behavior.

---

# 6. Multi-Month Budget Information Architecture

The multi-month screen should NOT render several copies of the complete phone budget next to each other.

Do NOT do:

    [September phone budget] [October phone budget] [November phone budget]

That would waste space by repeatedly rendering category names and oversized summary UI.

Instead use a shared vertical category axis.

Conceptually:

                        SEP 2026             OCT 2026             NOV 2026
                     Assigned Available   Assigned Available   Assigned Available

    Monthly Bills      6,194    8,273      6,250    7,900      6,100    8,020

    🏠 Mortgage        3,645    3,354      ...
    🍔 Groceries         403      445      ...
    🛠 Utilities         437      959      ...
    ⛽ Gas               200      200      ...
    📱 Cell Phone        108      108      ...

The category hierarchy exists once.

Each visible month contributes its own Assigned and Available values.

---

# 7. Grid Architecture

Prefer one vertically scrolling structure.

Do NOT create separate vertically scrolling month lists that must be synchronized.

Preferred conceptual structure:

    ScrollView(.vertical) {
        LazyVStack {
            ForEach(groups) {
                GroupHeaderRow()

                ForEach(categories) {
                    BudgetCategoryRow(
                        categoryColumn,
                        monthCells[]
                    )
                }
            }
        }
    }

Each category row contains:

    [ fixed category area ]
    [ Sep Assigned | Sep Available ]
    [ Oct Assigned | Oct Available ]
    [ Nov Assigned | Nov Available ]

Because horizontal scrolling is intentionally absent, the category column does not require complex frozen-column synchronization.

All visible values remain part of the same row.

This dramatically reduces scroll synchronization problems.

---

# 8. Category Column

The left category column should remain visually stable across every visible month.

It contains:

- Category icon/emoji if currently used.
- Category name.
- Relevant status indicators that belong to the category itself rather than a specific month.
- Category group hierarchy.
- Group expand/collapse controls.

Provide enough width to avoid the extremely aggressive truncation seen in compact layouts when the window is large.

The category column may have a preferred width with reasonable minimum/maximum bounds.

Example conceptual values only:

    categoryPreferredWidth ≈ 220–280 pt

Do not treat those numbers as final design constants until visually tested.

---

# 9. Category Groups

Category group expansion state is shared across months.

Example:

If "Monthly Bills" is collapsed, its categories disappear from ALL visible month columns.

There must never be:

    September -> expanded
    October   -> collapsed
    November  -> expanded

The category hierarchy is one shared hierarchy.

Group summary rows should expose month-specific totals in the corresponding month columns.

Example:

                        SEP                OCT                NOV
    Monthly Bills    6194 / 8273        6250 / 7900        6100 / 8020

This preserves the useful group-level Assigned/Available totals from the phone layout.

---

# 10. Month Headers

Each month should have a visually distinct header spanning its Assigned and Available subcolumns.

Example:

                September 2026
             Assigned    Available

The month header should be visually identifiable as one unit without building giant card boundaries everywhere.

Actualist's existing design language should remain visible.

Avoid making this look like a generic spreadsheet.

---

# 11. "To Budget" in Multi-Month Mode

Each month needs its own To Budget state.

However:

DO NOT repeat the enormous phone-width green To Budget bar five times.

In multi-month mode, convert the phone summary into a more compact month header treatment.

Possible presentation:

    September 2026
    [ $3,119.75 To Budget ]
    Assigned | Available

or:

    September 2026
    To Budget  $3,119.75
    Assigned | Available

The exact treatment should be prototyped visually.

Requirements:

- Value remains immediately visible.
- Positive/negative/status colors remain meaningful.
- Tapping it preserves any existing To Budget behavior.
- The result should still unmistakably feel like Actualist.
- It must remain legible when 4–5 months are visible.
- It must not dominate the entire screen.

Single-month modes may continue using the larger phone-style To Budget treatment.

---

# 12. Budget Alerts in Multi-Month Mode

The existing phone UI exposes alerts such as:

    1 Overspent category
    Cover >

These must remain discoverable on iPad.

Do not render five giant full-width alert cards.

Instead, each month header may contain a compact alert/status control beneath the To Budget summary.

Example:

    September 2026
    $3,119.75 To Budget
    [ ! 1 Overspent ]

A month without alerts should not waste equivalent vertical space unnecessarily if layout can remain aligned cleanly.

Alternative implementations can use a shared alert lane if visual testing proves superior, but month ownership MUST remain clear.

Important:

An alert must always indicate which month it belongs to.

Actions such as Cover must operate on that month's data.

---

# 13. Month Viewport — No Horizontal Scrolling

Version 1 must NOT horizontally scroll through months.

Visible months form an anchored viewport.

Example:

    Sep | Oct | Nov

The user navigates the viewport explicitly.

Controls should include:

- Previous month.
- Next month.
- Jump to current month.
- Month/year picker by tapping the month/date control.

Navigation changes the anchored month range.

Example:

Initial:

    Sep | Oct | Nov

Tap next:

    Oct | Nov | Dec

Tap previous:

    Sep | Oct | Nov

Do NOT jump an entire page of three months unless later testing indicates that is preferable.

One-month increments provide continuity.

---

# 14. Anchor Month

Maintain a clear viewport concept.

Suggested state:

    viewportStartMonth

This represents the leftmost visible month.

Visible months are:

    viewportStartMonth
    viewportStartMonth + 1
    viewportStartMonth + 2
    ...

depending on resolved visible month count.

When transitioning from compact single-month mode into multi-month mode, the currently selected month should become the viewport start month.

Example:

Compact user is viewing September.

Expand window.

Result:

    Sep | Oct | Nov

rather than unexpectedly moving September into some arbitrary middle position.

This preserves spatial/contextual continuity.

---

# 15. Visible Month Preference

Add an iPad budget layout preference:

    Months Shown

Options:

    Auto
    1
    2
    3
    4
    5

Five is a reasonable initial maximum.

Architecture should make extending this later trivial.

Internal representation could resemble:

    enum MonthDisplayPreference: Codable, Hashable {
        case automatic
        case fixed(Int)
    }

---

# 16. Auto Month Count

Auto is the default.

Auto should calculate the maximum number of month columns that fit comfortably within the available budget-content width.

Inputs should include:

- Current window width.
- Effective sidebar width.
- Category column width.
- Inspector width if applicable.
- Dynamic Type.
- Minimum usable month width.
- Safe-area/content margins.

Do NOT define behavior as crude device checks such as:

    if iPadPro13 { showFiveMonths }

The exact same device can be resized.

Instead:

    usableBudgetWidth
    ÷
    minimumMonthGroupWidth
    =
    candidateMonthCount

Clamp to the supported range.

Example:

    min 1
    max 5

Design constants should be tuned visually.

---

# 17. Fixed Month Count Preference

A manual setting expresses the user's preferred number of months.

Example:

    5

However, the app must never destroy usability simply to honor "5".

If the window physically cannot display five months above the hard minimum usable width:

- Temporarily display fewer months.
- Preserve the stored preference as 5.
- Restore 5 automatically when enough space returns.

Do not silently overwrite the user's preference.

Conceptually:

    preferred = 5
    physicallyPossible = 3
    rendered = 3

Resize larger:

    preferred = 5
    physicallyPossible = 5
    rendered = 5

This is especially important under Stage Manager.

---

# 18. Layout Mode Resolution

Use available width to derive layout state.

Conceptual algorithm:

    resolvePresentationMode(
        availableWidth,
        sidebarRequirements,
        singleMonthMinimumWidth,
        multiMonthMinimumWidth
    )

Priority while shrinking:

1. Reduce number of visible months.
2. Collapse multi-month presentation to single-month + sidebar.
3. Eventually remove persistent sidebar.
4. Return to existing compact Actualist.

Therefore:

    5 months
    4 months
    3 months
    2 months
        ↓
    single month + sidebar
        ↓
    compact app + bottom tabs

Do NOT prematurely remove the sidebar while a comfortable single-month sidebar layout still fits.

---

# 19. Do Not Over-Rely on Horizontal Size Class

`horizontalSizeClass` can help identify compact environments, but modern iPad windowing makes it too coarse to govern the complete experience.

Prefer actual layout width measurement.

Implementation may use:

- GeometryReader
- container-relative sizing
- custom Layout
- environment values
- other modern SwiftUI measurement APIs

provided the solution remains stable and avoids geometry feedback loops.

Centralize the layout calculation.

Do not scatter magic width comparisons throughout individual views.

Create something analogous to:

    struct BudgetLayoutMetrics {
        let presentationMode: BudgetPresentationMode
        let visibleMonthCount: Int
        let categoryColumnWidth: CGFloat
        let monthColumnWidth: CGFloat
        let inspectorAvailable: Bool
    }

One layout resolver should determine these values.

---

# 20. Assigned Cell Editing

On phone, Actualist already has a custom budget assignment/calculator keyboard.

Reuse that interaction model.

Do NOT create a completely unrelated iPad assignment editor.

For iPad sidebar modes, tapping an Assigned value should display the existing custom assignment keyboard as a floating popover anchored to the tapped cell.

Conceptually:

        Groceries
        Assigned
        $403.04
           ↓
    ┌─────────────────┐
    │ custom keypad   │
    │ / calculator    │
    └─────────────────┘

Use native popover presentation wherever possible.

Requirements:

- Popover is anchored to the selected Assigned cell.
- Existing calculator/expression logic is reused.
- Existing validation/business logic is reused.
- Commit updates the grid immediately.
- Cancel leaves the value unchanged.
- Popover should reposition automatically near screen edges.
- Only one assignment editor can be open at once.

The existing phone presentation remains unchanged.

---

# 21. Refactor Assignment Keyboard for Reuse

If the existing custom keyboard is tightly coupled to the phone sheet/view, separate:

1. Assignment/calculator logic.
2. Keypad view.
3. Presentation container.

Conceptually:

    AssignmentEditorModel
    AssignmentKeypad
    CompactAssignmentPresentation
    IPadAssignmentPopover

Do NOT duplicate calculator logic.

Both phone and iPad must ultimately invoke the same budget mutation path.

---

# 22. Hardware Keyboard Editing

The iPad interface should be usable with Magic Keyboard.

When an Assigned cell is selected, support direct hardware keyboard interaction where reasonable.

Minimum desired behavior:

    digits        -> input
    decimal point -> input
    Return        -> commit
    Escape        -> cancel
    Tab           -> next editable Assigned cell
    Shift-Tab     -> previous editable Assigned cell

If the existing calculator supports operators and expressions, reuse those semantics where practical.

Do not block implementation of the iPad UI on perfect spreadsheet-grade keyboard navigation, but structure selection state so it can be expanded later.

---

# 23. Pointer Behavior

Magic Keyboard/trackpad interaction should feel intentional.

At minimum:

- Assigned cells indicate clickability.
- Category rows have subtle hover affordance where appropriate.
- Buttons use native pointer behavior.
- Sidebar gets system pointer behavior automatically.
- Popovers anchor correctly to clicked cells.

Avoid excessive hover animation.

Actualist should remain touch-first while being excellent with a pointer.

---

# 24. Category Detail Inspector

Tapping a category on a sufficiently wide iPad should open a trailing inspector.

Preferred API:

    .inspector(...)

if it provides the required iPad behavior on the deployment target.

The inspector should feel like a native iPad trailing sidebar.

Do NOT create a permanent handcrafted panel if the system inspector API can provide the desired interaction.

---

# 25. Inspector Content

The inspector should substantially reuse the existing mobile category detail view.

The intent is:

    [ Multi-month Budget ] [ Category Detail ]

with the category detail effectively being the existing compact category screen presented at an appropriate narrow width.

Example:

    [sidebar]
    [budget grid........................][ Groceries Detail ]
                                        [ activity          ]
                                        [ goal info         ]
                                        [ actions           ]
                                        [ etc.              ]

This avoids inventing an entirely separate category-detail UX.

Extract reusable content from the mobile category view if necessary.

Do not duplicate category business logic.

---

# 26. Inspector Selection Behavior

Tap category name:

    selectedCategory = category
    inspectorPresented = true

Tap another category while inspector is open:

    inspector content changes to the new category

Close inspector:

    budget remains exactly where it was

The viewport month range and vertical scroll position must not reset.

---

# 27. Inspector and Window Width

Opening the inspector reduces available space.

The layout engine must account for this.

For Auto month count:

It is acceptable to reduce visible month count if necessary.

Example:

Before inspector:

    Sep | Oct | Nov | Dec

After inspector:

    Sep | Oct | Nov

because the inspector consumes width.

For a fixed preference:

Preserve the stored preference but temporarily clamp the rendered count if necessary.

Do not permit month columns to become unreadably narrow.

When the inspector closes, restore the previous number automatically.

---

# 28. Inspector in Narrower Sidebar Mode

The inspector may remain available in Mode B if the native system presentation can show it sensibly.

The system may overlay it rather than permanently consuming space.

Do not force three permanently visible columns into a width where they are uncomfortable.

In compact mode:

Use Actualist's existing category navigation/presentation instead.

Do not expose desktop inspector behavior on iPhone.

---

# 29. Available Cell Interaction

Preserve existing Actualist semantics as much as possible.

If tapping Available currently leads to category/activity information, route that destination into the inspector on wide iPad rather than navigating the entire budget away.

The distinction should generally become:

    Tap category name       -> Category inspector
    Tap Available           -> Relevant category detail/activity
    Tap Assigned            -> Assignment popover

Exact behavior should follow current Actualist logic rather than inventing divergent business semantics.

---

# 30. Month-Aware Actions

Every value in the multi-month grid must carry explicit month context.

Never assume that actions apply to a globally selected month merely because the phone interface did so.

For example:

    BudgetCellContext {
        categoryID
        month
        valueType
    }

Assignment mutations must know:

- category
- month
- amount

Alert actions must know:

- month
- affected category/categories

Category inspector should know which month initiated the interaction when relevant.

This prevents subtle bugs caused by having several months visible simultaneously.

---

# 31. Data Model / State Architecture

Do not build multi-month mode by spinning up several isolated copies of the existing single-month view model.

That risks:

- duplicated network/database work
- inconsistent rollovers
- stale future-month values
- divergent selection state
- excessive memory usage
- bugs after mutations

Instead create a viewport-level model over the same underlying Actual budget state.

Conceptually:

    BudgetViewportModel
        viewportStartMonth
        visibleMonths
        monthSnapshots
        groups
        categories
        selectedCategory
        selectedCell
        layoutPreference

The underlying budget source remains authoritative.

---

# 32. Cross-Month Budget Dependencies

This is especially important for Actual Budget.

A mutation in one month can affect future months because balances roll forward.

Example:

Changing September Groceries may alter:

- September Available
- October starting/Available state
- later visible months
- To Budget
- overspending alerts

Therefore:

DO NOT update only the tapped cell after a mutation.

The mutation path must invalidate/recompute all affected visible month projections.

The grid should settle into a coherent multi-month state after each edit.

Avoid independent month caches that become mutually inconsistent.

---

# 33. Adjacent Month Prefetching

Month navigation should feel instant.

Even though v1 does not horizontally scroll, consider keeping limited adjacent month data warm.

Example:

Visible:

    Sep | Oct | Nov

Prefetch:

    Aug
    Dec

Then pressing previous/next can transition immediately.

Do not aggressively preload years of budget data merely because multi-month mode exists.

Keep the prefetch window bounded.

If the underlying Actualist data layer already keeps all budget data locally and month derivation is cheap, use the existing architecture rather than layering unnecessary caching on top.

---

# 34. Vertical Scrolling

All months must scroll vertically together.

One gesture should move the entire budget row structure.

Never allow September to be scrolled to Groceries while October is scrolled to Utilities.

Group headers and values represent a single logical table.

---

# 35. Sticky Headers

Strongly consider a pinned header containing:

- visible month names
- compact To Budget status
- alert status
- Assigned / Available column labels

so the user retains month context while scrolling deep into a budget.

Use native/lazy pinned header behavior if practical.

Do not create a fragile manually synchronized overlay.

---

# 36. Row Density

The full iPad interface should become denser than simply scaling the phone list.

However:

Do not turn Actualist into Excel.

Preserve:

- readable spacing
- category icons
- Available capsules
- Actualist typography
- semantic colors
- touch-sized targets

Pointer use is an enhancement.

Touch remains a first-class input method.

---

# 37. Available Capsules

Actualist's green Available treatment is visually distinctive and should remain.

Multi-month mode may need a slightly more compact form to avoid excessive visual weight.

Do not remove these merely to resemble Actual web.

The guiding principle is:

    Actual information architecture
    +
    Actualist visual language

not:

    clone Actual CSS

---

# 38. Responsive Typography

Text size should not be indiscriminately shrunk to fit more months.

Auto mode should show fewer months before making values uncomfortably small.

Dynamic Type must influence physical capacity.

If the user has a larger accessibility text size:

    5 months -> 4 -> 3 -> 2

is preferable to microscopic or clipped values.

---

# 39. Window Resize Behavior

Resizing should feel stable.

Example:

Start full width:

    sidebar + 4 months

Shrink:

    sidebar + 3 months

Shrink:

    sidebar + 2 months

Shrink:

    sidebar + 1 month

Shrink further:

    compact Actualist

Do not reset:

- selected month
- viewport anchor
- vertical scroll position unnecessarily
- currently selected category unnecessarily
- user month-count preference

Animations should be restrained.

Avoid flashy morphing that makes rows difficult to track.

---

# 40. Transition Back to Compact

When crossing into compact mode:

- Current viewport start month becomes the compact selected month.
- Bottom navigation returns.
- Bottom Add Transaction accessory returns.
- Sidebar disappears.
- Multi-month grid becomes existing single-month budget.
- Assignment editing returns to existing compact presentation.
- Trailing inspector closes rather than unexpectedly turning into a navigation push.

No budget state should be lost.

---

# 41. Transition from Compact to Wide

Example:

User is in compact mode viewing:

    November 2026

They enlarge the window.

Mode B:

    Sidebar + November

Enlarge further:

    Sidebar + Nov | Dec | Jan

Do not suddenly anchor on the current calendar month if the user was intentionally looking somewhere else.

User context wins over "today."

---

# 42. Month Navigation Controls

Provide an explicit budget viewport control.

Potential structure:

    <   Sep 2026 – Nov 2026   >     Today

or integrate controls cleanly around month headers.

Requirements:

- Previous month.
- Next month.
- Current month.
- Direct month/year selection.

Month titles themselves can be interactive if this fits existing Actualist behavior.

No horizontal ScrollView should be used for month navigation in v1.

---

# 43. Month Keyboard Navigation

Optional but recommended:

    Command-[   previous month
    Command-]   next month

or another native-feeling shortcut.

Do not choose shortcuts that conflict with standard navigation behavior without testing.

At minimum, toolbar commands should expose keyboard shortcuts where conventional.

---

# 44. Settings

Add an iPad-specific budget display preference.

Possible location:

    Settings
      Budget
        Months Shown
          Auto
          1
          2
          3
          4
          5

Only expose this setting where it makes conceptual sense.

The preference may be visible on iPhone but disabled/explained, or hidden there.

Prefer not to clutter phone settings with a control that has no effect.

---

# 45. Preference Persistence

Month-count preference should be persistent across launches.

It is effectively a user interface preference.

Global preference is acceptable:

    Auto / 1 / 2 / 3 / 4 / 5

Window-local state should include:

- sidebar visibility
- viewport start month
- selected category
- inspector visibility
- vertical scroll state where feasible

Do not persist transient editing popovers.

---

# 46. Multiwindow Behavior

Different iPad windows may have different physical widths.

Therefore resolved month count must be computed independently per window.

Example:

Window A:

    preference = Auto
    width = 1300
    rendered = 5

Window B:

    preference = Auto
    width = 750
    rendered = 1

They share the preference.

They do not share the resolved layout.

---

# 47. Accessibility

Every budget cell must expose context sufficient for VoiceOver.

Do not announce merely:

    "$403.04"

Prefer semantic labeling equivalent to:

    "Groceries, September 2026, Assigned, $403.04"

and:

    "Groceries, September 2026, Available, $445.38"

Month summary controls should similarly communicate:

- month
- To Budget state
- alert status

Group collapse buttons should announce expanded/collapsed state.

---

# 48. Focus Model

Establish explicit focus/selection state for editable cells.

Conceptually:

    struct BudgetCellID: Hashable {
        let categoryID: ...
        let month: ...
        let field: BudgetField
    }

This enables:

- hardware keyboard editing
- popover anchoring
- future arrow-key navigation
- accessibility focus
- restoring sensible focus after edits

Do not make cell selection dependent on ephemeral SwiftUI view identity.

---

# 49. Empty / Loading / Error States

Multi-month mode must gracefully handle months that:

- contain no assignments
- are far in the future
- are loading
- fail to derive temporarily
- become stale during sync

Do not allow one month failure to crash the entire grid.

Prefer coherent viewport-level error handling where failures are global, and month-level placeholders only where failures are genuinely month-specific.

---

# 50. Sync Behavior

If Actual sync updates data while multiple months are visible:

- update all impacted cells
- update group totals
- update To Budget summaries
- update alerts
- preserve scroll position
- preserve selected category if it still exists
- do not recreate the entire navigation hierarchy unnecessarily

Avoid excessive animation during large sync changes.

---

# 51. Deletion / Hidden Categories

If a category becomes hidden/deleted while its inspector is open:

- close or transition the inspector gracefully
- clear invalid selection
- do not leave a stale detail view referring to missing data

If group visibility changes, update the shared row hierarchy across all months simultaneously.

---

# 52. Performance Targets

The multi-month grid may render substantially more financial values than the phone UI.

Optimize structure accordingly.

Goals:

- Smooth vertical scrolling.
- No visible lag when moving one month backward/forward.
- No multi-second layout recomputation on window resize.
- No five-fold multiplication of expensive budget calculations solely because five months are visible.
- Editing should update relevant values quickly.
- Opening/closing inspector should not rebuild unrelated major views.

Use lazy row rendering where appropriate.

Profile before performing speculative micro-optimization.

---

# 53. Reuse Existing Business Logic

This project is primarily a presentation architecture change.

DO NOT rewrite stable budget logic unless required.

Reuse:

- assignment calculations
- Available calculations
- To Budget calculations
- overspending logic
- Cover logic
- category hierarchy
- formatting
- currency handling
- multi-currency support
- existing transaction editor
- existing category details
- existing navigation destinations

The iPad work should expose existing capabilities differently rather than fork them.

---

# 54. Suggested High-Level View Structure

Illustrative only:

    ActualistRootView
      ├── CompactRootView
      │     └── existing TabView
      │
      └── AdaptiveIPadRootView
            └── NavigationSplitView
                  ├── ActualistSidebar
                  │
                  └── selected destination
                        ├── BudgetWorkspaceView
                        │     ├── SingleMonthBudgetView
                        │     └── MultiMonthBudgetView
                        │
                        ├── Spending
                        ├── Accounts
                        └── Reports

    MultiMonthBudgetView
      ├── BudgetViewportHeader
      │     ├── month navigation
      │     └── visible month summaries
      │
      └── BudgetGrid
            ├── MonthColumnHeaders
            ├── GroupHeaderRow
            └── CategoryBudgetRow

    CategoryBudgetRow
      ├── CategoryIdentityCell
      └── MonthBudgetCellGroup × visibleMonths
            ├── AssignedCell
            └── AvailableCell

    BudgetWorkspaceView
      └── .inspector(...)
            └── CategoryDetailContent

Do not follow these names dogmatically if the repository already has better abstractions.

The important requirement is separation of concerns.

---

# 55. Avoid Parallel Phone/iPad Implementations

Do not create:

    PhoneBudgetLogic
    IPadBudgetLogic

Instead prefer:

    shared budget models
    shared formatting
    shared row concepts
    presentation-specific containers

Some views will necessarily differ because the information architecture differs.

That is acceptable.

Business rules should not.

---

# 56. Existing Category Detail Reuse

If the current category detail screen combines navigation shell and content tightly, refactor it into:

    CategoryDetailContent

plus presentation wrappers:

    CompactCategoryDetailScreen
    IPadCategoryInspector

This will allow the inspector to remain approximately phone-width without embedding an entire fake phone navigation stack.

---

# 57. Existing Transaction Editor

Do not redesign transaction entry in this project.

Sidebar mode merely changes how the existing Add Transaction editor is invoked.

The same transaction editor should appear.

If the editor already uses a sheet appropriate for iPad, preserve it.

If iPadOS automatically presents it differently, allow native adaptation unless it causes obvious usability problems.

---

# 58. Visual Design Direction

Large iPad mode should visually communicate:

- dense financial workspace
- native iPad application
- Actualist identity

It should NOT communicate:

- stretched iPhone
- website embedded in SwiftUI
- spreadsheet clone
- Mac app pretending to be iPad
- custom navigation framework fighting the OS

Prefer native materials and system components around the bespoke Actualist budget content.

---

# 59. Mac Compatibility Scope

Actualist can currently be installed and used on Apple Silicon Macs as an iPad application.

Preserve that capability.

This project does NOT need to create:

- Mac menu architecture
- AppKit sidebar behavior
- Mac toolbar redesign
- Mac window model
- Mac-specific keyboard command system
- Mac-native density
- Catalyst-specific UI
- separate Mac preferences

The iPad UI may naturally be usable with a mouse/keyboard on Mac.

That is sufficient.

Long term, a genuinely Mac-native Actualist interface may be implemented separately.

Do not distort the iPad design to solve the future Mac application today.

---

# 60. Implementation Phases

## Phase 0 — Audit / Preparation

Before changing UI:

1. Identify current root TabView/navigation structure.
2. Identify current Budget single-month view.
3. Identify current month-selection state.
4. Identify category/group view models.
5. Identify Assignment keyboard/calculator code.
6. Identify Category Detail implementation.
7. Identify Add Transaction presentation.
8. Identify To Budget and alert components.
9. Identify where category group expanded/collapsed state lives.
10. Identify data dependencies between month calculations.

Document which pieces can be reused directly and which need extraction.

Do not begin by rewriting the whole root view.

---

## Phase 1 — Adaptive Root Navigation

Implement the width-aware shell.

Deliver:

- Compact root remains existing TabView.
- Wider root becomes NavigationSplitView.
- Sidebar contains defined navigation structure.
- Bottom tabs disappear in sidebar mode.
- Add Transaction moves to toolbar.
- Window resizing can transition between the two.
- Current destination survives transitions where sensible.

Do NOT implement multi-month grid yet.

Acceptance at end of Phase 1:

Actualist already feels substantially more native on iPad even though Budget still shows one month.

---

## Phase 2 — Wide Single-Month Budget

Adapt Budget for sidebar mode.

Deliver:

- wider category labels
- cleaner Assigned / Available alignment
- appropriate use of extra space
- existing To Budget summary
- existing alerts
- same budget functionality

This establishes the bridge presentation.

Do not prematurely cram several months in.

---

## Phase 3 — Multi-Month Data Viewport

Introduce:

    viewportStartMonth
    visibleMonthCount
    visibleMonths

Build the data layer capable of exposing several month projections simultaneously.

Verify:

- rollover behavior
- totals
- To Budget
- alerts
- currency formatting
- category hierarchy

before focusing heavily on visual polish.

---

## Phase 4 — Multi-Month Grid

Implement:

- shared category column
- month groups
- Assigned / Available subcolumns
- group totals
- compact month summaries
- vertical scrolling
- pinned headers if practical
- previous / next / Today controls

No horizontal scrolling.

At this phase, read-only multi-month viewing should be solid.

---

## Phase 5 — Month Count Preferences

Implement:

    Auto
    1
    2
    3
    4
    5

Add layout capacity calculation.

Verify window resizing continuously changes resolved count.

Ensure fixed preferences are temporarily clamped rather than overwritten.

---

## Phase 6 — Assignment Editing

Refactor custom calculator keyboard if necessary.

Implement anchored assignment popover.

Verify edits propagate across affected visible months.

Add hardware keyboard commit/cancel behavior.

---

## Phase 7 — Category Inspector

Extract reusable category detail content.

Implement trailing native inspector.

Verify:

- category selection
- switching categories
- inspector close
- viewport preservation
- layout month-count reaction
- resize behavior

---

## Phase 8 — Pointer / Keyboard Polish

Add:

- sensible focus model
- Tab traversal
- Return/Escape
- Add Transaction shortcut if appropriate
- month-navigation shortcuts if appropriate
- hover affordances
- pointer testing

Do not transform the app into a desktop spreadsheet.

---

## Phase 9 — Accessibility / Dynamic Type

Audit:

- VoiceOver cell labels
- group states
- month context
- inspector
- To Budget
- alerts
- keyboard focus
- large Dynamic Type

Verify Auto month count decreases appropriately when accessibility sizing requires more width.

---

## Phase 10 — Regression / Stress Testing

Test:

### iPhone
- portrait
- landscape where supported
- current Budget
- transaction creation
- assignment editor
- category details
- tab bar
- bottom accessory

### iPad narrow window
- compact interface
- resize into sidebar mode

### iPad medium
- sidebar + one month
- sidebar collapse/expand

### iPad portrait
- Auto month count
- inspector
- keyboard

### iPad large landscape
- 2 months
- 3 months
- 4 months
- 5 months
- Auto
- manual count
- inspector

### Stage Manager
Continuously resize through all thresholds.

Verify no:
- crashes
- invalid geometry
- overlapping columns
- stale month data
- disappearing controls
- duplicated navigation
- bottom tab/sidebar overlap

### Magic Keyboard
- pointer
- assignment edit
- Tab
- Return
- Escape
- toolbar commands

### Mac running iPad app
Smoke test only.

Ensure it remains launchable and usable.

No Mac redesign.

---

# 61. Important Edge Cases

Test explicitly:

1. Category name extremely long.
2. Currency values extremely large.
3. Negative Available values.
4. Zero To Budget.
5. Negative To Budget.
6. Several alerts in several visible months.
7. No alerts.
8. Hidden category groups.
9. Large number of categories.
10. Every group expanded.
11. Every group collapsed.
12. Multi-currency budget.
13. Month very far in past.
14. Month very far in future.
15. Editing first visible month changes later months.
16. Sync arrives during assignment editing.
17. Category deleted while inspector open.
18. Window resized while assignment popover open.
19. Window resized while inspector open.
20. Sidebar collapsed while inspector open.
21. Dynamic Type changed while displaying 5 months.
22. User preference 5 but only 2 physically fit.
23. Orientation change.
24. iPad external display / unusual window dimensions.
25. Empty budget.

---

# 62. Visual Acceptance Criteria

The feature is visually successful when:

- A narrow iPad window still looks essentially like current Actualist.
- A medium window unmistakably looks like a native iPad app.
- A large window no longer resembles an oversized iPhone.
- Multiple months can be compared without navigating away.
- Category names appear only once.
- To Budget is obvious without dominating the screen.
- Alerts remain obvious and actionable.
- Available values retain Actualist's visual identity.
- Sidebar looks like system iPad navigation.
- Inspector looks native rather than bolted on.
- The grid feels dense but not spreadsheet-like.

---

# 63. Functional Acceptance Criteria

The project is not complete until all of these are true:

[ ] Existing iPhone Budget behavior remains intact.

[ ] Compact iPad window uses existing bottom-tab interface.

[ ] Medium width uses native sidebar and one-month Budget.

[ ] Large width automatically enables multiple months.

[ ] Month count can be Auto or explicitly 1–5.

[ ] Auto responds to actual window size.

[ ] Fixed month preference survives temporary width constraints.

[ ] No horizontal month scrolling exists.

[ ] Previous/next changes viewport one month at a time.

[ ] Current month can be restored directly.

[ ] Category groups expand/collapse across all visible months together.

[ ] Group totals align correctly for every visible month.

[ ] Every month shows correct Assigned values.

[ ] Every month shows correct Available values.

[ ] Every month exposes its own To Budget state.

[ ] Month alerts remain visible and actionable.

[ ] Assigned values can be edited from the grid.

[ ] iPad Assigned editing uses floating anchored custom-keyboard popover.

[ ] Existing calculator logic is shared rather than duplicated.

[ ] Editing an earlier month correctly recomputes affected later months.

[ ] Category tap opens trailing inspector on iPad.

[ ] Inspector substantially reuses mobile category-detail content.

[ ] Changing category selection updates inspector.

[ ] Closing inspector does not reset budget viewport.

[ ] Opening inspector can reduce Auto month count when required.

[ ] Add Transaction appears in toolbar in sidebar modes.

[ ] Existing bottom Add Transaction accessory remains in compact mode.

[ ] Magic Keyboard can perform basic assignment editing.

[ ] Pointer interaction is comfortable.

[ ] Dynamic Type does not produce unusable five-column layouts.

[ ] VoiceOver identifies category + month + field for budget values.

[ ] App remains usable as an iPad app installed on Mac.

---

# 64. Explicit Non-Goals

Do NOT include any of the following unless separately approved:

- Native macOS redesign.
- Mac Catalyst conversion.
- Web UI embedding.
- Exact clone of Actual's desktop CSS.
- Horizontal month scrolling.
- Infinite month canvas.
- Dragging month columns around.
- User-resizable individual month column widths.
- Spreadsheet formula editing.
- Full Excel-style keyboard navigation.
- Completely new transaction editor.
- Completely new category detail interface.
- Rewrite of Actual budget calculation logic.
- Rewrite of sync architecture without demonstrated necessity.
- Separate iPad-only financial business rules.
- Custom replacement for NavigationSplitView.
- Custom fake sidebar.
- Custom fake iPad window chrome.

---

# 65. Engineering Guardrails

When implementing this plan:

1. Preserve existing compact behavior first.

2. Do not "clean up" unrelated architecture merely because the iPad work touches a nearby file.

3. Prefer extraction over duplication.

4. Keep business logic shared.

5. Keep layout calculations centralized.

6. Do not scatter arbitrary width checks throughout views.

7. Do not use device model checks.

8. Do not use screen bounds as a proxy for current window width.

9. Do not implement horizontal scrolling "temporarily."

10. Do not silently remove existing Budget functionality in multi-month mode.

11. Do not shrink typography excessively just to meet a requested month count.

12. Do not force five months into a window that cannot support them.

13. Preserve current Actualist visual language.

14. Use native Apple navigation/presentation APIs wherever they solve the problem cleanly.

15. Treat iPad window resizing as a first-class interaction, not an edge case.

---

# 66. Recommended First Prototype

Before polishing every feature, create one focused prototype demonstrating this exact path:

FULL WIDTH IPAD:

    ┌──────────── Sidebar ────────────┐
    │ Budget                         │
    │ Spending                       │
    │ Reports                        │
    │                                │
    │ Accounts                       │
    │   Checking                     │
    │   Savings                      │
    │                                │
    │ Settings                       │
    └────────────────────────────────┘

    ┌──────────────────────────────────────────────────────────────────────────┐
    │  ‹   Sep 2026 – Nov 2026   ›   Today                  [+ Transaction]   │
    ├────────────────┬──────────────────┬──────────────────┬───────────────────┤
    │                │    SEP 2026      │    OCT 2026      │    NOV 2026       │
    │                │ $3,119 To Budget │ $2,300 To Budget │ $1,800 To Budget  │
    │                │   ! 1 Overspent  │                  │                   │
    │ Category       │ Assigned | Avail │ Assigned | Avail │ Assigned | Avail  │
    ├────────────────┼──────────────────┼──────────────────┼───────────────────┤
    │ Monthly Bills  │  6194   | 8273   │  ...    | ...    │  ...    | ...     │
    │ 🏠 Mortgage    │  3645   | 3354   │  ...    | ...    │  ...    | ...     │
    │ 🍔 Groceries   │   403   |  445   │  ...    | ...    │  ...    | ...     │
    │ 🛠 Utilities   │   437   |  959   │  ...    | ...    │  ...    | ...     │
    │ ⛽ Gas          │   200   |  200   │  ...    | ...    │  ...    | ...     │
    └────────────────┴──────────────────┴──────────────────┴───────────────────┘

Tap September Groceries Assigned:

                         ┌─────────────────┐
                         │ Actualist       │
                         │ assignment      │
                         │ calculator      │
                         │ keypad          │
                         └─────────────────┘

Tap Groceries:

    ┌───────────── main multi-month budget ──────────────┐┌────────────────────┐
    │                                                    ││ Groceries          │
    │                                                    ││                    │
    │                                                    ││ Existing category  │
    │                                                    ││ detail content     │
    │                                                    ││ adapted from       │
    │                                                    ││ compact Actualist  │
    │                                                    ││                    │
    └────────────────────────────────────────────────────┘└────────────────────┘

Then physically resize the window.

The same running interface should progressively become:

    sidebar + 3 months
              ↓
    sidebar + 2 months
              ↓
    sidebar + 1 month
              ↓
    current compact Actualist

If this prototype feels natural while resizing, the architectural direction is correct.

---

# 67. Final Product Intent

The completed iPad interface should answer this question:

"What would Actualist look like if it had been designed specifically for a large touch-and-pointer canvas?"

It should not answer:

"What happens if we make the iPhone screen 13 inches wide?"

Actual Budget provides the conceptual inspiration for multi-month density.

Actualist remains responsible for the interaction design, visual identity, and native Apple-platform behavior.

The large-screen experience should make iPad one of the best ways to actively work on a budget:

- multiple months visible
- categories aligned across time
- fast inline assignment
- native sidebar navigation
- instant category inspection
- touch when desired
- Magic Keyboard when desired

while preserving the existing compact Actualist interface whenever the window no longer has room for that richer presentation.