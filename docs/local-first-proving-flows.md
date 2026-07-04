# Local-First Actualist Proving Plan

This fork is for testing whether Actualist can keep its existing SwiftUI experience while replacing the REST-backed data plane with Actual Budget's native local-first sync model.

The proving target is intentionally narrow:

1. Authenticate with a normal Actual server and list remote budgets.
2. Download one budget, import/open its local SQLite database, and configure sync metadata.
3. Render Actualist's Budget and Accounts screens from SQLite-backed data instead of the HTTP REST API container.

Do not implement transaction writes, budget writes, reconcile, bank sync, templates, alerts, or offline conflict recovery in this first proof. Those are later phases once the read path is real.

## Source Baseline

- Actualist fork root: `/Users/neil/CC/actualist-local-first-spike`
- Actuali source inspected: `MattFaz/actuali` at commit `d2b894020492245930b3161ba69b4c6c1aacff63`
- Actuali architecture to borrow:
  - `Actuali/Actuali/Services/Network/ActualServerClient.swift`
  - `Actuali/Actuali/Services/Database/BudgetFileManager.swift`
  - `Actuali/Actuali/Services/Database/BudgetDatabase.swift`
  - `Actuali/Actuali/Services/Sync/`
  - `Actuali/Actuali/Generated/Sync.pb.swift`
  - `Actuali/Actuali/Resources/sync.proto`
  - supporting models and encryption helpers needed by those files

Actuali's important design fact: reads come from local SQLite, writes generate CRDT messages and sync to `/sync/sync`. For this proof, only the read side and sync configuration need to work.

## Architectural Goal

Keep Actualist's UI and view-model architecture. Replace only the production repository/store implementation under the existing seams.

Current Actualist shape:

```text
SwiftUI views
  -> feature view models
  -> BudgetRepositoryProtocol / TransactionRepositoryProtocol
  -> ActualDataStore
  -> ActualAPIClient
  -> actual-http-api REST container
```

Proof target shape:

```text
SwiftUI views
  -> feature view models
  -> BudgetRepositoryProtocol / TransactionRepositoryProtocol
  -> LocalFirstActualStore
  -> BudgetDatabase / SyncClient / ActualServerClient
  -> normal Actual server sync endpoints
```

The first proof should avoid view rewrites. If a view needs changes, that is a sign the adapter layer is too thin or the mapping from SQLite rows to Actualist domain models is incomplete.

## Non-Goals For This Proof

- Do not delete `ActualAPIClient` or the current `ActualDataStore`.
- Do not mutate real budget data through the local-first engine yet.
- Do not attempt a full Actuali UI merge.
- Do not add HTTP API container dependencies.
- Do not support every dashboard/report/widget table.
- Do not solve all schema drift. Only open a current real budget and record gaps.
- Do not try to make both REST-backed and local-first stores share one cache object.

## New Local-First Modules

Create a contained area so the experiment stays reversible:

```text
Actualist/LocalFirst/
  Network/
    ActualServerSyncClient.swift
    OpenIDAuthenticator.swift              # only if OpenID is needed in this proof
  Database/
    BudgetFileManager.swift
    BudgetDatabase.swift
    LocalFirstModelMapping.swift
  Sync/
    CRDTMessage.swift
    EncryptionKeyManager.swift
    HLCTimestamp.swift
    HybridLogicalClock.swift
    MerkleTree.swift
    MessageGenerator.swift
    MurmurHash3.swift
    SyncClient.swift
    SyncEncoder.swift
    SyncEncryption.swift
  Generated/
    Sync.pb.swift
  LocalFirstActualStore.swift
```

Suggested dependency additions:

- `GRDB.swift`
- `SwiftProtobuf`
- `ZIPFoundation`

Keep these package additions in one commit so they are easy to audit or back out.

## Flow 1: Authenticate And List Budgets

### Purpose

Prove Actualist can talk directly to the normal Actual server, authenticate, and list remote budget files without the REST container.

### Implementation Steps

1. Port or adapt Actuali's `ActualServerClient` into `Actualist/LocalFirst/Network/ActualServerSyncClient.swift`.
2. Keep the client actor-based.
3. Support these endpoints first:
   - `GET /account/login-methods`
   - `POST /account/login`
   - `GET /sync/list-user-files`
4. Store the returned Actual server token in Keychain, separate from the current HTTP API key entry.
5. Add a local-first connection mode in settings or behind a temporary compile-time switch:

```swift
enum BackendMode: String, Codable, Hashable, Sendable {
    case restAPI
    case localFirstSync
}
```

