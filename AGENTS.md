# AGENTS.md

Guidance for coding agents working on Actualist.

## Project Intent

Actualist is a native iOS 26+ local-first client for Actual Budget. It talks to the normal Actual server sync API, stores an imported SQLite budget locally, applies CRDT messages, and renders from the local database. The app no longer relies on the sibling `actual-http-api` package or its REST/OpenAPI contract. Preserve the visual direction: dark, compact, rounded, money-forward, Liquid Glass-aware, and optimized for repeated budget review.

## Current References

- Development pipeline: `docs/DEVELOPMENT.md`
- Mechanical gate: `scripts/check.sh`. Run it before handing off a change. It
  covers whitespace, Liquid Glass, TestFlight notes, synchronized-group
  integrity, and file-size signals. It does not replace tests.
- Simulator and device ids for this machine: gitignored
  `scripts/lib/destinations.sh` (copy `scripts/lib/destinations.example.sh`).
  Pin destinations by UDID, never by display name.

## Local-First Backend

- The app connects to a normal Actual server, not the `actual-http-api` REST wrapper.
- Sync traffic uses Actual's `/sync/sync` protocol and local CRDT message storage.
- Reads must come from `LocalFirstActualStore` and `BudgetDatabase`, not from HTTP REST endpoints.
- Writes must generate Actual-compatible CRDT messages, apply them to SQLite, enqueue them in `actualist_outbox`, then reload local caches and opportunistically flush.
- Do not commit sync tokens, passwords, encryption keys, budget IDs, imported databases, or personal financial data.

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
- Keep sync transport, SQLite/CRDT models, domain/display models, view models, and views separated.
- Keep SwiftUI views layout-focused. Do not put API composition, loading/error workflows, budget derivation, input interpretation/math, write orchestration, or screen state machines directly in views.
- SwiftUI views may format layout, bind controls, show state already prepared for display, and call view-model intent methods. They must not compute final money amounts, decide API payload values, mutate model state beyond local presentation toggles, or contain business rules hidden in button actions/gestures.
- Route all fetched data through `LocalFirstActualStore` (`Actualist/LocalFirst/`): it is the single in-memory source of truth over the local budget database and owns sync, SQLite reads, local CRDT writes, request coalescing, and post-write local reloads. Never let a screen call sync transports or REST clients directly or hold its own duplicate copy of budget data.
- Reads are local-first: show the store's cached snapshot instantly, then refresh/pull CRDT messages in the background when appropriate. Writes must apply locally, enqueue outbox messages, reload affected local caches before the flow returns, and then opportunistically flush. Clear the cache (`reset()`) on budget switch / connection change.
- The repository *protocols* (`BudgetRepositoryProtocol`, `TransactionRepositoryProtocol`) are the dependency-injection seam the store conforms to; inject the store in production and fakes in tests. There are no concrete repository structs.
- Put feature screen state, loading/error handling, expansion/selection state, submission state machines, and derived display logic in feature view models.
- Put reusable pure calculations or draft input interpretation in explicit value types/helpers owned by the feature or domain layer, then unit test them. Views should consume the resulting display state; repositories should receive the already-decided command values.
- `AppState` should coordinate app-wide session/settings/routing only. Do not grow it into a catch-all feature view model.
- Keep design values in a small theme/design-system layer instead of scattering colors and dimensions through views.
- Treat write actions as explicit flows with confirmation or clear review states; this app controls real budget data.
- Decode Actual sync metadata and local SQLite values defensively. Actual budget files may have schema differences across versions and migrated data.
- Store sync tokens and encryption keys in Keychain and never log them.
- Do not commit real server hostnames, sync tokens, passwords, encryption keys, budget IDs, imported databases, or personal financial data.
- Keep dependencies minimal. Prefer Apple frameworks before adding packages.

## Commit And TestFlight Notes

Trailers are the What to Test changelog. They are not QA scripts. The release
helper keeps the newest note per `[topic]` and drops earlier ones.

