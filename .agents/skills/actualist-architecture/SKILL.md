---
name: actualist-architecture
description: Use when locating code, planning a change, tracing a feature across layers, deciding where new Actualist behavior belongs, or reviewing architectural ownership. Trigger for requests involving unfamiliar features, cross-layer work, data flow, repository structure, app navigation, local-first storage, sync, widgets, tests, or "where is" questions. This is a navigation map, not authorization to skip reading the complete destination files required by AGENTS.md.
---

# Actualist Architecture

Use this map to choose the first files to read. Do not begin with a repository-wide search. Once the likely owner is identified, read the complete destination file and its directly related view model, repository/store, domain helper, and tests as required by `AGENTS.md`.

## System shape

Actualist is a native SwiftUI, local-first Actual Budget client. The normal dependency direction is:

```text
SwiftUI view
  -> feature view model / coordinator / pure feature model
  -> repository protocol
  -> LocalFirstActualStore (in-memory source of truth and orchestration)
       -> BudgetDatabase (SQLite reads and atomic local writes)
       -> Actual sync/network clients (pull and opportunistic outbox flush)
```

App-wide session, settings, and routing coordination belongs in `AppState`; feature workflow state does not. Reads render from the local store/database. Writes produce Actual-compatible CRDT messages, apply them to SQLite, enqueue them in `actualist_outbox`, reload affected store caches, and then opportunistically flush.

## Target and directory map

| Path | Ownership |
| --- | --- |
| `Actualist/App/` | App entry point, session lifecycle, background work, launch coordination, app-wide sync status, notifications, and tab identity. |
| `Actualist/Features/` | User-facing screens, feature view models, focused coordinators, presentation models, and feature-local pure logic. |
| `Actualist/Repositories/` | Dependency-injection protocols and domain/display models consumed by features. These are protocols, not concrete repository implementations. |
| `Actualist/LocalFirst/` | `LocalFirstActualStore`, local-first orchestration, cached snapshots, CRDT mutation construction, sync, import, and feature-facing repository conformance. |
| `Actualist/LocalFirst/Database/` | `BudgetDatabase` actor, GRDB/SQLite reads, schema compatibility, calculations close to stored data, and atomic write/outbox transactions. |
| `Actualist/LocalFirst/Network/` | Concrete Actual sync, SimpleFIN, and bridge HTTP clients. |
| `Actualist/LocalFirst/Sync/` | Sync transport abstraction and CRDT message builder. |
| `Actualist/LocalFirst/ActionLog/` | Undoable budget action models and inverse construction. |
| `Actualist/Shared/` | Cross-feature value types and pure helpers such as money, bank-sync reconciliation, wallet mapping, rule projection, and notes. |
| `Actualist/Models/` | App-wide domain models shared by multiple ownership areas. |
| `Actualist/Persistence/` | App preferences and settings persistence, not imported budget data. |
| `Actualist/Security/` | Keychain, OpenID authentication, custom HTTP headers, and transport-security checks. |
| `Actualist/DesignSystem/` | Theme, palette, glass surfaces, and small presentation utilities. |
| `Actualist/Widgets/` | App-side widget snapshot construction/storage, deep links, shared widget models, and publication coordination. |
| `ActualistWidget/` | Widget extension entry points, timeline providers, configuration intents, and widget views. |
| `ActualistTests/` | Unit/integration tests and synthetic SQLite/Actual-core fixtures. Tests are flat and named after the production type or workflow. |
| `ActualistUITests/` | End-to-end UI regressions grouped by visible surface. |
| `scripts/` | Mechanical checks, simulator runner, focused test runner, parity tools, demo generation, and release tooling. |
| `docs/` | Public development documentation and public plans. Local active planning and evidence may also exist under gitignored `reference/`. |

The app, unit-test, UI-test, and widget directories are Xcode file-system synchronized groups. New Swift files under existing synchronized roots compile automatically, except explicitly excluded resources. The widget target also compiles a curated set of shared files from `Actualist/Widgets/` and `Actualist/DesignSystem/`; inspect `Actualist.xcodeproj/project.pbxproj` when changing that cross-target boundary.

## App shell and lifecycle

Start here for launch, session, routing, background refresh, or app-wide state:

