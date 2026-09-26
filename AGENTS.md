# AGENTS.md

Guidance for coding agents working on Actualist.

## Project Intent

Actualist is a native iOS 26+ local-first client for Actual Budget. It talks to
the normal Actual server sync API, stores an imported SQLite budget locally,
applies CRDT messages, and renders from the local database. The app no longer
relies on the sibling `actual-http-api` package or its REST/OpenAPI contract.

Preserve the visual direction: dark, compact, rounded, money-forward, Liquid
Glass-aware, and optimized for repeated budget review.

## Current References And Applicability

- Development pipeline: `docs/DEVELOPMENT.md`.
- Mechanical gate: `scripts/check.sh`. Run it before handing off a change, or
  reuse an applicable result when its relevant inputs are unchanged. It covers
  whitespace, Liquid Glass, TestFlight notes, synchronized-group integrity,
  file-size signals, and available `reference/` document links. It does not
  replace tests.
- Architecture guidance: `.agents/skills/actualist-architecture/SKILL.md`.
  Skill-aware clients expose it as `skill://actualist-architecture`.
- Machine-specific simulator/device configuration: gitignored
  `scripts/lib/destinations.sh`, based on
  `scripts/lib/destinations.example.sh`. Pin destinations by UDID, never by
  display name.
- Optional maintainer guidance: `.opencode/AGENTS.local.md`, when available.
  Private planning references and machine-specific procedures belong there.

Apply explicit task scope and verification authorization before default workflow
preferences. A read-only audit or planning request is not implementation
authorization. Do not commit, push, publish, or perform unrelated cleanup unless
the task authorizes it.

The local overlay supplements this file; it should not maintain a competing
test-execution or recovery policy. Missing private references must not block an
ordinary public-clone task. If a request specifically depends on an unavailable
private reference, report that limitation.

Preserve pre-existing working-tree changes. Inspect the actual current files and
diff rather than assuming that HEAD or a previously published snapshot includes
all local work.

Report material contradictions among task instructions, repository guidance,
scripts, and observed behavior. Do not silently choose whichever interpretation
permits more work or easier validation.

## Phased Plans And Worker Delegation

- Use bounded worker delegation when the task and available harness support it
  and the work is genuinely independent. Worker-model and cost preferences
  belong in the local overlay, not in repository-wide requirements.
- The main agent owns the plan, architecture decisions, dependency ordering,
  progress tracker, integration, and user communication.
- Give each worker a precise scope, relevant foreseeable edge cases, constraints,
  expected deliverables, and verification commands with explicit run limits.
- The verification budget is shared across the main agent and all workers.
  Delegating work does not create another budget.
- Parallel implementation does not authorize overlapping Xcode builds, test
  invocations, simulator launches, or other operations sharing the same
  simulator or DerivedData. Coordinate those operations through one owner.
- Require workers to report files changed, checks run, evidence locations,
  failures, blockers, and decisions needed.
- Inspect worker diffs and confirm required evidence before integration or a
  dependent phase. Do not rerun passing checks merely because a worker handed
  off, a phase ended, or a commit is being prepared.
- Implement small or tightly coupled changes directly when delegation would add
  more coordination than it saves.
- Explicit instructions for a single-agent diagnostic take precedence over
  delegation preferences.

## Architecture At A Glance

- `Actualist/App/`: app entry, session lifecycle, background work, and app-wide
  coordination. `AppState` publishes app-wide session, settings, and routing;
  `AppSessionRecovery` owns credential availability, restoration, discovery,
  and stale-session identity without caching credential bytes.
- `Actualist/Features/`: screens, feature view models, focused coordinators,
  presentation models, and feature-local pure logic.
- `Actualist/Repositories/`: dependency-injection protocols and domain/display
  models. Production injects `LocalFirstActualStore`; there are no concrete
  repository structs.
- `Actualist/LocalFirst/`: the observable store, cached local source of truth,
  CRDT write orchestration, sync, imports, and connection lifecycle.
- `Actualist/LocalFirst/Database/`: GRDB/SQLite reads, schema compatibility,
  calculations close to stored data, and atomic local write/outbox transactions.
- `Actualist/LocalFirst/Network/` and `LocalFirst/Sync/`: HTTP/wire transport,
  protocol decoding, sync abstractions, and CRDT message construction.
- `Actualist/Shared/`, `Models/`, `Persistence/`, `Security/`, and
  `DesignSystem/`: cross-feature domain helpers, shared models, app preferences,
  credentials/transport security, and visual primitives respectively.
- `Actualist/Widgets/` owns app-side widget snapshots and shared widget models;
  `ActualistWidget/` owns the extension UI and timelines.
- `ActualistTests/` is a flat unit/integration suite named by production type or
  workflow; `ActualistUITests/` is grouped by visible surface.

