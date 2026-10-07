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

Build settings that affect where code runs: the app target sets no default actor isolation and does not enable `SWIFT_APPROACHABLE_CONCURRENCY` (it is set only on the UI-test target; see `project.pbxproj`). A plain `nonisolated async` function therefore already runs off the caller's actor. Heavy helpers still say `@concurrent` (for example `BudgetDatabase.open` and the CSV import pipeline) to make that intent explicit; `MainActor` isolation is always written out.

## Target and directory map

| Path | Ownership |
| --- | --- |
| `Actualist/App/` | App entry point, session lifecycle, background work, launch coordination, app-wide sync status, notifications, and tab identity. |
| `Actualist/Features/` | User-facing screens, feature view models, focused coordinators, presentation models, and feature-local pure logic. |
| `Actualist/Repositories/` | Dependency-injection protocols and domain/display models consumed by features. These are protocols, not concrete repository implementations. |
| `Actualist/LocalFirst/` | `LocalFirstActualStore`, local-first orchestration, cached snapshots, CRDT mutation construction, sync, import, and feature-facing repository conformance. |
| `Actualist/LocalFirst/Database/` | `BudgetDatabase` actor, GRDB/SQLite reads, schema compatibility, calculations close to stored data, and atomic write/outbox transactions. |
| `Actualist/LocalFirst/Network/` | Concrete Actual sync, SimpleFIN, and bridge HTTP clients. |
| `Actualist/LocalFirst/Sync/` | Sync transport abstraction, CRDT message builder, merkle trie, timestamps, and the reserved-dataset policy. |
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
| `scripts/` | Mechanical checks, simulator runner, focused test runner, parity tools, demo generation, release tooling, and `scripts/lab/` (create, reset, list and download test budgets on a disposable Actual server through upstream's own client; see its README). |
| `docs/` | Public development documentation and public plans. Local active planning and evidence may also exist under gitignored `reference/`. |

The app, unit-test, UI-test, and widget directories are Xcode file-system synchronized groups. New Swift files under existing synchronized roots compile automatically, except explicitly excluded resources. The widget target also compiles a curated set of shared files from `Actualist/Widgets/` and `Actualist/DesignSystem/`; inspect `Actualist.xcodeproj/project.pbxproj` when changing that cross-target boundary.

## App shell and lifecycle

Start here for launch, session, routing, background refresh, or app-wide state:

- `Actualist/App/ActualistApp.swift` — app entry, dependency construction, scene setup, and environment injection.
- `Actualist/App/AppState.swift` — app-wide session/setup state and lifecycle coordination only.
- `Actualist/App/AppSessionRecovery.swift` — credential-availability state, cached-budget launch restoration, budget discovery/selection recovery, and stale-session identity; never caches credential bytes.
- `Actualist/App/AppStateModels.swift` — small app-state enums/value types.
- `Actualist/App/AppSyncCoordinator.swift` — foreground sync coordination and status publication.
- `Actualist/App/BackgroundTransactionWorkflow.swift` and `BackgroundTransactionRefreshRunner.swift` — background transaction/bank work.
- `Actualist/App/LaunchWarmup.swift` and `LaunchInstrumentation.swift` — post-open warmup and launch measurements. Store cache warming is `LocalFirstActualStore+LaunchWarmup.swift`, not more work in `AppState`.
- `Actualist/App/AppTab.swift` — native tab identity. `BudgetCalendarCoordinator.swift` owns local month-boundary invalidation. `SpringboardQuickActionCoordinator.swift` owns home-screen quick actions.
- `Actualist/Features/Root/RootView.swift` — setup-to-main-shell boundary. `CredentialRecoveryView.swift` is the credential-recovery surface.
- `Actualist/Features/Root/MainTabView.swift` — compact native tab shell: Budget, Spending, Accounts, and Reports.
- `Actualist/Features/Root/AdaptiveRootShell.swift` — adaptive/iPad shell.
- `Actualist/Features/Root/AdaptiveBudgetSession.swift` — retained Budget presentation session across shell changes.
- `Actualist/Features/Root/RootTransactionEditorPresenter.swift` — shell-owned transaction editor presentation, including shortcut and quick-action entry. The editor screens themselves stay in Transactions.
- `Actualist/Features/Shortcuts/Routing/AppRouteCoordinator.swift` and `AppRoute.swift` — app routes and external/deep-link navigation.

Do not add a feature workflow to `AppState`. Put it in the feature view model or a focused coordinator and let `AppState` coordinate only its app-wide boundary.

## Feature routing table

### Budget

- Screen composition: `Actualist/Features/Budget/BudgetView.swift`, `BudgetWorkspaceView.swift`, `BudgetCompactMonthContent.swift`, and `BudgetRows.swift`.
- State and derived display logic: `BudgetViewModel.swift`, `BudgetViewportModel.swift`, and nearby `*Presentation.swift`, `*Policy.swift`, and draft-model files.
- Month navigation and layout: `BudgetMonthSwipeModifier.swift`, `BudgetAssignmentViewport.swift`, `BudgetAssignmentScrollPresentation.swift`, and viewport/layout helpers.
- Assignment and move-money workflows: `BudgetMoveMoneyWorkflow.swift` and `BudgetMoveMoneyView.swift`; persistence enters through `BudgetRepositoryProtocol` and `LocalFirstActualStore+AssignMove.swift`.
- Category create/rename/reorder/delete/visibility: `BudgetCategory*Workflow.swift` and the category sheets. Store writes are `LocalFirstActualStore+CategoryLifecycle.swift`; SQLite is `BudgetDatabase+CategoryLifecycle*.swift` and `+CategoryVisibility.swift`.
- Hold for next month: `BudgetHoldViewModel.swift` and `BudgetHoldSheet.swift` own the shared compact/wide review workflow. `BudgetDatabase+EnvelopeHolds.swift` owns the stored hold calculation; the focused hold store/database writers own persistence.
- Uncategorized flow: `UncategorizedTransactionsView.swift` and its view model/coordinator siblings.
- Backend reads/writes: `LocalFirstActualStore+Reads.swift`, `+AssignMove.swift`, `+Mutations.swift`, `+ActionLog.swift`; `BudgetDatabase+BudgetReads.swift`, `+BudgetWrites.swift`, and `+ActionLog*.swift`.

### Transactions and spending

- Spending tab: `SpendingTransactionsView.swift`, hosted by `MainTabView` and `AdaptiveRootShell`. It is not a separate feature directory.
- Account feed and summaries: `AccountTransactionsView.swift`, `AccountTransactionsViewModel.swift`, `AccountTransactionFeedProjection.swift`, and presentation siblings.
- Cached feed reads: `LocalFirstActualStore+TransactionFeeds.swift` and `+TransactionFeedCache.swift`, with `TransactionFeedCacheKey.swift` and `TransactionFeedCacheRefreshGate.swift`. Do not add a second feed cache in the view model.
- Editor UI/state: `TransactionEditorView.swift`, `TransactionEditorViewModel.swift`, `TransactionEditorSession.swift`. Shell presentation is `RootTransactionEditorPresenter.swift`.
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
- Wallet import UI: `Actualist/Features/Settings/WalletImportView.swift`, `WalletImportViewModel.swift`, and `WalletImportSettingsSection.swift`. Apply path: `LocalFirstActualStore+WalletImport.swift` plus shared wallet mapping.

### Templates

- UI and workflow state: `Actualist/Features/Templates/` (`BudgetTemplatesBrowser*`, `BudgetTemplateEditor*`, apply-preview, confirmation, draft, input, and validation types).
- Store seam: `Actualist/LocalFirst/LocalFirstActualStore+Templates.swift` and `BudgetTemplatePreview.swift`.
- Database/engine: `Actualist/LocalFirst/Database/BudgetTemplate*`, `BudgetDatabase+Template*`, and `BudgetTemplateEngine*`.
- Template calendar/schedules: `BudgetTemplateCalendar.swift`, schedule recurrence, and engine schedule files.

### Rules and payees

- Settings UI: `BudgetRulesView.swift` and `PayeeRulesView.swift` for the lists, `RuleEditorView.swift` for editing, and `PayeesView.swift` for payees.
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

- `+Connection` — authenticate, select/open/import/reset budget sessions. The database is built off the main actor with `BudgetDatabase.open` (`@concurrent`); `init` stays for tests and records main-thread construction in DEBUG.
- `+Sync`, `+SyncQuarantine`, `+Failover` — pull/apply/flush through the session's `ServerSyncLane`, quarantine diagnostics, and endpoint failover.
- `+Reads` / `+BudgetCache` / `+BudgetLaunchSnapshot` — cached budget-month reads and launch snapshots.
- `+TransactionFeeds` / `+TransactionFeedCache` — cached account and Spending feeds. Do not duplicate this cache.
- `+LaunchWarmup` — store-side cache warming after open.
- `+Mutations`, `+TransactionMutations`, `+AssignMove`, `+CategoryLifecycle`, `+AccountLifecycle`, `+Holds`, `+CommitTail` — local CRDT write flows and the shared post-commit tail.
- `+TransactionBatch`, `+TransactionDuplicate`, `+TransactionMerge`, `+TransactionFilters`, `+TransactionCSVImport`, `+TransactionCSVExport`, `+PendingNewTransactions` — transaction-list actions, saved filters, and CSV.
- `+Schedules`, `+ScheduleMutations`, `+ScheduleConversion`, `+SchedulePosting`, `+ScheduleAdvancement` — schedule reads, edits, conversion from a transaction, manual and automatic posting.
- `+BankSyncPlanning`, `+BankSync`, `+WalletImport`, `+ImportReconcile` — imported transaction flows.
- `+PortableExport`, `+PortableImport`, `+PortableRegistration`, `+NewBudget` — ZIP export and import, server registration, and New Budget.
- `+Templates`, `+Rules`, `+Notes`, `+Reports`, `+Widgets`, `+ActionLog`, `+AccountGroups`, `+Reconciliation` — focused feature bridges.
- `ServerSyncLane.swift` — the one serialized flush/pull lane per budget session (flush flag, queued waiters, scheduled flush task, status tickets). `closeOpenBudget()` invalidates it and installs a fresh lane, so a late finisher releases its own dead lane.
- `ServerEndpointHealth.swift` — endpoint health cache.
- `StoreTestSeams.swift` — every optional test hook, in one `#if DEBUG` type behind `store.seams`. Release builds contain no hook property, type or awaited call site. Add new hooks here, never as store properties.
- `DemoMode/` — offline bundled-budget session. Bundled files are `Actualist/Resources/DemoBudget.zip` and `TrackingDemoBudget.zip`.

When adding a store operation, extend the workflow-specific file rather than growing the base type or creating a second concrete repository.

Repositories are per feature, not one facade: `Actualist/Repositories/` holds `BudgetRepositoryProtocol`, `TransactionRepositoryProtocol` plus focused protocols for batch, duplicate, merge, CSV import, saved filters, schedules (read, mutation, posting, conversion), account lifecycle, payees, rules, notes and reports. `LocalFirstActualStore` conforms to all of them; a view model depends only on the protocol it uses, and tests inject a fake of that one protocol.

### Database

`BudgetDatabase` is an actor around one imported budget's GRDB `DatabaseQueue`. File naming is the ownership index:

- `+BasicReads`, `+BudgetReads`, `+TransactionReads`, `+Reports` — query families.
- `+Sync`, `+Merkle` — remote CRDT application and the merkle trie (see Sync and merkle below).
- `+LocalCommit`, `+UserActionPlan` — the write core (see Write trace).
- `+BudgetWrites`, `+EnvelopeHolds`, `+TransactionCreation`, `+TransactionUpdates`, `+TransactionSplitWrites` — budget and transaction mutation families.
- `+CategoryLifecycle`, `+CategoryLifecycleDeletion`, `+CategoryVisibility` — category structure and hidden-category persistence.
- `+Schema`, `+LocalMigrations`, `+AccountGroupCompatibility` — local/schema compatibility.
- `+Rules`, rule evaluator files, and schedule helpers — Actual rule semantics.
- `+Template*` and `BudgetTemplate*` — template reads, authoring, preview, and apply engine.
- `+ActionLog*` — durable action history and undo inputs.
- `+Schedules`, `+ScheduleReads`, `+ScheduleWrites`, `+SchedulePosting`, `+ScheduleAdvancement`, `+ScheduleConversion` and `ScheduleRuleProjection.swift` — schedules and their linked rules.
- `+PortableExport`, `+PortableSyncReset`, `+NewBudgetSeed` — portable ZIP content and the CRDT reset applied to an imported file.
- `+TransactionBatch*`, `+TransactionDuplicate`, `+TransactionMerge`, `+TransactionFilters`, `+TransactionCSV*`, `+TransactionQuery` — list actions, structured queries and CSV.
- `+*ReviewGuard`, `+ReconciledMutationGuard`, `+ImportedIDPrecondition`, `+PayeeCreationPrecondition` — review preconditions checked inside the commit transaction.
- `BudgetFileManager.swift` and `BudgetFileManager+PortableInstall.swift` — imported budget directories/files and cache-presence lifecycle.

Keep SQL and storage-version tolerance here. Keep feature screen state out.

### Network and sync

- `LocalFirst/Network/ActualServerSyncClient.swift` — normal Actual server sync HTTP protocol and rejection decoding.
- `LocalFirst/Sync/SyncClient.swift` — sync transport abstraction/types.
- `LocalFirst/Sync/MerkleTrie.swift`, `SyncTimestamp.swift`, `ActualSyncDatasetPolicy.swift` — Actual's merkle trie, hybrid logical clock timestamps, and the set of datasets that are stored but never applied.
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
3. The repository call reaches a workflow-specific `LocalFirstActualStore` extension. A review-then-apply flow (reconciled rows, templates, holds, batch, merge, duplicate, bank link, imported IDs) first returns a review carrying the preconditions it was built from.
4. The store calls `BudgetDatabase.commitUserActionPlan` (or one of its adapters, below). Its build closure runs inside the write transaction, so messages are built from the live rows read through `db`, never from an earlier read. Do not build messages from a snapshot and commit them later.
5. The core, `commitLocalPlan`, checks the session write fence once, then in one SQLite transaction: validates the review preconditions (`validateLocalCommit` over `LocalCommitReview`), captures action-log facts, applies the CRDT cells, writes the merkle trie, enqueues `actualist_outbox`, and records pending new transactions. A failed precondition rolls back everything.
6. The fence is `invalidateSessionWrites()`, a non-blocking atomic flag. It refuses commits that have not started; a commit already inside its transaction finishes. A caller about to swap or delete the files awaits `quiesce()` after flipping it. `closeOpenBudget()` flips it.
7. After the commit the store finishes through `LocalFirstActualStore+CommitTail`. The tail rule: a write that has committed is never reported as cancelled or failed. User-repeatable writes (create, update, delete, categorize, assign, Move Money, Holds, Wallet import) use the durable tail (`finishDurableCommit`: an unstructured task, so caller cancellation cannot interrupt the reload; the result is returned, or `refreshPending`). Idempotent last-write-wins writes (notes, hide, rename, payee and rule edits, carryover, templates) use the attached tail, which reports `refreshPending` on a cancelled reload. Schedule advancement keeps its own background tail.
8. The tail reloads affected local caches and opportunistically flushes through the sync lane; local success never depends on the network.

Adapters over the core: `commitUserActionPlan` (user gestures; adds the action-log descriptor), `commitLocalSyncMessagesAndEnqueue` (pre-built message drafts with optional preconditions), and the undo commit. New writers should reuse the core rather than open their own write transaction.

### Sync and merkle

- The pull path asks the server for messages since the local merkle trie diverges (`merkleDivergence`), applies them with `applyRemoteSyncMessagesTrackingInserts`, and updates the trie in the same transaction. `writeTrackingMerkle` stages inserts and persists the pruned trie atomically; the in-memory cache is replaced only after commit.
- An imported `messages_clock` is not trusted. `ensureMerkleTrieTrusted()` rebuilds the trie lazily, once per file, on the first merkle use rather than at open.
- A remote batch with an invalid timestamp is rejected whole. A value that cannot be read, or that targets a reserved dataset, is stored in `messages_crdt` but never applied (quarantine); `+SyncQuarantine` reports counts and timestamps only, never values.
- Server access goes through the session's `ServerSyncLane`, which serializes flush and pull in request order.

### Import, export and the CRDT reset

- Every imported-transaction source (Bank Sync, CSV, Wallet) shares one reconcile pipeline: rule projection, then `reconcileProjectedImport`, then `importReconcileWrites` (`LocalFirstActualStore+ImportReconcile.swift`, `Shared/BankSyncReconciler.swift`). The source owns only parsing, mapping and its own review.
- CSV import stages are `@concurrent` helpers in `Shared/TransactionCSVImportPipeline.swift`; the store applies the reviewed plan through the write core.
- Portable ZIP export writes a temporary plaintext archive that is removed after the share (`PortableExportFiles`). Portable import validates and stages the archive (`PortableBudgetArchive`, `UntrustedZipExtractor`), clears its carried CRDT history with `resetSyncHistory` (the new server group starts empty, so a carried trie could never converge), installs it into a new directory, and registers it on the server. A budget downloaded or re-imported from a server keeps its `messages_crdt`.
- New Budget (`+NewBudget`, `BudgetDatabase+NewBudgetSeed`) seeds a starter schema and registers it the same way.

### Schedules

Reads are `LocalFirstActualStore+Schedules` over `BudgetDatabase+ScheduleReads`, cached per budget with a request identity for stale results. Edits go through a review (`ScheduleMutationPrecondition`) and `+ScheduleMutations`; a schedule and its rule are written together (`ScheduleRuleProjection`, `ScheduleRuleMutation`). Posting a due schedule is `+SchedulePosting` behind a posting gate; background advancement is `+ScheduleAdvancement`.

### Session transitions

`Actualist/App/BudgetSessionTransitionCoordinator.swift` is the single owner of select, restore, reimport, Shortcut/background opens, discovery and demo transitions. It de-duplicates a request for the budget already in transition, refuses a conflicting budget or kind, and runs on an unstructured task so a cancelled caller cannot abandon a transition. The store's session generation still stops stale work from publishing.

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
- UI suites under `ActualistUITests/` are named by visible surface or interaction, such as adaptive settings, reconciliation, iPad review, notes, tracking budget, month swipe, category lifecycle, credential recovery, or Springboard quick actions.
- `scripts/test.sh unit <Suite>...` and `scripts/test.sh ui <Suite[/testMethod]>...` are the supported focused runners.
- Tests that need to park a store operation use the DEBUG hooks on `store.seams` with `TestLatch`/`ObservedTestState`, not yield loops.
- `scripts/lab/budgets.sh` builds and resets test budgets on a disposable Actual server for live checks; read `scripts/lab/README.md` before use and never point it at a real server.
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