- `Actualist/App/ActualistApp.swift` — app entry, dependency construction, scene setup, and environment injection.
- `Actualist/App/AppState.swift` — app-wide session/setup state and lifecycle coordination only.
- `Actualist/App/AppStateModels.swift` — small app-state enums/value types.
- `Actualist/App/AppSyncCoordinator.swift` — foreground sync coordination and status publication.
- `Actualist/App/BackgroundTransactionWorkflow.swift` and `BackgroundTransactionRefreshRunner.swift` — background transaction/bank work.
- `Actualist/App/LaunchWarmup.swift` and `LaunchInstrumentation.swift` — post-open warmup and launch measurements.
- `Actualist/Features/Root/RootView.swift` — setup-to-main-shell boundary.
- `Actualist/Features/Root/MainTabView.swift` — compact native tab shell.
- `Actualist/Features/Root/AdaptiveRootShell.swift` — adaptive/iPad shell.
- `Actualist/Features/Root/AdaptiveBudgetSession.swift` — retained Budget presentation session across shell changes.
- `Actualist/Features/Shortcuts/Routing/AppRouteCoordinator.swift` and `AppRoute.swift` — app routes and external/deep-link navigation.

Do not add a feature workflow to `AppState`. Put it in the feature view model or a focused coordinator and let `AppState` coordinate only its app-wide boundary.

## Feature routing table

### Budget

- Screen composition: `Actualist/Features/Budget/BudgetView.swift`, `BudgetWorkspaceView.swift`, `BudgetCompactMonthContent.swift`, and `BudgetRows.swift`.
- State and derived display logic: `BudgetViewModel.swift`, `BudgetViewportModel.swift`, and nearby `*Presentation.swift`, `*Policy.swift`, and draft-model files.
- Month navigation and layout: `BudgetMonthSwipeModifier.swift`, `BudgetAssignmentViewport.swift`, `BudgetAssignmentScrollPresentation.swift`, and viewport/layout helpers.
- Assignment/move workflows: Budget feature view-model extensions and draft helpers; persistence enters through `BudgetRepositoryProtocol` and store mutation extensions.
- Uncategorized flow: `UncategorizedTransactionsView.swift` and its view model/coordinator siblings.
- Backend reads/writes: `LocalFirstActualStore+Reads.swift`, `+AssignMove.swift`, `+Mutations.swift`, `+ActionLog.swift`; `BudgetDatabase+BudgetReads.swift`, `+BudgetWrites.swift`, and `+ActionLog*.swift`.

### Transactions and spending

- Account feed and summaries: `Actualist/Features/Transactions/AccountTransactionsView.swift`, `AccountTransactionsViewModel.swift`, `AccountTransactionFeedProjection.swift`, and presentation siblings.
- Editor UI/state: `TransactionEditorView.swift`, `TransactionEditorViewModel.swift`, `TransactionEditorSession.swift`.
- Submission and guarded mutation: `TransactionEditorSubmissionCoordinator.swift`, `TransactionEditorMutationCoordinator.swift`, and reconciled-mutation presentation files.
- Protocol/model seam: `Actualist/Repositories/TransactionRepository.swift` and `TransactionModels.swift`.
- Store writes: `LocalFirstActualStore+TransactionMutations.swift` and related mutation extensions.
- Database reads/writes: `BudgetDatabase+TransactionReads.swift`, `+TransactionCreation.swift`, `+TransactionUpdates.swift`, `+TransactionCategorization.swift`, and `+TransactionSplit*.swift`.
- Split-family invariants: `Actualist/LocalFirst/SplitTransactionFamily.swift`.

### Accounts and reconciliation

- Account list: `Actualist/Features/Accounts/AccountsView.swift`, `AccountsViewModel.swift`, and `AccountListLayout.swift`.
- Add/group editing: `AddAccountViewModel.swift`, `AccountGroupEditorSheet.swift`, store account-group extension, and database account-group files.
- Reconciliation workflow: `AccountReconciliationCoordinator.swift`, `AccountReconciliationModels.swift`, `AccountReconciliationPresentation.swift`, and `AccountReconciliationViews.swift`.
- Backend: `LocalFirstActualStore+Reconciliation.swift`; `BudgetDatabase+Reconciliation.swift` and `+ReconciledMutationGuard.swift`.
- Protocol seam: `Actualist/Repositories/AccountRepository.swift`.

### Bank Sync and Wallet import

- Screen/review state: `Actualist/Features/BankSync/BankSyncView.swift`, `BankSyncViewModel.swift`, and review/account sheets.
- Planning: `Actualist/LocalFirst/LocalFirstActualStore+BankSyncPlanning.swift`.
- Apply/orchestration: `LocalFirstActualStore+BankSync.swift`.
- Provider clients: `Actualist/LocalFirst/Network/ActualServerSimpleFINClient.swift` and `SimpleFINBridgeClient.swift`.
- Pure reconciliation/mapping: `Actualist/Shared/BankSyncReconciler.swift`, `BankSyncFieldMapping.swift`, `BankSyncSupport.swift`, and `WalletTransactionMapping.swift`.
- Atomic persistence: `Actualist/LocalFirst/Database/BudgetDatabase+BankSync.swift`.
- Wallet import: `LocalFirstActualStore+WalletImport.swift` plus shared wallet mapping.

### Templates

