# Actualist

Actualist is a planned native iOS client for an Actual Budget HTTP REST API container.

The app is intended for iOS 26+ and should be implemented with Swift and SwiftUI only. UIKit should not be used for app UI.

The first build target is a read-focused mobile companion with three core surfaces:

- Budget: current month category groups, category balances, assigned amounts, ready-to-assign money, and overspending alerts.
- Accounts: grouped account list with current balances and closed account handling.
- Account Transactions: transaction timeline for a selected account, with payee/category context and cleared status.

Reference materials live in [reference](reference/):

- [openapi.json](reference/openapi.json): Actual HTTP API v26.6.0 endpoint contract.
- [Budget.PNG](reference/Budget.PNG): visual reference for the budget/envelope view.
- [Accounts.PNG](reference/Accounts.PNG): visual reference for account grouping and balances.
- [Account Transactions.PNG](reference/Account%20Transactions.PNG): visual reference for transaction list detail.

See [docs/PLAN.md](docs/PLAN.md) for the implementation plan, architecture notes, API mapping, and open questions.
See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the Xcode/simulator development loop.