Decide, in this order:

1. Internal (docs, tests, refactor, TestFlight prepare, no user-visible change)?
   Omit the trailer. Never write a placeholder such as `No tester-visible change`.
2. Same product surface as an earlier unreleased commit?
   Rewrite that topic's full note. Do not add a second topic or a delta line.
3. New tester-visible surface?
   Add exactly one `TestFlight-Note: [topic] ...` using a topic from
   `config/testflight/topics.txt`. Add a topic there only when this commit
   introduces a new surface.

A commit has zero or one trailer. Two trailers only if it ships two unrelated
surfaces. Never one trailer per incremental slice of the same feature.

Required format:

```text
TestFlight-Note: [rules] Added a Rules screen under Settings → Budget & Data. Rules apply in Actual's order and can split a match, link it to a schedule, or stop a matching new transaction from being saved.
```

Hard rules:

- Topic is required and must be in `config/testflight/topics.txt`.
- Topic names a product surface a tester would tap, never a commit slice.
  Wrong: `[rules-split]`, `[shortcuts-get-accounts]`, `[privacy-row]`.
  Right: `[rules]`, `[shortcuts]`, `[settings]`.
- The text is the complete current summary for that topic, not the delta since
  the last commit. Later commits with the same topic replace earlier ones.
- Keep the note at or under 400 characters (`TESTFLIGHT_NOTE_MAX_CHARS` in
  `scripts/lib/testflight-notes.sh`). Measure the draft before committing with
  `scripts/lint-testflight-notes.sh --message-file <file>`: a trailer that
  fails only after being pushed cannot be fixed without rewriting history.
  Trim the summary instead of appending clauses to an existing topic note.
- Start with `Added`, `Fixed`, `Improved`, `Moved`, `Renamed`, `Removed`, or
  `Combined`.
- Describe what changed and where to find it. Do not tell the tester what to
  tap, say, search, try, confirm, or verify.
- Write in the tester's voice, not the developer's. A tester who has never
  read Actual's internals or this repo must understand every sentence. Say
  what they will see or be able to do, and on which screen — never the
  mechanism that produces it.
- Name outcomes, not behaviors. Do not enumerate internal rules, guards, or
  clamp/refuse/fail-close branches; pick the one or two results a tester can
  observe. The full mechanism belongs in the commit body, not the trailer.
- No version-parity references (`matches Actual 26.8.1`), math symbols
  (`±7-day`), or engine/schema terms (CRDT, split family, rule projection,
  minor units, available vs To Budget sign conventions). If the tester does
  not type it or tap it, do not name it. Feature names the app itself shows
  (Apply Templates, Bank Sync, Split, Starting Balance) are allowed.
- Keep sentences short and concrete: one user-visible change per sentence,
  common words, no stacked clauses joined by commas and semicolons.
- No implementation jargon, credentials, hostnames, budget IDs, personal data,
  or real financial amounts.
- Omit layout-only and developer-only notes. If a tester would not notice it
  while using the app, it does not get a trailer.

Wrong:

```text
TestFlight-Note: Try Import Transaction from Text with "spent 12.50 on coffee".
TestFlight-Note: Added split rule actions.
TestFlight-Note: [shortcuts-siri] Say “Open spending in Actualist” and confirm the Spending tab comes forward.
```

Right:

```text
TestFlight-Note: [shortcuts] Added Shortcuts and Siri support, grouped under Accounts, Budget, Transactions, and Reports. You can log or import transactions, assign or move budget money, open screens, and read balances.
```

Developer-voice notes are wrong even when every hard rule passes. Describe
the outcome a tester sees, not the machinery:

Wrong:

```text
TestFlight-Note: [budget] Apply Templates reserves Hold for Next Month, tracks from total saved, refuses a stale note-based template directive, and clamps a priority template to leftover To Budget like Actual.
TestFlight-Note: [banksync] Fixed Bank Sync so imported-payee rules run before matching, ±7-day matches work across calendar boundaries, and unknown booking state stays pending.
```

