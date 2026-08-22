# Plan: Apple Shortcuts And Siri For Actualist

Ship a first-class App Intents catalog so Shortcuts, Siri, and Spotlight can
read and change the currently selected budget. Actuali’s eight actions are the
floor, not the target. If a value already exists in the local budget and a
person would reasonably ask Shortcuts for it — a balance, ready-to-assign,
overspent categories, uncategorized count, net worth, “add $50 to Groceries”,
“log $12 coffee” — it should be an action or a property on a returned entity.

Writes performed through Shortcuts apply immediately. There is no confirmation
sheet, review snippet, or second tap. “Open New Transaction” exists only as a
navigation action that prefills the existing editor; it is not a write gate.

## Progress Tracker

- [x] **Complete — Phase 1: Session, entities, settings, proving read.**
      2026-08-22, this commit. New `Features/Shortcuts/` module. `ShortcutsBudgetSession`
      opens the selected local budget without going through UI. Account /
      Category / Payee / Month entities and queries. Settings toggle.
      `Get Accounts` as the end-to-end proving intent.
      `AppShortcutsProvider` registered, even if phrases stay minimal until
      Phase 5. Evidence: early + normal simulator build zero warnings;
      complete-concurrency build succeeded with no new warnings in changed
      files; focused money/session/entity tests pass; full suite 613 tests /
      33 suites; plutil lint OK; liquid glass lint passed; error strings
      contain no paths or tokens; AppState 894 → 899.
- [x] **Complete — Phase 2: Read catalog.**
      2026-08-22, this commit. Rich getters for accounts, category metrics,
      payees, ready-to-assign, month summary, overspent categories,
      uncategorized items, recent / searched transactions, net worth, and
      cash flow. Money returns use `IntentCurrencyAmount` plus a spoken
      dialog. Evidence: normal + complete-concurrency builds succeeded with
      no new warnings in changed files; focused shortcut suites pass; full
      suite 621 tests / 34 suites; largest new intent file 284 lines.
- [x] **Complete — Phase 3: Transaction writes and text import.**
      2026-08-22, this commit. Log, transfer, update, categorize, set
      cleared, delete, and import from text. All go through
      `TransactionDraft` / the existing repository write methods.
      Unspecified category runs rule preview and applies a match. Evidence:
      parser table + command tests pass; normal + complete-concurrency
      builds succeeded; full suite 632 tests / 36 suites; command split at
      286 / 131 lines.
- [x] **Complete — Phase 4: Budget writes and creates.**
      2026-08-22, this commit. Assign, add-to-category, move money, apply
      template, set carryover, create payee, create account. No new budget
      math. Evidence: focused command tests pass; complete-concurrency
      build succeeded; full suite 637 tests / 37 suites.
- [x] **Complete — Phase 5: Open-in-app routes, Siri phrases, handoff.**
      2026-08-22, this commit. `AppRouteCoordinator` for Open Account /
      Category / Uncategorized / New Transaction / tabs. Notification
      spending route uses the coordinator. App Shortcut phrases. Privacy
      copy. Evidence: route tests pass; complete-concurrency build
      succeeded; full suite 640 tests / 38 suites; AppState 894 → 901.

## Intent And Why This Is Tractable

There is no App Intents code today. The domain work is already done.

| Need | Existing seam |
|------|----------------|
| Account list + balance | `accountDisplays(budgetID:)` / `AccountDisplay.balance` |
| Category available / budgeted / spent | `currentBudgetMonth` / `budgetMonth` → `BudgetMonthCategory` |
| Ready to assign | `BudgetMonth.toBudget` |
| Month totals | `BudgetMonth` (`totalBudgeted`, `totalSpent`, `totalIncome`, `fromLastMonth`, `forNextMonth`, `incomeAvailable`) |
| Overspent / uncategorized | `nativeBudgetAlerts` / `uncategorizedTransactions` |
| Payees | `editorOptions` / payee snapshot |
| Recent / search transactions | `cachedAccountTransactions`, `searchAccountTransactions`, `searchSpendingTransactions` |
| Create / update / categorize / delete transaction | `createTransactionAndRefresh`, `updateTransactionAndRefresh`, `categorizeTransactionAndRefresh`, `deleteTransactionAndRefresh` |
| Payee resolve-or-create | already inside `createTransactionAndRefresh` |
| Rule fill-in | `previewRules(for:budgetID:)` |
| Assign / move / template / carryover | `assignCategoryBudgetAndRefresh`, `moveMoneyAndRefresh`, `applyBudgetTemplateAndRefresh`, `setCategoryCarryoverAndRefresh` |
| Create account / payee | `createAccountAndRefresh`, `createPayeeAndRefresh` |
| Reports | `refreshReportsDashboard` → net worth, cash flow, budget overview |
| Default account | `AppSettings.defaultAccountIDByBudgetID` |
| Cold-open a cached budget | `openBudgetForBackgroundDiffIfNeeded` (used by background refresh) |
| Reconstruct `ActualBudget` from settings | `BackgroundTransactionRefreshRunner.budget(for:…)` |
| Draft construction | `TransactionDraft` / `TransactionDraftBuilder` |
| Money units | `Money` minor units; locale currency like the rest of the app |