Normal flow is View -> feature view model/coordinator -> repository protocol ->
`LocalFirstActualStore`, which orchestrates `BudgetDatabase` and sync/network
clients. Screens never read from network clients.

For unfamiliar or cross-layer work, load the architecture skill before choosing
an implementation seam.

## Local-First Backend

- The app connects to a normal Actual server, not the `actual-http-api` REST
  wrapper.
- Sync traffic uses Actual's `/sync/sync` protocol and local CRDT message storage.
- Reads must come from `LocalFirstActualStore` and `BudgetDatabase`, not from
  HTTP REST endpoints.
- Writes must generate Actual-compatible CRDT messages, apply them to SQLite,
  enqueue them in `actualist_outbox`, then reload local caches and
  opportunistically flush.
- Do not commit sync tokens, passwords, encryption keys, budget IDs, imported
  databases, or personal financial data.

## Development Defaults

- Use Swift and SwiftUI only for app UI.
- Do not introduce UIKit UI code.
- Use a standard Xcode SwiftUI app project unless the user explicitly changes
  direction.
- Target iOS 26+.
- Enforce iOS 26 Liquid Glass for all glass-like controls, buttons, toolbars,
  floating navigation, and panels. Use only public SwiftUI Liquid Glass APIs:
  - `.buttonStyle(.glass)`
  - `.buttonStyle(.glassProminent)`
  - `.buttonStyle(.glass(...))`
  - `.glassEffect(_:in:)`
- Liquid Glass must be system-owned wherever SwiftUI provides native chrome.
  Do not wrap native toolbar buttons, tab bars, navigation bars, sheets, alerts,
  or menus in custom glass containers.
- Do not apply `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`, or
  `.buttonStyle(.glass(...))` to buttons inside a SwiftUI `.toolbar`. Let the
  toolbar render its own Liquid Glass button chrome. Toolbar labels should
  usually be plain `Button` views with SF Symbols and optional font/control-size
  adjustments only.
- The main app navigation must use native `TabView` with `.tabItem`. Do not
  recreate the tab bar with custom `HStack`, `ZStack`, `safeAreaInset`, overlay,
  capsule, or `FloatingTabBar` views.
- Never place a glass-styled button inside a view that already has `.glassEffect`,
  and never place a `.glassEffect` wrapper around a native glass button. This
  creates the visible "button inside button" defect on device.
- Use `.glassEffect(_:in:)` only for standalone non-control panels or custom
  surfaces that are not themselves native SwiftUI chrome. If the element is
  clickable and should look like a button, prefer the appropriate native
  `Button` style rather than wrapping it in another glass shape.
- Do not use `GlassEffectContainer` in this app until it has been explicitly
  re-tested on a physical iOS 26 device. The first physical-device run after
  adding it crashed before app code with a system
  `OS_dispatch_mach_msg _setContext:` selector failure.
- Do not fake Liquid Glass with `.regularMaterial`, `.thinMaterial`,
  `.ultraThinMaterial`, `.thickMaterial`, blur overlays, translucent hand-rolled
  capsules, or custom material-backed toolbar containers.
- Row hit areas may still use `.buttonStyle(.plain)` when they should look like
  list rows instead of controls.

### Liquid Glass Examples

Toolbar buttons must be plain toolbar content. The toolbar supplies the glass.

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

The main app tab bar must be native `TabView`, not a custom floating glass
control.

```swift
TabView(selection: $selectedTab) {
    BudgetView()
        .tabItem {
            Label("Budget", systemImage: "list.bullet.rectangle.portrait.fill")
        }
        .tag(AppTab.budget)
    // Add Spending, Accounts, and Reports with the same native structure.
}
```

Glass panels are allowed only for non-native, non-toolbar surfaces. Do not put
glass-styled buttons inside glass panels.

```swift
GlassPanel {
    HStack {
        Text("Server")
        Spacer()
        Text(status)
    }
}
```

Prominent standalone actions may use native glass button styles when they are
not inside native toolbar/tab chrome and not inside another glass surface.

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

Pre-handoff visual rule: if any control looks like a smaller rounded rectangle
or capsule sitting inside a larger rounded rectangle or capsule, it is wrong.
Remove one layer of glass before handing off.

### State And Data Ownership

- Keep sync transport, SQLite/CRDT models, domain/display models, view models,
  and views separated.
- Keep SwiftUI views layout-focused. Do not put API composition, loading/error
  workflows, budget derivation, input interpretation/math, write orchestration,
  or screen state machines directly in views.
- SwiftUI views may format layout, bind controls, show state already prepared
  for display, and call view-model intent methods. They must not compute final
  money amounts, decide API payload values, mutate model state beyond local
  presentation toggles, or contain business rules hidden in button
  actions/gestures.
- Route all fetched data through `LocalFirstActualStore`
  (`Actualist/LocalFirst/`): it is the single in-memory source of truth over the
  local budget database and owns sync, SQLite reads, local CRDT writes, request
  coalescing, and post-write local reloads. Never let a screen call sync
  transports or REST clients directly or hold its own duplicate copy of
  budget data.
