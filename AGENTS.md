# AGENTS.md

Guidance for coding agents working on Actualist.

## Project Intent

Actualist is a native iOS 26+ client for Actual Budget through the Actual HTTP API. Preserve the visual direction in `reference/*.PNG`: dark, compact, rounded, money-forward, Liquid Glass-aware, and optimized for repeated budget review.

## Current References

- API contract: `reference/openapi.json`
- Budget UI reference: `reference/Budget.PNG`
- Accounts UI reference: `reference/Accounts.PNG`
- Account transactions UI reference: `reference/Account Transactions.PNG`
- Product plan: `docs/PLAN.md`
- Development pipeline: `docs/DEVELOPMENT.md`

## Development Defaults

- Use Swift and SwiftUI only for app UI.
- Do not introduce UIKit UI code.
- Use a standard Xcode SwiftUI app project unless the user explicitly changes direction.
- Target iOS 26+.
- Enforce iOS 26 Liquid Glass for all glass-like controls, buttons, toolbars, floating navigation, and panels. Use only public SwiftUI Liquid Glass APIs:
  - `.buttonStyle(.glass)`
  - `.buttonStyle(.glassProminent)`
  - `.buttonStyle(.glass(...))`
  - `.glassEffect(_:in:)`
- Liquid Glass must be system-owned wherever SwiftUI provides native chrome. Do not wrap native toolbar buttons, tab bars, navigation bars, sheets, alerts, or menus in custom glass containers.
- Do not apply `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, or `.buttonStyle(.glass(...))` to buttons inside a SwiftUI `.toolbar`. Let the toolbar render its own Liquid Glass button chrome. Toolbar labels should usually be plain `Button` views with SF Symbols and optional font/control-size adjustments only.
- The main app navigation must use native `TabView` with `.tabItem`. Do not recreate the tab bar with custom `HStack`, `ZStack`, `safeAreaInset`, overlay, capsule, or `FloatingTabBar` views.
- Never place a glass-styled button inside a view that already has `.glassEffect`, and never place a `.glassEffect` wrapper around a native glass button. This creates the visible "button inside button" defect on device.
- Use `.glassEffect(_:in:)` only for standalone non-control panels or custom surfaces that are not themselves native SwiftUI chrome. If the element is clickable and should look like a button, prefer the appropriate native `Button` style rather than wrapping it in another glass shape.
- Do not use `GlassEffectContainer` in this app until it has been explicitly re-tested on a physical iOS 26 device. The first physical-device run after adding it crashed before app code with a system `OS_dispatch_mach_msg _setContext:` selector failure.
- Do not fake Liquid Glass with `.regularMaterial`, `.thinMaterial`, `.ultraThinMaterial`, `.thickMaterial`, blur overlays, translucent hand-rolled capsules, or custom material-backed toolbar containers.
- Row hit areas may still use `.buttonStyle(.plain)` when they should look like list rows instead of controls.

### Liquid Glass Examples

Toolbar buttons must be plain toolbar content. The toolbar supplies the glass.

Wrong:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button {
        Task { await load() }
    } label: {
        Image(systemName: "arrow.clockwise")
    }
    .buttonStyle(.glass(.clear))
    .glassEffect(.regular, in: Circle())
}
```