Right:

```text
TestFlight-Note: [budget] Apply Templates now matches the web app more closely. Money you hold for next month stays reserved, average templates use your real spending history, and a template never assigns more than you have left to budget.
TestFlight-Note: [banksync] Fixed Bank Sync matching so downloaded transactions find existing ones even across month boundaries, and your own payee rules now apply before matches are suggested.
```

After writing trailers, run `scripts/lint-testflight-notes.sh --range <base>..HEAD`
against the commits that added them. Do not generate or prepare the next build's
release artifacts merely to validate a commit or OTA build; that belongs only to
an explicitly requested TestFlight release workflow.

## Mandatory Pre-Implementation Architecture Gate

Passing tests does not establish that a change complies with this file. Before
editing production code, complete this gate and let it determine the
implementation shape:

- Read the complete destination file and the directly related view model,
  repository/store, domain helper, and tests. Do not patch from a narrow snippet
  when ownership may sit elsewhere.
- Measure every prospective Swift destination with `wc -l` and inspect its
  current responsibilities. Also inspect `git diff --numstat` during the work so
  incremental growth remains visible.
- Search with `rg` for existing types, helpers, formatters, calculations,
  derived-state projections, and state machines before adding another one. A
  locally convenient duplicate is not an acceptable implementation.
- State the ownership decision before implementation: view-local presentation,
  feature view model, pure domain/value helper, repository/store, database, sync
  transport, or app-wide coordination. Put the behavior at that seam from the
  start; do not add it to the nearest file and promise a later cleanup.
- For every new or changed SwiftUI `@State` property, task, binding setter,
  button action, or gesture, decide whether it is presentation-only. Loading,
  errors, pagination, debounce/search, submission, deletion, write
  orchestration, payload construction, input interpretation, money math, and
  derived display state belong outside the view.
- Do not add feature workflows or feature-specific state to `AppState`.
  `AppState` may coordinate app-wide session, settings, and routing while a
  focused collaborator owns each independent workflow.
- Do not represent a multi-step workflow with a growing collection of loosely
  coupled Boolean flags, optional tasks, and continuations. Use an explicit
  state model or focused coordinator with cancellation, identity/generation,
  and stale-result behavior made deliberate and testable.
- Identify the verification seam before implementation. Any new calculation,
  state transition, cancellation path, compatibility branch, or command value
  must have a focused test plan before production code is written.

If this gate reveals that the requested change needs a structural extraction,
the extraction is part of the change. Do not defer it merely to keep the first
diff smaller.
- When the gate, the duplication/complexity discipline, or any review surfaces
  work that is real but should be deferred rather than done now, ask the user
  before parking it. Do not silently drop a discovered follow-up, and do not
  add one without confirming. Examples: a structural extraction blocked by the
  file-size threshold, a dead code path whose removal is out of scope, a
  setting or feature surfaced by a review but not requested, a compatibility
  branch without a fixture yet.

## File Size And Structural Maintainability

- Treat file size as an architectural signal, not a quota. Reassess a Swift file
  before adding code when it is near or above 800 lines. Record an explicit
  keep-or-split decision before implementation.
- Do not add a substantive responsibility to a file that is already at or above
  800 lines. Extract a cohesive seam first. A truly local bug fix may proceed
  only when it adds no responsibility and no net growth; explain that exception
  in the handoff.
- Do not add net-new production code to a file at or above 1,000 lines. Reduce it
  below the threshold through a responsibility-based extraction first, unless
  the user explicitly approves a documented exception.
- Never allow a file to cross 1,000 lines during implementation and defer the
  split to later. File-size review is a pre-implementation decision, not a
  cleanup task.
- Split by responsibility, state ownership, or reusable behavior. Good seams
  include a child workflow state machine, a pure calculation or command
  builder, a reusable view, a repository/transport concern, or a test
  subsystem.