- Reads are local-first: show the store's cached snapshot instantly, then
  refresh/pull CRDT messages in the background when appropriate. Writes must
  apply locally, enqueue outbox messages, reload affected local caches before
  the flow returns, and then opportunistically flush. Clear the cache
  (`reset()`) on budget switch / connection change.
- The repository protocols (`BudgetRepositoryProtocol`,
  `TransactionRepositoryProtocol`) are the dependency-injection seam the store
  conforms to; inject the store in production and fakes in tests. There are no
  concrete repository structs.
- Put feature screen state, loading/error handling, expansion/selection state,
  submission state machines, and derived display logic in feature view models.
- Put reusable pure calculations or draft input interpretation in explicit
  value types/helpers owned by the feature or domain layer, then unit test
  them. Views should consume the resulting display state; repositories should
  receive the already-decided command values.
- `AppState` should coordinate app-wide session/settings/routing only. Do not
  grow it into a catch-all feature view model.
- Keep design values in a small theme/design-system layer instead of scattering
  colors and dimensions through views.
- Treat write actions as explicit flows with confirmation or clear review
  states; this app controls real budget data.
- Decode Actual sync metadata and local SQLite values defensively. Actual budget
  files may have schema differences across versions and migrated data.
- Store sync tokens and encryption keys in Keychain and never log them.
- Do not commit real server hostnames, sync tokens, passwords, encryption keys,
  budget IDs, imported databases, or personal financial data.
- Keep dependencies minimal. Prefer Apple frameworks before adding packages.

## Commit And TestFlight Notes

Trailers are the What to Test changelog. They are not QA scripts. The release
helper keeps the newest note per `[topic]` and drops earlier ones.

Decide, in this order:

1. Internal change with no tester-visible behavior change, such as documentation,
   tests, refactoring, TestFlight preparation, or cosmetic-only polish?
   Omit the trailer. Never write a placeholder such as
   `No tester-visible change`.
2. Same product surface as an earlier unreleased commit?
   Rewrite that topic's full note. Do not add a second topic or a delta line.
3. New tester-visible surface?
   Add exactly one `TestFlight-Note: [topic] ...` using a topic from
   `config/testflight/topics.txt`. Add a topic there only when this commit
   introduces a new surface.

A commit has zero or one trailer. Two trailers are allowed only if it ships two
unrelated surfaces. Never use one trailer per incremental slice of the same
feature.

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
  `scripts/lint-testflight-notes.sh --message-file <file>`.
  Trim the summary instead of appending clauses to an existing topic note.
- Start with `Added`, `Fixed`, `Improved`, `Moved`, `Renamed`, `Removed`, or
  `Combined`.
- Describe what changed and where to find it. Do not tell the tester what to
  tap, say, search, try, confirm, or verify.
- Write in the tester's voice, not the developer's. A tester who has never read
  Actual's internals or this repo must understand every sentence. Say what they
  will see or be able to do, and on which screen — never the mechanism that
  produces it.
- Name outcomes, not implementation behaviors. Do not enumerate internal rules,
  guards, or clamp/refuse/fail-close branches; pick the one or two results a
  tester can observe. The full mechanism belongs in the commit body, not the
  trailer.
- No version-parity references (`matches Actual 26.8.1`), math symbols
  (`±7-day`), or engine/schema terms (CRDT, split family, rule projection,
  minor units, available vs To Budget sign conventions). If the tester does
  not type it or tap it, do not name it. Feature names the app itself shows
  (Apply Templates, Bank Sync, Split, Starting Balance) are allowed.
- Keep sentences short and concrete: one user-visible change per sentence,
  common words, no stacked clauses joined by commas and semicolons.
- No implementation jargon, credentials, hostnames, budget IDs, personal data,
  or real financial amounts.
- Omit cosmetic/layout-only and developer-only notes. Material changes to
  navigation, interaction, or accessibility are tester-visible behavior, not
  merely cosmetic polish.

Developer-voice notes are wrong even when every hard rule passes. Describe the
outcome a tester sees, not the machinery.

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

After writing trailers, run
`scripts/lint-testflight-notes.sh --range <base>..HEAD` against the commits that
added them. Do not generate or prepare the next build's release artifacts merely
to validate a commit or OTA build; that belongs only to an explicitly requested
TestFlight release workflow.

## Mandatory Pre-Implementation Architecture Gate

Passing tests does not establish that a change complies with this file. Before
editing production code, complete this gate and let it determine the
implementation shape:

- Read the complete destination file and the directly related view model,
  repository/store, domain helper, and tests relevant to its ownership. Do not
  patch from a narrow snippet when ownership may sit elsewhere.
- Measure every prospective Swift destination with `wc -l` and inspect its
  current responsibilities. Also inspect `git diff --numstat` during the work so
  incremental growth remains visible.