Shortcuts should call those seams. It must not grow `AppState` into a feature
view model, must not add read/write methods to `LocalFirstActualStore`, and
must not invent a second budget database.

## Product Decisions

These are settled for this plan. Revisit only if a later review contradicts
them.

1. **Selected budget only.** Every action targets
   `AppSettings.selectedBudgetID`. No budget picker. Switching budgets stays
   an in-app Settings action.
2. **Writes go through.** Log, update, delete, assign, move, and create apply
   locally, enqueue CRDT messages, reload caches, and opportunistically flush
   exactly as the in-app editors do. No confirmation intent, no snippet
   review, no “are you sure”.
3. **Local-first, no extra sync.** Serving an intent opens the cached SQLite
   file if needed and reads/writes locally. It does not call
   `beginForegroundSession()` and does not wait on a server pull. Existing
   write methods already schedule an outbox flush.
4. **Device authentication for money.** Every intent that returns an amount
   or mutates the budget uses `authenticationPolicy = .requiresAuthentication`
   so a locked phone cannot speak or change balances. Pure tab opens
   (`Open Budget`, `Open Accounts`, `Open Spending`, `Open Reports`) do not
   require it.
5. **Real numbers always.** `randomizedDisplayValuesEnabled` is a screenshot
   aid. Shortcuts never apply `PrivacyDisplay`.
6. **Demo mode works.** Demo is a selected local budget. Intents run against
   it and never touch a transport, because the store already guards that.
7. **Hidden / closed are opt-in.** Default entity queries hide closed
   accounts and hidden categories. An `Include Hidden` / `Include Closed`
   parameter exists on the list getters. Write pickers use the default
   (visible) set.
8. **Off-budget accounts are first-class.** They appear in Get Accounts and
   can be used to log. Category is omitted for off-budget / transfer the
   same way the editor already does.
9. **Unspecified category uses rules.** If Log / Import does not name a
   category, run `previewRules` and apply a suggested category when present.
   Otherwise leave it uncategorized.
10. **Unspecified account uses the default account.** If none is set and none
    can be parsed, fail with “Choose an account or set a default account in
    Settings.”
11. **One-shot money intents plus rich entities.** Novices get `Get Account
    Balance` and `Get Ready to Assign`. Power users get `AccountEntity`,
    `CategoryEntity`, and `BudgetSummaryEntity` with properties they can
    pick in the Shortcuts editor.
12. **Siri phrases are static and few.** Phase 5 donates a short
    `AppShortcutsProvider` list. Do not donate personalized phrases that
    embed real payees or amounts.
13. **Main app target only.** No SiriKit extension, no App Group, no second
    process. App Intents in the app target run in-process; a cold start
    constructs `AppState` in `ActualistApp.init` the same way background
    refresh already does.

## Architecture

### Ownership

| Concern | Owner | Must not live in |
|---------|--------|------------------|
| Open selected budget, expose repository | `ShortcutsBudgetSession` | `AppState`, views, intent structs |
| Entity mapping / queries | `*Entity` + `*EntityQuery` | store, `AppState` |
| Intent `perform()` | thin wrapper that calls a command/session | views |
| Draft / amount / text parse / assign math | pure helpers under `Features/Shortcuts/Commands/` | views, store |
| Tab / sheet / editor navigation | `AppRouteCoordinator` | individual intents, `BudgetView` local state |
| Enablement toggle | `AppSettings.shortcutsEnabled` + Privacy settings | `AppState` feature logic |
| SQLite / CRDT / flush | existing `LocalFirstActualStore` methods | Shortcuts module |

