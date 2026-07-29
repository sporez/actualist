import Foundation

protocol PayeeRepositoryProtocol: Sendable {
    @MainActor
    func cachedPayeeManagementSnapshot(budgetID: String) -> PayeeManagementSnapshot?

    @MainActor
    func refreshPayeeManagementSnapshot(budgetID: String) async throws

    @MainActor
    func createPayeeAndRefresh(budgetID: String, name: String) async throws

    @MainActor
    func renamePayeeAndRefresh(budgetID: String, payeeID: String, name: String) async throws

    @MainActor
    func mergePayeesAndRefresh(
        budgetID: String,
        sourcePayeeIDs: Set<String>,
        targetPayeeID: String
    ) async throws

    @MainActor
    func deletePayeeAndRefresh(budgetID: String, payeeID: String) async throws
}

struct ManagedPayee: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let transferAccountID: String?
    let transferAccountName: String?
    let transactionCount: Int
    let ruleReferenceCount: Int
    let canDelete: Bool

    var isTransfer: Bool {
        transferAccountID != nil
    }

    var displayName: String {
        if isTransfer {
            return transferAccountName ?? name
        }
        return name
    }
}

struct PayeeManagementSnapshot: Hashable, Sendable {
    let payees: [ManagedPayee]
    let supportsCreate: Bool
    let supportsRename: Bool
    let supportsMerge: Bool
    let supportsDelete: Bool
    let hasUnreadableRuleReferences: Bool

    static let empty = PayeeManagementSnapshot(
        payees: [],
        supportsCreate: false,
        supportsRename: false,
        supportsMerge: false,
        supportsDelete: false,
        hasUnreadableRuleReferences: false
    )
}