- Search with `rg` for existing types, helpers, formatters, calculations,
  derived-state projections, and state machines before adding another one. A
  locally convenient duplicate is not an acceptable implementation.
- State the ownership decision before implementation: view-local presentation,
  feature view model, pure domain/value helper, repository/store, database,
  sync transport, or app-wide coordination. Put the behavior at that seam from
  the start; do not add it to the nearest file and promise a later cleanup.
- For every new or changed SwiftUI `@State` property, task, binding setter,
  button action, or gesture, decide whether it is presentation-only. Loading,
  errors, pagination, debounce/search, submission, deletion, write orchestration,
  payload construction, input interpretation, money math, and derived display
  state belong outside the view.
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
- For plan-governed work, enumerate each phase's foreseeable important edge
  cases before implementation: races and cancellation identities, error and
  recovery paths, compatibility branches with named sources, and the
  per-phase verification budget.
- Discovering another case within the approved behavior is normal implementation
  work. A new case that materially expands product behavior, data contracts,
  architecture, or verification cost requires a plan amendment and scope
  approval before implementing the expansion.

Architecture and file-size gates can identify a blocker; they do not independently
authorize expanding the task. Include narrowly necessary structural extraction
when it fits the approved scope. If satisfying a gate requires a materially
broader refactor, explain the smallest compliant approach and obtain approval
rather than silently beginning that refactor.

When review surfaces relevant work that should be deferred, report it and ask
before recording a backlog item or implementing it. Do not silently drop a real
finding, but do not turn every nearby issue into mandatory cleanup for the
current task.

## File Size And Structural Maintainability

- Treat file size as an architectural signal, not a quota. Reassess a Swift file
  before adding code when it is near or above 800 lines. Record an explicit
  keep-or-split decision before implementation.
- Do not add a substantive responsibility to a file that is already at or above
  800 lines. Extract a cohesive seam first within the approved scope. A truly
  local bug fix may proceed only when it adds no responsibility and no net
  growth; explain that exception in the handoff.
- Do not add net-new production code to a file at or above 1,000 lines. Reduce it
  below the threshold through a responsibility-based extraction first, unless
  the user explicitly approves a documented exception.
- Never allow a file to cross 1,000 lines during implementation and defer the
  split to later. File-size review is a pre-implementation decision, not a
  cleanup task.
- If these thresholds require a broader extraction than the task authorizes,
  report the blocker and proposed scope. Do not use the threshold as permission
  for an unrequested rewrite.
- Split by responsibility, state ownership, or reusable behavior. Good seams
  include a child workflow state machine, a pure calculation or command builder,
  a reusable view, a repository/transport concern, or a test subsystem.
- Do not split a cohesive type into arbitrary cross-file extensions solely to
  lower line counts. Preserve or improve access control. A split should reduce
  coupling or make ownership clearer; it should not expose previously private
  state, create forwarding boilerplate, or make one workflow harder to follow.
- Prefer composition when a view model or coordinator owns multiple independent
  workflows. Extract a focused collaborator with an explicit input/output
  contract and focused tests, while leaving the parent responsible for
  screen-wide or app-wide coordination.
- Keep primary screens focused on composition and navigation. Move substantial
  supporting screens, row families, sheets, diagnostics, and feature-specific
  infrastructure into clearly named sibling files.
- Let test boundaries mirror production responsibilities. Keep shared fixtures
  in dedicated support and preserve every test during mechanical moves.
  `LocalFirstActualStoreTests` is also a shared fixture namespace; account for
  its extensions and external fixture consumers before moving files.
- This Xcode project uses file system synchronized groups: Swift files under
  `Actualist/` or `ActualistTests/` normally compile automatically without a
  pbxproj edit. Files excluded from target membership, such as `Info.plist`
  and entitlements, are listed in the synchronized group's
  `membershipExceptions`.
- Confirm compilation early after structural moves. An immediately scheduled
  test invocation that builds every affected target satisfies that compile
  check; do not add an identical standalone build. For other targets, inspect
  their actual synchronized groups and membership rather than assuming the
  app/unit-target layout applies.

## Duplication And Complexity Discipline

- Maintain one authoritative representation of each piece of state. Do not keep
  parallel cached, searched, filtered, and displayed collections with repeated
  fallback expressions; resolve them once into a named display/domain value.
- Extract repeated expressions and byte-identical or near-identical helpers at
  the narrowest shared ownership seam. Before extracting globally, confirm that
  the semantics are genuinely identical.
- Within the approved scope, delete identity wrappers, pure forwarders, unused
  compatibility aliases, dead branches, and tests that exist only to preserve
  retired production behavior. Preserve tests that assert live domain behavior
  by rebuilding their fixtures through current construction paths. Never
  remove a valid regression merely to make verification pass.