6. In local-first mode, onboarding/settings should ask for:
   - Actual server URL
   - server password or OpenID credentials
   - selected budget file
   - encryption password only if the budget requires it

Do not reuse the "Actual HTTP API base URL + API key" copy for this flow. It is a different backend contract and should feel different in the UI.

### Acceptance Criteria

- A real Actual server URL can be entered.
- Password login succeeds and persists a sync token in Keychain.
- Available remote budgets render by name.
- Deleted remote files are filtered out.
- Logging out removes the sync token.
- The old REST mode still compiles.

### Manual Test

1. Build the fork.
2. Launch in local-first mode.
3. Enter the normal Actual server URL, not `actual-http-api`.
4. Authenticate.
5. Confirm the remote budget picker shows the expected budget names.
6. Kill and relaunch the app.
7. Confirm the token is restored and budgets can be listed again without retyping the password.

### Unit Test Targets

- URL normalization.
- Login response decoding.
- Login methods decoding.
- File list decoding with deleted-file filtering.
- Keychain token save/load/remove wrapper.

## Flow 2: Download, Import, And Open Budget

### Purpose

Prove the app can download a budget file, import the zipped Actual budget database, open SQLite with GRDB, and configure sync identity.

### Implementation Steps

1. Port/adapt:
   - `BudgetFileManager`
   - `BudgetDatabase`
   - `BudgetMetadata`
   - encryption helpers if using encrypted budgets
2. Add support for:
   - `GET /sync/download-user-file`
   - `GET /sync/get-user-file-info`
   - `POST /sync/user-get-key`
3. Store downloaded budgets under Application Support, for example:

```text
Application Support/Actualist/Budgets/<budget-id>/
  db.sqlite
  metadata.json
```

4. Import the downloaded ZIP and persist metadata containing:
   - local budget id
   - cloud file id
   - group id
   - budget name
   - encryption key id when present
5. Open `db.sqlite` through `BudgetDatabase`.
6. Run only safe upstream schema migrations needed to open current files.
7. Configure `SyncClient` with:
   - `BudgetDatabase`
   - `fileId`
   - `groupId`
   - node id
   - encryption key and key id if applicable
8. Do not perform any local write yet.

### Acceptance Criteria

- Selecting a remote budget downloads the ZIP.
- The ZIP imports into the app support directory.
- `db.sqlite` exists and can be opened by GRDB.
- `metadata.json` includes the remote `fileId` and `groupId`.
- Encrypted budgets either open after password unlock or fail with a clear "encryption password required" state.
- `BudgetDatabase.fetchAccounts()`, `fetchCategoryGroups()`, `fetchPayees()`, and `fetchBudgetMonth(month:)` can run without crashing.
- `SyncClient.configure(...)` succeeds.

### Manual Test

1. Remove any previous local-first test data from the app or simulator.
2. Authenticate and select a budget.
3. Download/import it.
4. Confirm the app shows an "opened local budget" state.
5. Put the device in airplane mode.
6. Relaunch the app.
7. Confirm the app can still open the local budget and fetch accounts/categories/month data from SQLite.

### Unit Test Targets

- ZIP import rejects missing `db.sqlite`.
- ZIP import rejects missing `metadata.json`.
- Imported metadata preserves `cloudFileId` and `groupId`.
- Encrypted key derivation fixture, if encrypted budgets are in scope.
- `BudgetDatabase` opens a fixture SQLite file and runs read queries.

## Flow 3: Render Budget And Accounts From SQLite

### Purpose

Prove Actualist's existing UI can be fed by the local Actual database with minimal view churn.

### Implementation Steps

1. Create `LocalFirstActualStore`.
2. Make it conform to the existing repository protocols where needed:
   - `BudgetRepositoryProtocol`
   - read portions of `TransactionRepositoryProtocol` if the existing screens require editor options or transaction lists
3. Add mapping code from Actuali-style models/SQLite rows into Actualist's domain/display models:
   - SQLite `accounts` -> `ActualAccount`
   - SQLite `category_groups` and `categories` -> `ActualCategory`
   - SQLite `payees` -> `ActualPayee`
   - SQLite budget calculations -> `BudgetMonth`
4. Start with these repository methods:

```swift
func budgets() async throws -> [ActualBudget]
func currentBudgetMonth(budgetID: String, preferredMonth: String) async throws -> LoadedBudgetMonth
func budgetMonth(budgetID: String, selectedMonth: String) async throws -> LoadedBudgetMonth
```

