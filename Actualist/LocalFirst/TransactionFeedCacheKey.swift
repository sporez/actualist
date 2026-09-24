import Foundation

enum TransactionFeedCacheScope: Hashable, Sendable {
    case account(String)
    case spending
}

struct TransactionFeedCacheKey: Hashable, Sendable {
    let budgetID: String
    let scope: TransactionFeedCacheScope
    let statusFilter: TransactionStatusFilter

    static func account(
        budgetID: String,
        accountID: String,
        statusFilter: TransactionStatusFilter = .all
    ) -> Self {
        Self(budgetID: budgetID, scope: .account(accountID), statusFilter: statusFilter)
    }

    static func spending(
        budgetID: String,
        statusFilter: TransactionStatusFilter = .all
    ) -> Self {
        Self(budgetID: budgetID, scope: .spending, statusFilter: statusFilter)
    }
}

typealias TransactionFeedPageReadHook = @MainActor @Sendable (
    TransactionFeedCacheKey,
    String?,
    Int?,
    Int
) async throws -> Void

struct TransactionFeedRequestIdentity: Sendable {
    struct Ticket: Hashable, Sendable {
        let sessionID: UUID
        let key: TransactionFeedCacheKey
        let revision: UInt64
    }

    private(set) var sessionID = UUID()
    private var nextRevision: UInt64 = 0
    private var latestRevisionByKey: [TransactionFeedCacheKey: UInt64] = [:]

    mutating func begin(for key: TransactionFeedCacheKey) -> Ticket {
        nextRevision &+= 1
        latestRevisionByKey[key] = nextRevision
        return Ticket(sessionID: sessionID, key: key, revision: nextRevision)
    }

    func accepts(_ ticket: Ticket) -> Bool {
        ticket.sessionID == sessionID && latestRevisionByKey[ticket.key] == ticket.revision
    }

    func accepts(_ tickets: [Ticket]) -> Bool {
        tickets.allSatisfy(accepts)
    }

    func keys(forBudget budgetID: String) -> Set<TransactionFeedCacheKey> {
        Set(latestRevisionByKey.keys.filter { $0.budgetID == budgetID })
    }

    mutating func resetSession() {
        sessionID = UUID()
        nextRevision = 0
        latestRevisionByKey = [:]
    }
}