- Do not retain speculative compatibility indefinitely. Every schema or wire
  compatibility branch must name an observed source, have a fixture/test, or be
  recorded as an explicit product requirement. Otherwise stop and obtain the
  product decision before adding more branches.
- Prefer a small cohesive value type, enum state machine, or collaborator over
  several variables that must remain synchronized by convention.
- Comments must explain a real invariant, compatibility fact, or non-obvious
  reason. Do not use comments to justify avoidable indirection or duplication.
  Do not present an unconfirmed diagnosis as an established invariant.

## UI Principles

- Match the dark, compact, money-forward palette until settings-driven themes
  are implemented.
- Use real Liquid Glass APIs for prominent actions and reusable panels. For
  native navigation chrome, use native SwiftUI structures (`TabView`, `.toolbar`,
  navigation stacks) and let the system draw the Liquid Glass.
- Any visual result that looks like a smaller rounded button inside a larger
  rounded button is wrong and must be fixed before handoff.
- Use native symbols/icons where possible.
- Keep rows dense and scannable.
- Make money states visually distinct:
  - Green for available/positive.
  - Yellow for caution/special availability.
  - Red for overspent/error.
  - Gray for zero/inactive.
- Support Dynamic Type without breaking row layout.
- Build loading, empty, error, and partial-refresh states for each sync-backed
  screen.
- First launch must route to Actual server URL/password onboarding and budget
  selection before the main app shell.
- The main tab bar is Budget, Spending, Accounts, and Reports, rendered with
  native `TabView`/`.tabItem`. Settings is reached from the Budget screen's
  gear/overflow menu, not as a tab.
- Closed accounts and hidden categories should be collapsed by default when
  present.

## Simulator Builds And Visual Verification

Pin simulator and device destinations by UDID from the local destination
configuration, not by display name. Use the current configuration and actual
device list; do not assume a historically healthy destination remains healthy.

Do not start a build, test, launch, or screenshot workflow against shared
simulator/DerivedData resources while another invocation is using them.
`scripts/test.sh` coordinates its own callers; other tools do not automatically
participate in its lock.

A slow or stalled run is a symptom, not a simulator diagnosis. Use the failure
and recovery policy in Testing Scope And Reuse. Never assume that a small test
selection cannot hang because of test code, blocking dependencies, or
coordination defects.

For UI changes, drive an appropriate pinned simulator with the bundled demo
budget and inspect a screenshot rather than asking the user to tap through
onboarding:

```sh
scripts/run-ios-simulator.sh --boot --demo --screen budget --screenshot
```

`--screen` is a slash path. Roots are `budget`, `spending`, `accounts`, `reports`,
`settings`, and `uncategorized`. Settings pages can be nested
(`settings/appearance`) or used as a unique shorthand (`appearance`).

`--reset` uninstalls first. Use it only for a confirmed disposable demo/test
installation, not to erase an existing real selected budget. Without reset,
`-actualist-demo` does not erase a real selected budget.

Screenshots land in `.artifacts/screenshots/` (gitignored). Read the PNG to
confirm the result. `--demo` never writes a sync token or contacts a server.

Perform the required affected-screen/device/theme verification at closeout,
not after every intermediate edit. Documentation, test-runner, or test-fixture
changes do not require screenshots or a UI matrix.

## Sandbox And Escalation Defaults

Use the execution environment's supported permission/escalation mechanism.

When a specific command is already known to require permissions unavailable in
the current sandbox, request the required execution mode directly rather than
repeating a known-denied attempt. Do not generalize that limitation to every
Xcode, socket, or public-network command.

A sandbox DNS, filesystem, signing, or network restriction does not establish
that a simulator, device, server, or public route is broken. Preserve the actual
error and distinguish local execution restrictions from remote failures.

Never bypass required authorization or assume that a different execution
mechanism is necessary before examining the actual failure.

## Testing Scope And Reuse

### Supported Commands And Execution Policy

`scripts/test.sh` is the executable source of truth for test selection and
execution policy. Inspect its help or dry-run output when needed; do not launch
a test merely to discover what command it would run.

Supported entry points:

- `scripts/test.sh unit <Suite>...`: focused unit suites.
- `scripts/test.sh unit`: the complete populated unit target.
- `scripts/test.sh ui <Suite[/testMethod]>...`: selected UI suites or methods.
- `scripts/test.sh all`: the complete unit and UI selection.
- `scripts/test.sh --dry-run unit`: print the unit command without launching
  Xcode or touching the invocation lock.

When `ACTUALIST_TEST_PARALLEL` is unset:
- `unit` enables parallel testing.
- `ui` and `all` remain serial.

Explicit `ACTUALIST_TEST_PARALLEL=1` enables parallel testing for the selected
mode. Explicit `ACTUALIST_TEST_PARALLEL=0` disables it. Other values, including an
explicitly empty value, are invalid.