`AppState` may register the session and hold the route coordinator. It may
not parse amounts, build drafts, or list entities.

### Session

```
ActualistApp.init
  → AppState()
  → ShortcutsBudgetSession(appState:)
  → AppDependencyManager.shared.add { session }
```

`ShortcutsBudgetSession` is `@MainActor` and the only thing intents depend
on.

```
prepare() throws -> PreparedBudget
  1. Read AppSettings.
  2. Throw if shortcutsEnabled == false.
  3. Throw if setup is .needsConnection / no selected budget.
  4. If store.isOpen(selectedID), return PreparedBudget.
  5. Reconstruct ActualBudget from settings the same way
     BackgroundTransactionRefreshRunner does.
  6. openBudgetForBackgroundDiffIfNeeded(...)
  7. Return PreparedBudget(budgetID, store, defaultAccountID, ...).
```

Cold start must not wait for `RootView.task` or `beginForegroundSession`.
Those start foreground sync. Shortcuts is a local-first reader/writer.

If two intents run while the app is already foregrounded, they must use the
live store, never open a second `BudgetDatabase` on the same file.

After a successful write the session increments `AppState.localDataRevision`
so an already-visible Budget / Accounts / editor reloads.

### File Layout

New files only. Register every one in `project.pbxproj`. Keep each file to
one responsibility; do not start a catch-all `Shortcuts.swift`.

```
Actualist/Features/Shortcuts/
  ShortcutsBudgetSession.swift
  ActualistShortcutsProvider.swift
  ShortcutsErrors.swift
  Entities/
    AccountEntity.swift
    CategoryEntity.swift
    PayeeEntity.swift
    TransactionEntity.swift
    BudgetMonthEntity.swift
    BudgetSummaryEntity.swift
  Commands/
    ShortcutMoney.swift
    ShortcutTransactionCommand.swift
    ShortcutBudgetCommand.swift
    ShortcutTextImportParser.swift
  Intents/
    AccountReadIntents.swift
    BudgetReadIntents.swift
    TransactionReadIntents.swift
    ReportReadIntents.swift
    TransactionWriteIntents.swift
    BudgetWriteIntents.swift
    OpenIntents.swift
  Routing/
    AppRoute.swift
    AppRouteCoordinator.swift
```

Intent files group a family, not the whole catalog. If any family file
approaches ~400 lines, split by verb (`Get*` vs `Log*`) before it grows
further.

Do not add net-new production code to:

- `AppState.swift` (894) — except a few-line toggle setter in Phase 1 and
  coordinator wiring in Phase 5
- `LocalFirstActualStore+Reads.swift` (596)
- `LocalFirstActualStore+Mutations.swift` (637)
- `LocalFirstActualStore+Connection.swift` (538)
- `TransactionEditorViewModel.swift` (768)
- `BudgetViewModel.swift` (773)

Phase 5 extracts routing instead of adding `pendingShortcutDraft` booleans
to `AppState`.

### Money And Dialogs

- Persist and compute in integer minor units, same as the rest of the app.
- Accept `Decimal` / `IntentCurrencyAmount` on write parameters. Convert
  with a tested `ShortcutMoney` helper. Reject non-finite values and more
  than two decimal places after rounding-to-nearest-cent.
- Return `IntentCurrencyAmount` so Shortcuts can add/compare results.
- Also return `ProvidesDialog` so Siri can say “Checking has $432.10”.
- Currency code is `Locale.current`, matching `Money.formatted()`. There is
  no per-budget currency in Actualist today. Do not invent one here.

### Entities

Stable IDs are Actual’s IDs.

| Entity | ID | Display | Query |
|--------|----|---------|--------|
| `AccountEntity` | account id | name; subtitle on/off-budget | visible open accounts; string search by name |
| `CategoryEntity` | category id | name; subtitle group | visible non-income by default; string search |
| `PayeeEntity` | payee id | display name | non-transfer by default; string search; include transfers when logging a transfer |
| `TransactionEntity` | transaction id | “Payee · amount · date” | recent page + `searchSpendingTransactions` / account search; cap 50 suggested, 100 hard |
| `BudgetMonthEntity` | `yyyy-MM` | “Apr 2026” | `availableMonths`, default current |