- Do not split a cohesive type into arbitrary cross-file extensions solely to
  lower line counts. A split should reduce coupling or make ownership clearer;
  it should not expose previously private state, create forwarding boilerplate,
  or make one workflow harder to follow.
- Prefer composition when a view model or coordinator owns multiple independent
  workflows. Extract a focused collaborator with an explicit input/output
  contract and focused tests, while leaving the parent responsible for
  screen-wide or app-wide coordination.
- Keep primary screens focused on composition and navigation. Move substantial
  supporting screens, row families, sheets, diagnostics, and feature-specific
  infrastructure into clearly named sibling files.
- Let test boundaries mirror production responsibilities. Partition unwieldy
  suites by subsystem or workflow, keep shared fixtures in dedicated support,
  and preserve every test during mechanical moves.
- This Xcode project uses file system synchronized groups: any Swift file under
  `Actualist/` or `ActualistTests/` is compiled automatically with no pbxproj
  edit. Run an early simulator build immediately after structural moves, then
  run relevant tests and the full suite. Files that must be excluded from
  target membership (e.g. `Info.plist`, entitlements) are listed in the
  synchronized group's `membershipExceptions`.
- File splitting must preserve or improve access control. Do not expose private
  state, add forwarding boilerplate, or create arbitrary extensions solely to
  manipulate line counts.

## Duplication And Complexity Discipline

- Maintain one authoritative representation of each piece of state. Do not keep
  parallel cached, searched, filtered, and displayed collections with repeated
  fallback expressions; resolve them once into a named display/domain value.
- Extract repeated expressions and byte-identical or near-identical helpers at
  the narrowest shared ownership seam. Before extracting globally, confirm that
  the semantics are genuinely identical.
- Delete identity wrappers, pure forwarders, unused compatibility aliases, dead
  branches, and tests that exist only to preserve retired production behavior.
  Preserve tests that assert live domain behavior by rebuilding their fixtures
  through current construction paths.
- Do not retain speculative compatibility indefinitely. Every schema or wire
  compatibility branch must name an observed source, have a fixture/test, or be
  recorded as an explicit product requirement. Otherwise stop and obtain the
  product decision before adding more branches.
- Prefer a small cohesive value type, enum state machine, or collaborator over
  several variables that must remain synchronized by convention.
- Comments must explain a real invariant, compatibility fact, or non-obvious
  reason. Do not use comments to justify avoidable indirection or duplication.

## UI Principles

- Match the dark, compact, money-forward palette until settings-driven themes are implemented.
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
- Build loading, empty, error, and partial-refresh states for each sync-backed screen.
- First launch must route to Actual server URL/password onboarding and budget selection before the main app shell.
- The main tab bar is Budget, Spending, Accounts, and Reports, rendered with native `TabView`/`.tabItem`. Settings is reached from the Budget screen's gear/overflow menu, not as a tab.
- Closed accounts and hidden categories should be collapsed by default when present.

## Simulator Builds And Visual Verification

Pin simulator and device destinations by UDID from `scripts/lib/destinations.sh`,
not by display name. If an `xcodebuild` run appears stuck for minutes with no
output, the destination simulator is wedged — never the test code. Check
`pgrep -fl xcodebuild` and `xcrun simctl list devices booted`, kill the wedged
process (`pkill -f xcodebuild`), and shut down the stuck device before
re-running against the pinned UDID.

For UI changes, drive the pinned simulator with the bundled demo budget and
capture a screenshot instead of asking the user to tap through onboarding:

```sh
scripts/run-ios-simulator.sh --boot --reset --demo --screen budget --screenshot
```

`--screen` is a slash path. Roots are `budget`, `spending`, `accounts`,
`reports`, `settings`, and `uncategorized`. Settings pages can be nested
(`settings/appearance`) or used as a unique shorthand (`appearance`). `--reset`
uninstalls first so demo starts from onboarding;
without it, `-actualist-demo` will not erase a real selected budget. Screenshots
land in `.artifacts/screenshots/` (gitignored). Read the PNG to confirm the
fix. `--demo` never writes a sync token or contacts a server.