Use the normal defaults unless the user or an approved diagnostic plan
explicitly specifies another mode. Serial execution is a diagnostic escape
hatch, not the default workaround for a failure.

Do not propagate a one-off serial override into later worker prompts or change
the script's defaults because one run failed.

Invoke real tests through the existing wrapper. Do not bypass it with raw
`xcodebuild test`, `test-without-building`, PATH shims, custom flag combinations,
or a new runner unless an explicitly authorized experiment requires that work
and preserves invocation ownership.

A harmless `xcodebuild` stub is appropriate for explicitly scoped wrapper
behavior checks in a disposable harness. Never use it for real app validation.

Unfiltered `xcodebuild test` on the shared scheme includes UI tests. Never call
that a unit-only run.

### Accepted Fixture And Suite Scheduling Boundaries

- Preserve the fresh `FakeKeychainBackend()` defaults in
  `makeOpenedWritableStoreBundle` and `makeBankSyncStore`.
- These synthetic store/workflow fixtures normally do not need real
  system-Keychain access. The real `KeychainStore`, store behavior, database
  operations, and assertions remain under test.
- Preserve explicit backend arguments and forwarding. Tests that genuinely
  require operating-system Keychain behavior must opt into that dependency
  deliberately. Do not change production defaults to accommodate tests.
- Give independent fixtures independent fake instances. Do not replace them
  with a static/global/shared fake. When a test intentionally shares credential
  state, make that sharing explicit within the test.
- `FakeKeychainBackend` is mutable and `@unchecked Sendable`; it is not generally
  thread-safe. The audited affected fixture paths confine its synchronous
  accesses to MainActor. Preserve that invariant, or review a newly introduced
  cross-executor consumer before using the fake there. A fresh instance per
  test does not prove safe concurrent access within that test.
- Preserve `@Suite(.serialized)` on `LocalFirstActualStoreTests`. It is the
  accepted internal scheduling choice for this large suite; unrelated suites
  remain eligible for parallel execution.
- Another suite that merely instantiates `LocalFirstActualStoreTests()` to use
  helpers does not inherit that suite's serialization.
- Suite serialization does not disable asynchronous/concurrent operations
  deliberately created inside an individual test.
- Do not remove legitimate production or test actor isolation, weaken
  assertions, increase time limits, or add serialization broadly to obtain a
  green run.
- Do not split targets or broadly reorganize fixtures as routine flake recovery.
  A future split needs an approved purpose, dependency analysis, and complete
  before/after test inventories. File prefixes alone are not dependency
  boundaries.
- If unit targets or suite identities change, update wrapper selection and
  focused-test routing together. Verify that tests have not disappeared or been
  duplicated.

### Test Coordination

- Wait for meaningful events or task completion, not an assumed number of
  scheduler turns.
- Do not add `while ... { await Task.yield() }` polling or bounded "give the
  scheduler time" yield loops. A single `Task.yield()` is also not proof that
  another task has processed a released response.
- Prefer existing fakes' `waitFor...()` methods, completion acknowledgments, or
  awaiting the actual task when those express the behavior being tested.
  Use `TestLatch` or `ObservedTestState` only where their contracts fit.
- New or changed waits need an explicit failure/cancellation strategy. Do not
  assume a test-level `.timeLimit` will forcibly release a continuation or stop
  a cancellation-insensitive operation.
- Distinguish the test waiting for an event from a fake operation intentionally
  ignoring cancellation to exercise a late result. Do not remove the late-result
  scenario while "fixing" its synchronization.
- For stale-result tests, establish that the obsolete operation has completed
  or reached the relevant rejection point before asserting that state remained
  unchanged.
- Keep coordination hardening scoped. Existing helper limitations do not
  authorize converting every wait during an unrelated task.

### Verification Budget

Test execution is expensive. Choose the necessary scope before running it, use
recent comparable evidence for duration estimates, and do not launch a full
suite merely to estimate how long it takes.

Default implementation budget:

- At most three full-suite invocations per implementation session, shared by
  the main agent and all workers.
- At most one planned full-suite invocation per phase, after the final relevant
  edit and only when the validation matrix requires it.
- A complete `unit` or `all` invocation consumes the full-suite budget.
  Near-complete selections or artificial batches used to recreate most of the
  suite are full-equivalent work; do not evade the cap with selectors.
- While iterating, use focused suites for changed behavior and relevant callers.
  Do not run broad/full verification to "see where things stand," after each
  worker handoff, or merely to confirm a commit.
- Finish the relevant review before the phase's full run. New edits do not reset
  the budget or automatically authorize another full run.
- Run affected UI/device/theme verification once at closeout of a UI change,
  not after every iteration.
- If required verification exceeds the agreed budget, report the need and obtain
  authorization rather than continuing silently.

An explicitly authorized diagnostic or reliability plan may define its own
bounded budget, including repetitions on unchanged code. State the configuration,
question, measurements, acceptance criteria, stop conditions, and maximum runs
before execution.

