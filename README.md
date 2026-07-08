# Actualist

Actualist is a native iOS local-first client for Actual Budget. It connects to a
normal Actual server, imports the budget SQLite database, syncs CRDT messages,
and renders from the local database. It does not depend on the sibling
`actual-http-api` REST wrapper.

The app is intended for iOS 26+ and should be implemented with Swift and SwiftUI only. UIKit should not be used for app UI.

The app focuses on repeated mobile budget review and common write flows across
four core surfaces:

- Budget: current month category groups, category balances, assigned amounts, ready-to-assign money, and overspending alerts.
- Accounts: grouped account list with current balances and closed account handling.
- Spending: all-account transaction feed and search.
- Account Transactions: transaction timeline for a selected account, with payee/category context and cleared status.
- Settings: Actual server connection, budget selection, sync controls, display density, theme, privacy mode, and developer-gated local writes.

See [docs/PLAN.md](docs/PLAN.md) for the current product direction and architecture notes.
See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the Xcode/simulator development loop.