`CategoryEntity` properties: name, group, available, budgeted, spent,
carryover, isIncome, isHidden. One “Get Category” result should be enough
to build most budget automations.

`AccountEntity` properties: name, balance, offBudget, closed.

`TransactionEntity` properties: amount, date, payee, account, category,
notes, cleared, isTransfer.

Do not make `AppEntity` wrappers that mutate. Writes are intents.

### Errors

`ShortcutsError` is a `LocalizedError` with stable, user-facing copy:

- Shortcuts are turned off in Privacy
- No budget selected / still onboarding
- Budget file is not on disk (reopen the budget in the app)
- Encrypted budget needs the in-app unlock path first
- Account / category / payee / transaction not found
- Amount missing or invalid
- Transfer destination missing
- Default account missing
- Text import could not find an amount

Never include sync tokens, encryption keys, hostnames, or raw file paths.

## Catalog

Actuali’s list, then everything that is an obvious next question.

### Actuali floor

| Actuali | Actualist |
|---------|-----------|
| Get Accounts | `Get Accounts` → `[AccountEntity]` |
| Get Account Balance | `Get Account Balance` → currency |
| Get Categories | `Get Categories` → `[CategoryEntity]` |
| Get Category Balance | `Get Category Balance` (metric: Available / Budgeted / Spent, default Available) |
| Get Payees | `Get Payees` → `[PayeeEntity]` |
| Log Transaction | `Log Transaction` (writes immediately) |
| Import Transaction from Text | `Import Transaction from Text` (parse, then same write path) |
| Add Transaction with Review | **Not a write.** `Open New Transaction` prefills the existing editor |

### Beyond Actuali — reads

**Accounts**

- `Get Account` — one account entity, including balance
- `Get Account Transactions` — account + optional limit (default 25)

**Budget**

- `Get Category` — rich entity, not just one number
- `Get Ready to Assign` — `toBudget` for a month (default current)
- `Get Budget Summary` — ready to assign, total budgeted, total spent,
  total income, from last month, for next month, income available
- `Get Overspent Categories` — visible expense categories with
  `balance < 0` in that month
- `Get Uncategorized Transactions` / `Get Uncategorized Count`
- `Get Budget Alerts` — existing `BudgetMonthAlert` values as strings +
  amounts (ready-to-assign, overspent count, uncategorized)

**Transactions**

- `Get Transactions` — optional account, optional search, optional limit
- `Get Transaction` — one entity by picker / previous result

**Reports**

- `Get Net Worth` — balance + change
- `Get Cash Flow` — income, expenses, net, uncategorized for the month
- `Get Budget Overview` — actual vs budgeted + variance

Month parameters default to the current budget month, not “now” if the user
has been looking at another month in-app. Use `cachedBudgetMonth` when
present, otherwise `availableMonths.last`.

### Beyond Actuali — writes

**Transactions**

- `Log Transaction`
  - Parameters: amount (required), account (optional, default account),
    direction (`Spend` / `Inflow`, default Spend), payee (entity or name),
    category (optional), notes (optional), date (optional, default today),
    cleared (optional, default false)
  - Payee name creates/resolves through the existing write path
- `Log Transfer` — from account, to account, amount, date, notes
- `Update Transaction` — transaction + any subset of the log fields
- `Categorize Transaction` — transaction + category
- `Set Transaction Cleared` — transaction + bool
- `Delete Transaction` — transaction; applies immediately
- `Import Transaction from Text` — one string; see parser below

**Budget**

- `Assign Category Budget` — category, amount, month → sets `budgeted`
- `Add to Category Budget` — category, amount, month →
  `current.budgeted + amount` then assign. This is the “add $50 to
  Groceries” action and is worth more than a second Assign.
- `Move Money` — from category-or-ready-to-assign, to
  category-or-ready-to-assign, amount, month. Reuses
  `BudgetMoveMoneyCommand` (`fromCategoryID` / `toCategoryID` already
  allow `nil` for ready-to-assign).
- `Apply Budget Template` — mode Fill Empty / Overwrite, optional category
  (empty list = whole month)
- `Set Category Carryover` — category, enabled, start month

**Creates**

- `Create Payee` — name
- `Create Account` — name, off-budget flag (default on-budget)

### Beyond Actuali — open in app

