import Foundation

/// New-transaction alerts on the store: the pending rows a remote sync or
/// Bank Sync recorded, their delivery to a notification, and the review that
/// reconciles the legacy settings projection. The store owns it.
@MainActor
final class PendingTransactionWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    struct PendingNewTransactionDelivery: Equatable, Sendable {
        let requestIdentifier: String
        let transactionIDs: [String]
    }

    func reconcilePendingNewTransactionProjection(
        budgetID: String,
        legacyStorage: [String: [String]]
    ) async throws -> [String: [String]] {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let prefix = pendingNewTransactionPrefix(budgetID: budgetID)
        let legacyByAccount = Self.accountScopedIDs(in: legacyStorage, prefix: prefix)
        try await PendingNewTransactionSQL.migrateLegacyPendingNewTransactions(legacyByAccount, in: database)
        let durable = try await PendingNewTransactionSQL.pendingNewTransactionIDsByAccount(in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        return replacingPendingNewTransactionProjection(
            legacyStorage,
            budgetID: budgetID,
            durableByAccount: durable
        )
    }

    func registerRemotePendingNewTransactions(
        _ pending: [BackgroundPendingTransactions],
        budgetID: String,
        notificationID: String
    ) async throws {
        guard !pending.isEmpty else { return }
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await PendingNewTransactionSQL.recordPendingNewTransactions(.init(
            transactionIDsByAccount: Dictionary(
                pending.map { ($0.accountID, $0.transactionIDs) },
                uniquingKeysWith: { $0 + $1 }
            ),
            source: .remoteSync,
            notificationID: notificationID
        ), in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    func pendingNewTransactionDelivery(
        budgetID: String
    ) async throws -> PendingNewTransactionDelivery? {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        let delivery = try await PendingNewTransactionSQL.pendingNewTransactionDelivery(in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        return delivery.map {
            PendingNewTransactionDelivery(
                requestIdentifier: "actualist.new-transactions.\($0.notificationID)",
                transactionIDs: $0.transactionIDs
            )
        }
    }

    func acknowledgePendingNewTransactionDelivery(
        _ delivery: PendingNewTransactionDelivery,
        budgetID: String
    ) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await PendingNewTransactionSQL.acknowledgePendingNewTransactionDelivery(delivery.transactionIDs, in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    func suppressPendingNewTransactionDeliveries(budgetID: String) async throws {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await PendingNewTransactionSQL.suppressPendingNewTransactionDeliveries(in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    func reviewPendingNewTransactions(
        budgetID: String,
        accountID: String?,
        transactionIDs: Set<String>,
        projection: [String: [String]]
    ) async throws -> (clearedCount: Int, projection: [String: [String]]) {
        let database = try store.requireDatabase(for: budgetID)
        let generation = store.budgetSessionGeneration
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        let prefix = pendingNewTransactionPrefix(budgetID: budgetID)
        let legacyByAccount = Self.accountScopedIDs(in: projection, prefix: prefix)
        let clearedCount = try await PendingNewTransactionSQL.migrateLegacyAndReviewPendingNewTransactions(
            legacyByAccount,
            transactionIDs: transactionIDs,
            accountID: accountID,
            in: database
        )
        let durable = try await PendingNewTransactionSQL.pendingNewTransactionIDsByAccount(in: database)
        try store.requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        return (
            clearedCount,
            replacingPendingNewTransactionProjection(
                projection,
                budgetID: budgetID,
                durableByAccount: durable
            )
        )
    }

    private func replacingPendingNewTransactionProjection(
        _ projection: [String: [String]],
        budgetID: String,
        durableByAccount: [String: [String]]
    ) -> [String: [String]] {
        let prefix = pendingNewTransactionPrefix(budgetID: budgetID)
        var result = projection.filter { !$0.key.hasPrefix(prefix) }
        for (accountID, transactionIDs) in durableByAccount where !transactionIDs.isEmpty {
            result[prefix + accountID] = Array(Set(transactionIDs)).sorted()
        }
        return result
    }

    private func pendingNewTransactionPrefix(budgetID: String) -> String {
        "\(budgetID)|"
    }

    /// Entries stored under `<budgetID>|<accountID>`, keyed by account.
    private static func accountScopedIDs(
        in storage: [String: [String]],
        prefix: String
    ) -> [String: [String]] {
        storage.reduce(into: [String: [String]]()) { result, entry in
            guard entry.key.hasPrefix(prefix) else { return }
            result[String(entry.key.dropFirst(prefix.count))] = entry.value
        }
    }
}

extension PendingTransactionWorkflows: BackgroundPendingTransactionPersisting {}
