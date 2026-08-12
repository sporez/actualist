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

    @MainActor
    func deletePayeesAndRefresh(budgetID: String, payeeIDs: Set<String>) async throws

    @MainActor
    func updatePayeesAndRefresh(
        budgetID: String,
        updates: [PayeeManagementUpdate]
    ) async throws

    @MainActor
    func setGlobalCategoryLearningAndRefresh(budgetID: String, enabled: Bool) async throws

    @MainActor
    func undoLastPayeeMutationAndRefresh(budgetID: String) async throws
}

struct PayeeManagementUpdate: Hashable, Sendable {
    let payeeID: String
    let favorite: Bool?
    let learnCategories: Bool?

    init(payeeID: String, favorite: Bool? = nil, learnCategories: Bool? = nil) {
        self.payeeID = payeeID
        self.favorite = favorite
        self.learnCategories = learnCategories
    }
}

struct ManagedPayee: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let transferAccountID: String?
    let transferAccountName: String?
    let transactionCount: Int
    let ruleReferenceCount: Int
    let canDelete: Bool
    let favorite: Bool
    let learnCategories: Bool

    init(
        id: String,
        name: String,
        transferAccountID: String?,
        transferAccountName: String?,
        transactionCount: Int,
        ruleReferenceCount: Int,
        canDelete: Bool,
        favorite: Bool = false,
        learnCategories: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transferAccountID = transferAccountID
        self.transferAccountName = transferAccountName
        self.transactionCount = transactionCount
        self.ruleReferenceCount = ruleReferenceCount
        self.canDelete = canDelete
        self.favorite = favorite
        self.learnCategories = learnCategories
    }

    var isTransfer: Bool {
        transferAccountID != nil
    }

    var displayName: String {
        if isTransfer {
            return transferAccountName ?? name
        }
        return name
    }

    var isUnused: Bool {
        transactionCount == 0
    }
}

struct PayeeManagementSnapshot: Hashable, Sendable {
    let payees: [ManagedPayee]
    let supportsCreate: Bool
    let supportsRename: Bool
    let supportsMerge: Bool
    let supportsDelete: Bool
    let hasUnreadableRuleReferences: Bool
    let supportsFavorite: Bool
    let supportsCategoryLearning: Bool
    let globalCategoryLearningEnabled: Bool
    let canUndo: Bool

    init(
        payees: [ManagedPayee],
        supportsCreate: Bool,
        supportsRename: Bool,
        supportsMerge: Bool,
        supportsDelete: Bool,
        hasUnreadableRuleReferences: Bool,
        supportsFavorite: Bool = false,
        supportsCategoryLearning: Bool = false,
        globalCategoryLearningEnabled: Bool = true,
        canUndo: Bool = false
    ) {
        self.payees = payees
        self.supportsCreate = supportsCreate
        self.supportsRename = supportsRename
        self.supportsMerge = supportsMerge
        self.supportsDelete = supportsDelete
        self.hasUnreadableRuleReferences = hasUnreadableRuleReferences
        self.supportsFavorite = supportsFavorite
        self.supportsCategoryLearning = supportsCategoryLearning
        self.globalCategoryLearningEnabled = globalCategoryLearningEnabled
        self.canUndo = canUndo
    }

    static let empty = PayeeManagementSnapshot(
        payees: [],
        supportsCreate: false,
        supportsRename: false,
        supportsMerge: false,
        supportsDelete: false,
        hasUnreadableRuleReferences: false,
        supportsFavorite: false,
        supportsCategoryLearning: false,
        globalCategoryLearningEnabled: true,
        canUndo: false
    )

    func settingCanUndo(_ canUndo: Bool) -> PayeeManagementSnapshot {
        PayeeManagementSnapshot(
            payees: payees,
            supportsCreate: supportsCreate,
            supportsRename: supportsRename,
            supportsMerge: supportsMerge,
            supportsDelete: supportsDelete,
            hasUnreadableRuleReferences: hasUnreadableRuleReferences,
            supportsFavorite: supportsFavorite,
            supportsCategoryLearning: supportsCategoryLearning,
            globalCategoryLearningEnabled: globalCategoryLearningEnabled,
            canUndo: canUndo
        )
    }
}