These bring Actualist forward. They do not write.

- `Open Budget`
- `Open Accounts`
- `Open Spending`
- `Open Reports`
- `Open Account` — `accountNavigationPath = [account]`
- `Open Category` — present existing `CategoryMonthDetailsView`
- `Open Uncategorized` — present existing `UncategorizedTransactionsView`
- `Open New Transaction` — present existing `TransactionEditorView` with
  optional account / amount / payee / category / notes / direction

### Out Of Scope

Real features, not this plan. Ask before parking any of these in
`reference/follow-ups.md`.

- Rule create / edit / delete
- Reconcile account
- Merge, rename-as-a-primary-action, or delete payees (rename is not needed;
  log already resolve-or-creates)
- Delete / close / hide account
- Structured split-transaction builder (too many parameters for Shortcuts;
  the in-app editor stays the home for splits)
- Widgets, Control Center, Live Activities, Spotlight indexing of every
  transaction
- Multi-budget actions
- Per-budget currency
- Custom intent snippet UI / Liquid Glass in the Shortcuts result card
- Personalized Siri donations
- A separate App Intents extension or App Group
- Foreground sync as part of serving an intent

## Text Import

Pure helper: `ShortcutTextImportParser`. No NLP framework.

Accepted shapes, case-insensitive, currency symbols optional:

- `$12.50 coffee`
- `12.50 at Starbucks`
- `Coffee 12.50`
- `spent 12.50 on coffee in Checking`
- `received 200 paycheck`
- `12.50 coffee Groceries Checking`
- `transfer 50 from Checking to Savings`

Output is a structured parse, not a draft:

```
amountMinorUnits
direction?        // spend / inflow / transfer
payeeText?
accountText?
destinationAccountText?
categoryText?
notes?
date?
```

Resolution (command layer, not parser):

1. Amount is required or the intent throws.
2. Account text matches account names, case-insensitive, unique prefix
   allowed. Else default account. Else throw.
3. Category text matches visible category names the same way.
4. Payee text is passed through as a name; the write path resolves or
   creates.
5. If no category, run rule preview.
6. Then the same `ShortcutTransactionCommand.log` as `Log Transaction`.

Unit-test the parser with a table of strings. Do not call the store from
parser tests.

Ambiguous matches (two accounts named similarly) throw rather than guess.

## Open-In-App Routing

`AppState` is already over the 800-line keep-or-split line. Phase 5 adds
`AppRouteCoordinator` instead of more booleans.

```
enum AppRoute: Equatable {
    case tab(AppTab)
    case account(id: String)
    case category(id: String, month: String)
    case uncategorized(month: String)
    case newTransaction(ShortcutEditorPrefill)
}
```

Views already have the destinations:

- `MainTabView` binds `selectedTab`
- `AccountsView` binds `accountNavigationPath`
- `BudgetView` already presents category details and uncategorized
- `AccountTransactionsView` already presents `TransactionEditorView`

The coordinator publishes a pending route. The relevant view consumes and
clears it. Intents call `coordinator.enqueue(.account(id:))` and use
`ForegroundContinuableIntent` / `openAppWhenRun` so the scene comes
forward.

Do not deep-link through the existing `com.sporez.actualist` URL scheme.
That scheme is owned by OpenID.

`routeToSpendingFromNotification` should eventually forward through the
same coordinator so notification routing and Shortcuts routing do not
diverge. That migration is part of Phase 5, not a later cleanup.

## Settings And Privacy

Add `AppSettings.shortcutsEnabled: Bool` defaulting to `true` on decode so
existing installs get Shortcuts without a migration.

Surface it on `PrivacySettingsView` (41 lines; this is the right home):

- Toggle: “Allow Shortcuts & Siri”
- Footer: Shortcuts and Siri can read balances and log transactions in the
  selected budget. Turn this off to refuse every action. The device passcode
  or Face ID is still required for money actions.

`NSSiriUsageDescription` in `Info.plist`:

> Actualist uses Siri to log transactions and read budget amounts you ask
> for.

No new entitlements file.

## Siri Phrases (Phase 5)

Keep the provider short. Suggested set:

- “Get \(\.$account) balance in \(.applicationName)”
- “What’s left in \(\.$category) in \(.applicationName)”
- “How much can I budget in \(.applicationName)”
- “Log a transaction in \(.applicationName)”
- “Log \(\.$amount) for \(\.$payee) in \(.applicationName)”
- “Open spending in \(.applicationName)”