Predetermined confirmation runs are not retry-until-green. Stop on the plan's
first failed condition; do not silently change the candidate, thresholds, or
selection and restart acceptance.

A retry following an infrastructure failure is not automatic. Identify and
resolve the concrete failure, confirm quiescence, and ensure the rerun fits an
explicitly agreed budget. An assertion failure or test time-limit failure is
not, by itself, an infrastructure diagnosis.

The main agent must put allowed verification commands and counts in worker
prompts. Workers report requests for broader verification instead of spending
additional runs independently.

### Validation Matrix

Choose validation from changed behavior and its callers. Do not treat commit,
push, phase completion, or handoff as a reason to repeat successful validation.

| Change | Required validation beyond applicable static checks and diff review |
| --- | --- |
| Already validated work being committed or pushed | Reuse applicable results for the same tested source, tests, configuration, and relevant toolchain. |
| Documentation or comments only | No app build or tests. Run applicable documentation/static checks. |
| Test-only changes | Changed test suites; full coverage checks when scheduling, discovery, or shared fixture scope requires them. |
| Scripts or developer tooling | Syntax checks and focused behavior checks for the changed tooling. Do not invoke the app suite merely to test shell process/lock behavior. |
| Contained production logic | Affected unit suites, including relevant caller/regression coverage. |
| UI layout or interaction | Compile, inspect affected screens, and run relevant UI regressions for changed interactions; include unit tests when view-model/domain behavior changes. No unrelated UI suites. |
| Shared database, sync, money logic, broad refactors, or runtime-relevant project/target configuration | Full unit suite and relevant integration coverage; affected UI tests only when UI behavior is at risk. |
| TestFlight release | Full unit and UI coverage, reusing applicable evidence when the release records the already validated state. |

Full UI coverage is required for releases and broad UI/navigation changes.
Routine backend changes do not require it. Verify affected iPad layouts when
changing adaptive UI; do not repeat a whole device/theme matrix for a localized
change.

A successful normal test build satisfies compilation for the targets it built.
Do not add a separate identical build. Build other affected targets if the
selected test run did not compile them.

The normal Swift 6 build performs the project's compiler-enforced concurrency
checks. Do not add a redundant strict-concurrency overlay build. A passing build
does not establish cancellation behavior, forward progress, freedom from
blocking, or the safety of unchecked annotations; verify the affected runtime
behavior when relevant.

Focused runs need not precede an already sufficient full run. Do not run both
parallel and serial full suites unless a bounded scheduling/reliability
investigation explicitly calls for them.

### Evidence And Reuse

Record enough evidence to establish:
- The command, scope, destination/runtime, and execution mode.
- The relevant source/configuration state, including applicable uncommitted
  changes and overrides rather than only the HEAD commit.
- The numeric exit status, result-bundle outcome, and artifact paths.
- Tests executed, passed, failed, skipped, or left unfinished.
- Relevant toolchain information and any unexpected test-host termination.

For long diagnostic/acceptance runs, prefer non-PTY supervision with output
redirected to a regular log and a separately captured exit status. Do not depend
on a PTY or log stream reaching EOF to decide that the invocation finished.
Use the approved external execution ceiling and confirm ownership before
stopping processes.

Do not treat a green summary as sufficient when the expected tests did not run.
When changing scheduling, fixtures broadly, target membership, or discovery,
compare test identities and parameterized coverage with a complete reference
selection. Do not confuse test functions, parameterized argument nodes,
invocations, or assertion counts.

Historical counts and timings are evidence for their recorded source state, not
permanent required totals. A smaller result after a host failure is not a new
coverage baseline.

Performance gates in a diagnostic plan are distinct from test assertions and
framework time limits. A functionally passing run can miss an experiment's
performance gate; describe both outcomes accurately.

Reuse results when their relevant inputs remain applicable. A commit that only
records the validated working-tree state does not invalidate them.
Documentation/comment-only edits do not, by themselves, require runtime
revalidation.

Relevant code, test, configuration, or toolchain changes require fresh affected
checks. Failures, incomplete execution, or missing evidence cannot be treated
as a pass for the affected scope. Do not add a validation-cache framework.

Report what ran or was reused and any outstanding required check. A deliberately
focused run is complete validation when this policy calls for focused scope;
do not label it incomplete because unrelated suites were omitted.

### Stalls, Failures, And Lock Recovery

A slow or stalled run is a symptom, not a diagnosis. Inspect the actual phase,
logs, process state, and available results before attributing it to compilation,
test code, synchronization, external services, or simulator infrastructure.

- Do not assume a small selection cannot hang because of test code.
- Do not assume that all main-actor tests are defective or that total test count
  determines a universal safe concurrency threshold.
- Do not infer the installed runner's behavior solely from current upstream
  source, a scheme attribute, summed test durations, or a different toolchain.
