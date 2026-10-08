import Foundation

/// The options upstream's `reconcileTransactions` / `matchTransactions`
/// expose (`packages/loot-core/src/server/accounts/sync.ts`, pinned Actual
/// v26.9.0). Bank Sync and CSV import run the same reconcile; only these
/// options differ. `transactions-import` passes the CSV defaults
/// (`accounts/app.ts` `importTransactions`); Bank Sync passes
/// `isBankSyncAccount: true` and leaves the rest to the per-account
/// preference (`strictIdChecking` is upstream's default `true`, but
/// Actualist's Bank Sync has always matched without it, and its shipped
/// behavior stays byte-identical).
struct ImportReconcileOptions: Equatable, Sendable {
    /// The rows come from a bank provider: each carries its own `imported_id`
    /// and a provider payee name, and the apply never writes a missing one.
    /// When false (CSV), a matched update writes the incoming `imported_id` and
    /// `imported_payee` even when absent, clearing the stored value
    /// (`imported_id: trans.imported_id || null`, sync.ts).
    var isBankSyncAccount: Bool
    /// Upstream's fuzzy query only considers rows that have no `imported_id`
    /// when the incoming row has one (`(imported_id IS NULL OR ? IS NULL)`).
    var strictIdChecking: Bool
    /// `nil` reads the account's `sync-reimport-deleted-<id>` preference (Bank
    /// Sync). `true` re-imports rows the user deleted, so no deleted id is
    /// suppressed (the CSV default).
    var reimportDeleted: Bool?
    /// An inserted row whose source did not say whether it is cleared takes
    /// this value (`trans.cleared ?? defaultCleared`).
    var defaultCleared: Bool
    /// `normalizePayeeName`: how a new payee name is spelled.
    var payeeNameNormalization: ImportPayeeNameNormalization

    /// Bank Sync as shipped in 0.8.1.
    static let bankSync = ImportReconcileOptions(
        isBankSyncAccount: true,
        strictIdChecking: false,
        reimportDeleted: nil,
        defaultCleared: true,
        payeeNameNormalization: .original
    )

    /// Upstream `transactions-import` defaults (main-to-dev D5).
    static let csv = ImportReconcileOptions(
        isBankSyncAccount: false,
        strictIdChecking: true,
        reimportDeleted: true,
        defaultCleared: true,
        payeeNameNormalization: .titleCase
    )
}