- UI and workflow state: `Actualist/Features/Templates/` (`BudgetTemplatesBrowser*`, `BudgetTemplateEditor*`, apply-preview, confirmation, draft, input, and validation types).
- Store seam: `Actualist/LocalFirst/LocalFirstActualStore+Templates.swift` and `BudgetTemplatePreview.swift`.
- Database/engine: `Actualist/LocalFirst/Database/BudgetTemplate*`, `BudgetDatabase+Template*`, and `BudgetTemplateEngine*`.
- Template calendar/schedules: `BudgetTemplateCalendar.swift`, schedule recurrence, and engine schedule files.

### Rules and payees

- Settings UI: `Actualist/Features/Settings/RuleEditorView.swift`, rules-list files, and `PayeesView.swift`.
- Protocol/display seam: `Actualist/Repositories/RuleRepository.swift`, `RulePresentation.swift`, and `PayeeRepository.swift`.
- Store seam: `LocalFirstActualStore+Rules.swift`.
- Evaluation/persistence: `Actualist/LocalFirst/Database/BudgetDatabase+Rules.swift`, `RuleConditionEvaluator.swift`, `RuleFormulaEvaluator.swift`, `RuleSplitActionExecutor.swift`, `RuleRanking.swift`, and schedule helpers.
- Shared post-rule projection: `Actualist/Shared/TransactionRulePreviewProjection.swift`.

### Settings and onboarding

- Settings directory and pages: `Actualist/Features/Settings/`.
- Connection/budget data settings: `BudgetDataSettingsView.swift` and focused settings view models/coordinators nearby.
- Diagnostics: `DiagnosticReport.swift` and `SettingsDeveloperDiagnostics.swift`.
- Onboarding: `Actualist/Features/Onboarding/OnboardingView.swift` and `OnboardingViewModel.swift`.
- Connection/session implementation: `LocalFirstActualStore+Connection.swift`, `BudgetFileManager.swift`, `AppSettingsStore.swift`, and `Actualist/Security/`.

### Reports, history, notes, and shortcuts

- Reports: `Actualist/Features/Reports/`, `ReportsRepository.swift`, `LocalFirstActualStore+Reports.swift`, and `BudgetDatabase+Reports.swift`.
- History/undo: `Actualist/Features/History/`, `LocalFirstActualStore+ActionLog.swift`, `LocalFirst/ActionLog/`, and `BudgetDatabase+ActionLog*.swift`.
- Entity notes: `Actualist/Features/Notes/`, `EntityNotesRepository.swift`, `LocalFirstActualStore+Notes.swift`, and `BudgetDatabase+Notes.swift`.
- App Intents/Shortcuts: `Actualist/Features/Shortcuts/Intents/` for OS-facing intents, `Commands/` for parsed command values, `Entities/` for AppEntity models, and `ShortcutsBudgetSession*` for local budget access.

### Widgets

- App-side publication: `Actualist/Widgets/WidgetSnapshotCoordinator.swift`, snapshot builders/models/store, deep-link routing, theme, and quick-action definitions.
- Extension UI/timelines: `ActualistWidget/`.
- Shared target membership: curated in `Actualist.xcodeproj/project.pbxproj`; do not assume every app-side widget file is compiled into the extension.

## Local-first backend map

### Store facade

`Actualist/LocalFirst/LocalFirstActualStore.swift` defines the observable production repository implementation and owned caches/dependencies. Extensions divide orchestration by workflow:

- `+Connection` — authenticate, select/open/import/reset budget sessions.
- `+Sync` — pull/apply/flush sync and resolve sync failures.
- `+Reads` / `+BudgetCache` / `+BudgetLaunchSnapshot` — cached local reads and launch snapshots.
- `+Mutations`, `+TransactionMutations`, `+AssignMove` — local CRDT write flows.
- `+BankSyncPlanning`, `+BankSync`, `+WalletImport` — imported transaction flows.
- `+Templates`, `+Rules`, `+Notes`, `+Reports`, `+Widgets`, `+ActionLog`, `+AccountGroups`, `+Reconciliation` — focused feature bridges.
- `+Failover` and `ServerEndpointHealth.swift` — endpoint failover and health.
- `DemoMode/` — offline bundled-budget session.

When adding a store operation, extend the workflow-specific file rather than growing the base type or creating a second concrete repository.

### Database

`BudgetDatabase` is an actor around one imported budget's GRDB `DatabaseQueue`. File naming is the ownership index:

- `+BasicReads`, `+BudgetReads`, `+TransactionReads`, `+Reports` — query families.
- `+Sync` — CRDT application, local atomic mutation, and outbox behavior.
- `+BudgetWrites`, `+TransactionCreation`, `+TransactionUpdates`, `+TransactionSplitWrites` — mutation families.
- `+Schema`, `+LocalMigrations`, `+AccountGroupCompatibility` — local/schema compatibility.
- `+Rules`, rule evaluator files, and schedule helpers — Actual rule semantics.
- `+Template*` and `BudgetTemplate*` — template reads, authoring, preview, and apply engine.
- `+ActionLog*` — durable action history and undo inputs.
- `BudgetFileManager.swift` — imported budget directories/files and cache-presence lifecycle.

Keep SQL and storage-version tolerance here. Keep feature screen state out.

### Network and sync

- `LocalFirst/Network/ActualServerSyncClient.swift` — normal Actual server sync HTTP protocol and rejection decoding.
- `LocalFirst/Sync/SyncClient.swift` — sync transport abstraction/types.
- `LocalFirst/Sync/LocalFirstSyncMessageBuilder.swift` — compatible CRDT message construction.
- `LocalFirst/ActualBudgetCrypto.swift` — budget encryption operations.
- `LocalFirst/Generated/Sync.pb.swift` — generated protobuf; do not hand-edit.

Network clients transport/decode. They do not become a read source for screens.

## Data-flow traces

### Read

1. A feature view observes a focused view model.
2. The view model calls a repository protocol.
3. Production injection resolves that protocol to `LocalFirstActualStore`.
4. The store immediately exposes an owned cached snapshot when available.
5. The store reads `BudgetDatabase` for local truth and may refresh sync in the background.
6. Pulled CRDT messages are applied to SQLite; the store reloads affected caches; views update through observation.

### Write

1. A feature view emits intent only.
2. Its view model/coordinator validates workflow state and decides command values.
3. The repository call reaches a workflow-specific `LocalFirstActualStore` extension.
4. The store constructs Actual-compatible CRDT messages.
5. `BudgetDatabase` applies messages and enqueues the outbox in one protected SQLite transaction.
6. The store reloads affected local caches before returning.
7. The store opportunistically flushes; local success does not depend on immediate network success.

### Connection/open

1. Onboarding/settings coordinates through `AppState` and its focused collaborators.
2. `LocalFirstActualStore+Connection` authenticates and manages selection/open/import.
3. `BudgetFileManager` owns local budget file lifecycle.
4. Credentials, sync tokens, and encryption keys use `Security/KeychainStore.swift`; ordinary preferences use `Persistence/AppSettingsStore.swift`.
5. Session replacement clears store caches and app-global routes before presenting the new budget.

## Test navigation

- Start with the production type or workflow name under flat `ActualistTests/`: `BudgetViewModel…Tests`, `LocalFirstActualStore…Tests`, `BudgetDatabase…Tests`, `BankSync…Tests`, and so on.
- Shared test construction lives in files ending in `TestSupport.swift`; reuse it instead of inventing a second fixture style.
- SQLite/schema/oracle fixtures live under `ActualistTests/Fixtures/`.
- UI suites under `ActualistUITests/` are named by visible surface or interaction, such as adaptive settings, reconciliation, iPad review, notes, tracking budget, or month swipe.
- `scripts/test.sh unit <Suite>...` and `scripts/test.sh ui <Suite[/testMethod]>...` are the supported focused runners.
- `scripts/run-ios-simulator.sh --boot --reset --demo --screen <path> --screenshot` is the supported visual path.
- `scripts/check.sh` is always required before handoff but does not replace behavior-specific verification.

## Placement decision

Before adding code, classify it:

- View-local layout or presentation toggle -> the feature `View`.
- Loading, errors, selection, expansion, submission, or derived display state -> feature view model.
- Multi-step/cancellable workflow -> focused coordinator or explicit state model.
- Reusable pure calculation/input interpretation -> feature or domain value helper with focused tests.
- Feature-facing data contract -> repository protocol/model.
- Cached data ownership, write orchestration, or post-write reload -> `LocalFirstActualStore` workflow extension.
- SQL, schema tolerance, atomicity, or persisted Actual semantics -> `BudgetDatabase` or a database-owned helper.
- HTTP/wire decoding -> `LocalFirst/Network` or `LocalFirst/Sync`.
- App-wide session/settings/routing boundary -> `AppState` or an app coordinator.
- Cross-feature presentation primitive -> `DesignSystem`; cross-feature domain helper -> `Shared`.

If the behavior seems to fit two layers, keep the decision in the highest layer that owns the invariant while pushing storage and transport mechanics downward. Do not duplicate a calculation at each caller.

## Keeping this map useful

Update this skill and the short `AGENTS.md` architecture index in the same change when:

- a top-level directory or target is added or removed;
- an ownership seam or normal dependency direction changes;
- a feature's primary entry point moves;
- a new cross-cutting subsystem becomes a likely search destination.

Do not list every file. Prefer stable ownership anchors and naming patterns so ordinary file additions do not make the map stale.