- For a further diagnostic run, define the evidence needed in advance. If stack
  capture is the purpose, verify a usable capture path and do not spend the
  entire run after capture has failed.
- Separate observation from interpretation. Stack-sample frequency is not CPU
  utilization, and a continuation being resumed is not proof its consumer has
  completed.
- Treat unexplained failures as findings to resolve within scope or report.
  Do not delete/quarantine tests, weaken assertions, increase limits, or switch
  execution mode simply to obtain a pass.

The wrapper's lock is `.artifacts/.test-run.lock`.

- It coordinates cooperating `scripts/test.sh` invocations in this checkout.
  It does not cover raw Xcode commands, other checkouts, or every simulator
  process.
- A successful, uninterrupted invocation releases its own lock after its child
  succeeds and ownership is confirmed.
- Failure or interruption deliberately retains the lock.
- Existing locks are not automatically reclaimed, including locks with missing,
  malformed, or dead-owner metadata.
- Help, invalid arguments, invalid parallel values, and dry-run do not acquire
  or modify the lock.
- A retained lock is not proof that work is still running; a dead recorded PID
  is not proof that all associated work has ended.

Recovery is explicit. Inspect the lock metadata, invocation evidence, and
associated processes, including actual test hosts and simulator clones.
Confirm that the prior invocation and its relevant test activity have ended
before removing only that verified stale lock. If ownership or quiescence is
uncertain, stop and report rather than guessing.

Stop only processes positively associated with the affected invocation.
Never use blanket `pkill -f xcodebuild`, `killall`, or broad process-group
termination as routine recovery.

The wrapper attempts to terminate its recorded direct child on interruption;
it does not guarantee that every simulator descendant has stopped. SIGKILL
cannot run cleanup handlers. Confirm actual state before recovery.

XCTest may execute on a clone with a different UDID from the pinned destination.
Identify the actual affected host rather than assuming the base simulator is
where the test process lives.

Shut down a specific simulator only after confirming its involvement and that
unrelated work will not be interrupted. Simulator deletion, erasure, or clearing
DerivedData/Keychain is not routine recovery and requires a concrete reason and
appropriate authorization.

## Mandatory Pre-Handoff Verification Gate

Builds and tests are necessary but not sufficient. Before handing off a
production-code change, review the completed diff against the architecture gate.

- Run `scripts/check.sh` after the final relevant edits, or reuse an applicable
  result. Its appearance in multiple sections is not a requirement to run it
  multiple times.
- Fix failures introduced by the change. Report pre-existing or external
  blockers without silently expanding scope to resolve unrelated work.
- Inspect the entire diff. Compare touched-file size and responsibilities with
  the pre-implementation decision. A passing suite does not excuse unplanned
  structural growth.
- Search changed and directly related code for duplicate helpers, repeated
  derived-state/fallback expressions, parallel sources of truth, identity
  wrappers, and new Boolean-flag state machines. Resolve issues within the
  approved scope; report broader findings.
- Audit every changed SwiftUI view against the ownership rules. Confirm that
  remaining `@State` values are presentation-only and that no binding/action
  computes payload values, money conversions, or business rules.
- Audit every `AppState` change and confirm that it is app-wide
  session/settings/routing coordination.
- Do not introduce new concurrency warnings in changed code. Do not silence
  diagnostics with `@unchecked Sendable` or `@preconcurrency` without a
  documented invariant and appropriate focused verification.
- Run or reuse the checks required by Testing Scope And Reuse.
- Introduce no new warnings in changed code. Record pre-existing or external
  warnings separately; do not filter them out or expand scope to eliminate them
  without authorization.
- `scripts/check.sh` includes Liquid Glass lint; do not rerun it separately
  unless relevant inputs changed or a focused diagnostic requires it.
- If a new commit includes a `TestFlight-Note` trailer, run the required trailer
  lint for its commit range and fix violations before handoff.
- Confirm new Swift files belong to the intended synchronized groups/targets
  and that structural edits received the appropriate compile check.
- Confirm changed `BudgetMonth`, `Account`, and `Transaction` reads/writes
  against SQLite fixtures or a throwaway synced budget.
- Verify money formatting/conversion against Actual amount units whenever money
  display, parsing, serialization, or calculations change.
- Verify relevant sync-token, password, encryption-key, and budget-data
  redaction behavior when security, diagnostics, persistence, or networking
  changes.
- For frontend changes, inspect affected screens in an iPhone-sized simulator
  or preview, including affected light/dark settings and adaptive layouts.

The handoff must report structural compliance, verification scope/evidence,
known limitations, and any outstanding required check.

Implementation, verification, commit, push, and release are distinct states.
Work may be implemented and verified while intentionally uncommitted. Do not
create a commit or run additional tests merely to make a tracker look complete.

When required verification could not run, state exactly what remains pending;
do not claim that the affected behavior is verified.