Titles and SF Symbols should match the in-app language (Budget, Accounts,
Spending), not Actuali’s wording.

## Testing

Test the session, commands, parser, entity queries, and router. Do not make
`AppIntent.perform()` the primary suite.

| Suite | Must cover |
|-------|------------|
| `ShortcutsBudgetSessionTests` | already-open store reused; cold open from settings; shortcuts disabled; no budget; demo opens; encrypted-without-unlock fails cleanly; write bumps `localDataRevision` |
| `ShortcutMoneyTests` | decimal ↔ minor units; rounding; invalid input; locale currency |
| `ShortcutTransactionCommandTests` | spend/inflow sign; default account; missing account; transfer; rule fill-in when category omitted; payee name path; delete/update/categorize |
| `ShortcutTextImportParserTests` | table of strings above; ambiguous account; missing amount |
| `ShortcutBudgetCommandTests` | assign; add-to uses current + delta; move to/from ready-to-assign; template modes |
| `ShortcutEntityQueryTests` | hidden/closed filtered by default; search; transaction query cap |
| `AppRouteCoordinatorTests` | enqueue / consume / clear; notification spending route uses it |
| `AppSettings` decode | missing `shortcutsEnabled` decodes as `true` |

Use the existing fake store / repository fakes. Do not hit a real server.

Any new money conversion or command-value branch needs a focused test
before production code, per the architecture gate.

## Phase Notes

### Phase 1

Prove the pipe: dependency registration, session, entities, settings
toggle, `Get Accounts`. After this, the Shortcuts app shows an Actualist
group with at least one action.

Implementation order inside the phase:

1. Mark this tracker item in progress in the same turn as the first
   production edit.
2. Add the Swift files to `project.pbxproj` and do an early simulator
   build before filling intent bodies.
3. Session + errors + tests.
4. Entities + `Get Accounts`.
5. Privacy toggle + Info.plist usage string.

`Get Accounts` should return entities with balances already populated so
Phase 2 is additive, not a rewrite.

### Phase 2

Add the rest of the read catalog. Prefer one rich `Get Category` / `Get
Budget Summary` and keep the one-shot money intents as thin wrappers so
Siri has a simple “what’s left in Groceries” phrase later.

Reports reads go through `refreshReportsDashboard` only when the cache is
empty; otherwise use `cachedReportsDashboard`. Same local-first rule as
screens.

### Phase 3

All transaction mutations share `ShortcutTransactionCommand`. Intent
structs only bind parameters and call the command.

Delete is in scope and unconfirmed, matching the write policy. It is still
a real-money action; the dialog after success should name the payee and
amount so the Shortcuts run log is auditable.

### Phase 4

`Add to Category Budget` must read the current month, add, then assign.
Do not add a new store method.

`Move Money` reuses `BudgetMoveMoneyCommand`. Do not reimplement cover /
overspent workflows.

### Phase 5

Extract `AppRouteCoordinator` first, migrate
`routeToSpendingFromNotification`, then add Open intents. Only then add
App Shortcut phrases (phrases that reference parameters need those intents
to exist).

Handoff is this phase: `git diff --check`, `git diff --numstat`, `wc -l`
on touched Swift files, largest-files check, no new AppState feature
logic, complete-concurrency build, focused tests then full suite, Liquid
Glass lint if Privacy UI changed, pbxproj membership, money-unit tests,
redaction check on error strings, tracker update.

## Verification Gate (Every Phase That Touches Production Code)

- Architecture gate before the first edit: read the destination files,
  measure them, search for an existing helper, state ownership, identify
  the test seam.
- No new `@State` that loads, writes, or computes money.
- No new concurrency warnings in changed files.
- Zero warnings from the normal project build.
- Full unit suite after the focused tests.
- Do not mark a tracker item complete without date, commit, and evidence.

## Non-Goals For The First Landing

Shipping Phase 1 alone is acceptable. The catalog above is the committed
shape of the feature, not a single PR. Do not thin the catalog by dropping
actions in later phases without updating this tracker and saying so.

Do not implement Actuali’s “Add Transaction with Review” as a write that
waits. The review-shaped action in Actualist is `Open New Transaction`.