## Sandbox And Escalation Defaults

Do not waste a first attempt inside the filesystem/network sandbox for commands
that are already known to require Xcode, CoreDevice, signing, socket binding,
or public network access. Request/run them outside the sandbox immediately.

## Mandatory Pre-Handoff Verification Gate

Builds and tests are necessary but not sufficient. Before handing off any
production-code change, rerun the architecture gate against the completed diff
and report the result. At minimum:

- Run `scripts/check.sh`. It is the mechanical part of this gate (`git diff
  --check`, Liquid Glass, TestFlight notes, synchronized-group integrity,
  touched-file sizes, largest-file list). Fix every failure before continuing.
- Inspect the entire diff. Compare touched-file size and responsibilities with
  the pre-implementation decision. A passing test suite does not excuse
  unplanned structural growth.
- Search the completed diff and nearby code for duplicate helpers, repeated
  derived-state/fallback expressions, parallel sources of truth, identity
  wrappers, and new Boolean-flag state machines. Resolve them before handoff.
- Audit every changed SwiftUI view against the view-ownership rules above.
  Confirm that each remaining `@State` value is presentation-only and that no
  binding/action computes payload values, money conversions, or business rules.
- Audit every `AppState` change and confirm it is strictly app-wide
  session/settings/routing coordination. Move feature behavior to a focused
  owner before handoff.
- Build with complete concurrency diagnostics enabled, pinning the simulator
  from `scripts/lib/destinations.sh`:

  ```sh
  xcodebuild -project Actualist.xcodeproj -scheme Actualist \
    -destination "platform=iOS Simulator,id=${ACTUALIST_SIMULATOR_ID}" \
    -derivedDataPath .derivedData \
    SWIFT_STRICT_CONCURRENCY=complete build
  ```

  The project is still Swift 5. Complete concurrency is a CLI overlay, not a
  target setting, until remaining warnings are gone (Sendable write callbacks,
  theme global, notification delegate, iOS 26 intent `supportedModes`). Do not
  introduce a new concurrency warning in changed code. Do not enable
  `SWIFT_VERSION = 6` or project-wide `SWIFT_STRICT_CONCURRENCY=complete` until
  that overlay is clean. Do not silence diagnostics with `@unchecked Sendable`
  or `@preconcurrency` without a documented invariant and focused tests.
- Run the relevant focused unit tests, followed by the full test suite for every
  production-code change. Documentation-only and test-only changes are exempt
  from the full suite when no production source or project configuration moved.
- Require zero warnings from the normal project build. Investigate new warnings
  instead of accepting or filtering them out.
- Run `scripts/lint-liquid-glass.sh` after UI/design-system work.
- If any new commit includes a `TestFlight-Note` trailer, run
  `scripts/lint-testflight-notes.sh --range <base>..HEAD` and fix violations
  before handoff.
- Confirm new Swift files were added under `Actualist/` or `ActualistTests/`;
  synchronized groups compile them automatically, but an early simulator build
  after a structural edit is still required.
- Confirm `BudgetMonth`, `Account`, and `Transaction` reads/writes against SQLite
  fixtures or a throwaway synced budget when those paths change.
- Verify money formatting and conversion against Actual amount units whenever
  money display, parsing, serialization, or calculations change.
- Verify sync token, password, encryption-key, and budget-data redaction behavior
  whenever security, diagnostics, persistence, or networking changes.
- Inspect affected UI in light/dark settings if light mode exists, and in dark
  mode by default. For frontend changes, verify affected screens in an
  iPhone-sized simulator or preview.

The handoff must explicitly report structural compliance, not only test results.
If any mandatory check cannot run, state that verification is incomplete and do
not describe the work as complete.