Right:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button {
        Task { await load() }
    } label: {
        Image(systemName: "arrow.clockwise")
    }
    .font(.body.weight(.semibold))
    .controlSize(.small)
}
```

The main app tab bar must be native `TabView`, not a custom floating glass control.

Wrong:

```swift
ZStack(alignment: .bottom) {
    content

    HStack {
        Button("Budget") { selectedTab = .budget }
            .buttonStyle(.glass(.regular))
        Button("Accounts") { selectedTab = .accounts }
            .buttonStyle(.glass(.regular))
    }
    .glassEffect(.regular, in: Capsule())
}
```

Right:

```swift
TabView(selection: $selectedTab) {
    BudgetView()
        .tabItem {
            Label("Budget", systemImage: "list.bullet.rectangle.portrait.fill")
        }
        .tag(AppTab.budget)

    AccountsView()
        .tabItem {
            Label("Accounts", systemImage: "building.columns.fill")
        }
        .tag(AppTab.accounts)
}
```

Glass panels are allowed only for non-native, non-toolbar surfaces. Do not put glass buttons inside glass panels unless the design has been verified on a physical device and does not show nested glass.

Wrong:

```swift
HStack {
    Button("Settings") { showSettings = true }
        .buttonStyle(.glass)
}
.glassEffect(.regular, in: Capsule())
```

Right:

```swift
GlassPanel {
    HStack {
        Text("Server")
        Spacer()
        Text(status)
    }
}
```

Prominent standalone actions may use native glass button styles when they are not inside native toolbar/tab chrome and not inside another glass surface.

Right:

```swift
Button {
    Task { await connect() }
} label: {
    Text("Connect")
        .frame(maxWidth: .infinity)
}
.buttonStyle(.glassProminent)
```

Pre-handoff visual rule: if any control looks like a smaller rounded rectangle or capsule sitting inside a larger rounded rectangle or capsule, it is wrong. Remove one layer of glass before handing off.
- Keep API transport, API Codable models, domain/display models, view models, and views separated.
- Keep SwiftUI views layout-focused. Do not put API composition, loading/error workflows, budget derivation, or screen state machines directly in views.
- Put Actual API composition in repositories. Put feature screen state, loading/error handling, expansion/selection state, and derived display logic in feature view models.
- `AppState` should coordinate app-wide session/settings/routing only. Do not grow it into a catch-all feature view model.
- Keep design values in a small theme/design-system layer instead of scattering colors and dimensions through views.
- Treat write actions as explicit flows with confirmation or clear review states; this app controls real budget data.
- Decode Actual API responses defensively. The checked-in OpenAPI has mismatches such as string examples for fields typed as integers and boolean examples for fields typed as strings.
- Store API keys in Keychain and never log them.
- Do not commit real API hostnames, tokens, budget IDs, or personal financial data.
- Keep dependencies minimal. Prefer Apple frameworks before adding packages.

## UI Principles

- Match the screenshot palette until settings-driven themes are implemented.
- Use real Liquid Glass APIs for prominent actions and reusable panels. For native navigation chrome, use native SwiftUI structures (`TabView`, `.toolbar`, navigation stacks) and let the system draw the Liquid Glass.
- Any visual result that looks like a smaller rounded button inside a larger rounded button is wrong and must be fixed before handoff.
- Use native symbols/icons where possible.
- Keep rows dense and scannable.
- Make money states visually distinct:
  - Green for available/positive.
  - Yellow for caution/special availability.
  - Red for overspent/error.
  - Gray for zero/inactive.
- Support Dynamic Type without breaking row layout.
- Build loading, empty, error, and partial-refresh states for each API-backed screen.
- First launch must route to server URL and API key onboarding before the main app shell.
- The main tab bar should include only implemented views: Budget, Accounts, and Settings initially.
- Closed accounts and hidden categories should be collapsed by default when present.

## Physical iPhone Build And Run

When the user asks to build and run on their iPhone, use the connected physical device named `Airy` when present.

1. List connected devices:

```sh
xcrun devicectl list devices
```

2. Build for the physical iPhone using Xcode's hardware UDID, not the CoreDevice identifier from `devicectl`. If needed, get Xcode destinations with:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -showdestinations
```

The known working Xcode destination for `Airy` is:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS,id=00008150-0001189C2220401C' \
  -derivedDataPath .derivedData \
  build
```

3. Install the built app with `devicectl` using the CoreDevice identifier from `xcrun devicectl list devices`. The known working CoreDevice identifier for `Airy` is `F8621CA4-4F85-50E3-A00F-FE846C848327`:

```sh
xcrun devicectl device install app \
  --device F8621CA4-4F85-50E3-A00F-FE846C848327 \
  .derivedData/Build/Products/Debug-iphoneos/Actualist.app
```

4. Launch the app:

```sh
xcrun devicectl device process launch \
  --device F8621CA4-4F85-50E3-A00F-FE846C848327 \
  com.sporez.actualist
```

These commands usually need permission outside the filesystem sandbox because Xcode and CoreDevice access signing credentials, device services, and connected-device state.

## Verification Checklist

Before handing off UI or API work:

- Run the relevant unit tests.
- Run `scripts/lint-liquid-glass.sh` after UI/design-system work.
- Confirm `BudgetMonth`, `Account`, and `Transaction` decoding against fixtures or the live container.
- Verify money formatting against Actual amount units.
- Verify API key storage/redaction behavior.
- Inspect the UI in light/dark settings if light mode exists, and in dark mode by default.
- For frontend changes, verify the main screens in an iPhone-sized simulator or preview.