5. Add account-list support through the store path used by `AccountsView`.
6. If the existing account screen depends directly on `ActualDataStore` cache internals, introduce a small repository seam instead of letting views query `BudgetDatabase`.
7. Return empty alerts for this proof unless local alert derivation is explicitly implemented:

```swift
LoadedBudgetMonth(
    availableMonths: fetchedMonths,
    selectedMonth: selectedMonth,
    month: mappedMonth,
    alerts: []
)
```

8. Keep all mapping and money math out of SwiftUI views.

### Acceptance Criteria

- Budget tab renders category groups and category rows from SQLite.
- Budgeted, spent, and available amounts match the Actual web app for the chosen month within Actual amount-unit expectations.
- Accounts tab renders on-budget and off-budget accounts from SQLite.
- Account balances match Actual web app values for the same budget.
- The app can render those two tabs while offline after the initial download.
- No screen calls `ActualServerSyncClient` or `BudgetDatabase` directly from SwiftUI.

### Manual Test

1. Open a downloaded local budget while online.
2. Navigate to Budget.
3. Compare:
   - total budgeted
   - total spent
   - total available
   - a few category row values
4. Navigate to Accounts.
5. Compare:
   - account names
   - account ordering
   - account balances
   - closed/hidden behavior
6. Turn off network.
7. Force quit and relaunch.
8. Confirm Budget and Accounts still render from local SQLite.

### Unit Test Targets

- Account mapping handles tombstone, closed, offbudget, and sort order.
- Account balance calculation excludes split parents and tombstoned rows.
- Budget month calculation handles:
  - envelope budgets
  - tracking budgets
  - carryover
  - hidden groups/categories
  - income categories
  - category mappings
- Money formatting still uses Actualist's existing amount-unit conventions.

## Verification Ladder

Run verification in this order as the proof develops.

### 1. Static Build

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -target Actualist \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 2. Focused Unit Tests

Add tests under `ActualistTests/LocalFirst/` and run the narrow suite first:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ActualistTests/LocalFirstActualStoreTests \
  test
```

Adjust the scheme/destination if this fork still uses the target-only build fallback.

### 3. Simulator Smoke Test

Use a fresh simulator install. Verify the three flows with a non-production test budget first.

### 4. Physical Device Smoke Test

After simulator proof:

```sh
xcodebuild \
  -project Actualist.xcodeproj \
  -scheme Actualist \
  -destination 'platform=iOS,id=00008150-0001189C2220401C' \
  -derivedDataPath .derivedData \
  build
```

Then install and launch on Airy using the standard Actualist device flow.

## Suggested Commit Breakdown

1. `chore: add local-first spike dependencies`
2. `feat: add Actual server sync login and budget listing`
3. `feat: import and open local Actual budget database`
4. `feat: map local budget data into repository protocols`
5. `test: cover local-first database import and read mapping`

Keep generated protobuf output in the same commit as the sync proto integration.

## Risk Register

### Schema Drift

Actual's local database schema changes over time. Actuali already carries guarded migrations for several upstream additions. The proof should record every missing table/column rather than broadening migrations blindly.

### Budget Math Parity

Budget month math is easy to get subtly wrong. Compare against the Actual web app, not just against Actualist's old REST output.

### Encrypted Budgets

Encrypted budget support requires both whole-file decryption for download and per-message encryption/decryption for sync. If this slows the proof, start with an unencrypted test budget and mark encrypted budgets as phase 1.5.

### Store Lifetime

GRDB database ownership and `SyncClient` actor lifetime must be single-owner per opened budget. Do not create fresh database/sync clients casually inside views or view models.

### Dual Backend Confusion

The REST API server URL/API key and Actual server URL/token are different credentials. Keep labels, storage keys, and settings state separate.

### Write Safety

Do not enable local-first writes until read parity is proven. A half-correct CRDT write path can affect real budget data once it syncs.

## Done Definition For The Proof

The proof is done when:

- A clean fork build succeeds.
- A normal Actual server login can list remote budgets.
- A selected budget downloads and opens locally.
- Budget and Accounts render from local SQLite.
- The same two screens still render after relaunch with network disabled.
- A short parity note records what matched, what differed, and which missing features block transaction-write work.

## Recommended Next Step After The Proof

If the three flows pass, the next phase should be transaction read/write parity:

1. Render account transactions from SQLite.
2. Create a transaction locally.
3. Generate CRDT messages.
4. Sync and verify the transaction appears in Actual web.
5. Edit/delete the transaction from Actualist and verify Actual web parity.

Only after that should budget writes, move money, templates, reconcile, bank sync, or alert derivation move into the local-first path.
