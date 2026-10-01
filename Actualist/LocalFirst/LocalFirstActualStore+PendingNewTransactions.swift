import Foundation

extension LocalFirstActualStore {
    struct PendingNewTransactionDelivery: Equatable, Sendable {
        let requestIdentifier: String
        let transactionIDs: [String]
    }

    func reconcilePendingNewTransactionProjection(
        budgetID: String,
        legacyStorage: [String: [String]]
    ) async throws -> [String: [String]] {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let prefix = pendingNewTransactionPrefix(budgetID: budgetID)
        let legacyByAccount = legacyStorage.reduce(into: [String: [String]]()) { result, entry in
            guard entry.key.hasPrefix(prefix) else { return }
            result[String(entry.key.dropFirst(prefix.count))] = entry.value
        }
        try await database.migrateLegacyPendingNewTransactions(legacyByAccount)
        let durable = try await database.pendingNewTransactionIDsByAccount()
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
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
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: Dictionary(
                pending.map { ($0.accountID, $0.transactionIDs) },
                uniquingKeysWith: { $0 + $1 }
            ),
            source: .remoteSync,
            notificationID: notificationID
        ))
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    func pendingNewTransactionDelivery(
        budgetID: String
    ) async throws -> PendingNewTransactionDelivery? {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        let delivery = try await database.pendingNewTransactionDelivery()
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
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
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await database.acknowledgePendingNewTransactionDelivery(delivery.transactionIDs)
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    func suppressPendingNewTransactionDeliveries(budgetID: String) async throws {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        try await database.suppressPendingNewTransactionDeliveries()
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
    }

    func reviewPendingNewTransactions(
        budgetID: String,
        accountID: String?,
        transactionIDs: Set<String>,
        projection: [String: [String]]
    ) async throws -> (clearedCount: Int, projection: [String: [String]]) {
        let database = try requireDatabase(for: budgetID)
        let generation = budgetSessionGeneration
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
        let prefix = pendingNewTransactionPrefix(budgetID: budgetID)
        let legacyByAccount = projection.reduce(into: [String: [String]]()) { result, entry in
            guard entry.key.hasPrefix(prefix) else { return }
            result[String(entry.key.dropFirst(prefix.count))] = entry.value
        }
        let clearedCount = try await database.migrateLegacyAndReviewPendingNewTransactions(
            legacyByAccount,
            transactionIDs: transactionIDs,
            accountID: accountID
        )
        let durable = try await database.pendingNewTransactionIDsByAccount()
        try requireSyncSession(database: database, budgetID: budgetID, generation: generation)
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
}

extension LocalFirstActualStore: BackgroundPendingTransactionPersisting {}
