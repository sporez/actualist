import Foundation

struct AccountLifecycleAccount: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let offBudget: Bool
    let isClosed: Bool
    let accountGroupID: String?
}

struct AccountLifecycleIdentity: Hashable, Sendable {
    let budgetID: String
    let accountID: String
}

struct AccountRenameCommand: Hashable, Sendable {
    let accountID: String
    let expectedCurrentName: String
    let newName: String

    func normalized() throws -> Self {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw AccountLifecycleCommandError.accountNotFound
        }
        guard !newName.isEmpty else {
            throw AccountLifecycleCommandError.blankName
        }
        return Self(
            accountID: accountID,
            expectedCurrentName: expectedCurrentName,
            newName: newName
        )
    }
}

struct AccountReopenCommand: Hashable, Sendable {
    let accountID: String
    let expectedClosed: Bool

    func normalized() throws -> Self {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw AccountLifecycleCommandError.accountNotFound
        }
        return Self(accountID: accountID, expectedClosed: expectedClosed)
    }
}

enum AccountLifecycleMutationPrecondition: Hashable, Sendable {
    case rename(AccountRenameCommand)
    case reopen(AccountReopenCommand)
}

enum AccountLifecycleOperation: String, Codable, Hashable, Sendable {
    case rename
    case reopen
    case close
    case delete
}

struct AccountLifecycleDay: Hashable, Sendable {
    let isoDate: String
    let transactionDate: Int

    static func localGregorian(
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return Self(
            isoDate: String(format: "%04d-%02d-%02d", year, month, day),
            transactionDate: year * 10_000 + month * 100 + day
        )
    }
}

struct AccountLifecycleOutcome: Hashable, Sendable {
    let operation: AccountLifecycleOperation
    let account: AccountLifecycleAccount
    var refreshPending = false
}

enum AccountLifecycleCommitResult: Hashable, Sendable {
    case applied(AccountLifecycleOutcome)
    case reviewChanged(AccountLifecycleReview)
    case noChange(AccountLifecycleOutcome)
}

enum AccountLifecycleCommandError: Error, Hashable, Sendable {
    case accountNotFound
    case blankName
    case duplicateName(String)
    case reviewChanged
    case missingAccountSchema
    case missingTransactionSchema
    case invalidPreparedMutation
}

extension AccountLifecycleCommandError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            "This account is no longer available."
        case .blankName:
            "Enter an account name."
        case .duplicateName(let name):
            "An account named \(name) already exists."
        case .reviewChanged:
            "This account changed. Review its latest details and try again."
        case .missingAccountSchema, .missingTransactionSchema:
            "Account maintenance is not available for this budget file."
        case .invalidPreparedMutation:
            "The account change could not be validated."
        }
    }
}

struct AccountRenameDraft: Hashable, Sendable {
    let identity: AccountLifecycleIdentity
    let account: AccountLifecycleAccount
    let existingAccounts: [AccountLifecycleAccount]
    var name: String
    var validationMessage: String?

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSubmit: Bool {
        validationError == nil && normalizedName != account.name
    }

    var command: AccountRenameCommand? {
        guard validationError == nil else { return nil }
        return AccountRenameCommand(
            accountID: account.id,
            expectedCurrentName: account.name,
            newName: normalizedName
        )
    }

    var validationError: AccountLifecycleCommandError? {
        guard !normalizedName.isEmpty else { return .blankName }
        if existingAccounts.contains(where: {
            $0.id != account.id && $0.name == normalizedName
        }) {
            return .duplicateName(normalizedName)
        }
        return nil
    }
}

struct AccountReopenSession: Hashable, Sendable {
    let identity: AccountLifecycleIdentity
    let account: AccountLifecycleAccount

    var command: AccountReopenCommand {
        AccountReopenCommand(accountID: account.id, expectedClosed: true)
    }
}

enum AccountLifecycleRequestedAction: Hashable, Sendable {
    case close(destinationAccountID: String?, categoryID: String?)
}

struct AccountLifecycleReviewRequest: Hashable, Sendable {
    let budgetID: String
    let accountID: String
    let requestedAction: AccountLifecycleRequestedAction
}

struct AccountLifecycleDestination: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let offBudget: Bool
}

struct AccountLifecycleCategory: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isHidden: Bool
}

enum AccountLifecycleBankProvider: String, Hashable, Sendable {
    case simpleFIN
    case goCardless
    case pluggyAI
    case akahu
    case enableBanking
    case unknown
}

struct AccountLifecycleBankLinkIdentity: Hashable, Sendable {
    let remoteAccountID: String?
    let syncSource: String?
    let bankRowID: String?
}

struct AccountLifecycleBankLink: Hashable, Sendable {
    let provider: AccountLifecycleBankProvider
    let identity: AccountLifecycleBankLinkIdentity
}

struct AccountScheduleReference: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct AccountLifecycleSourceFacts: Hashable, Sendable {
    let account: AccountLifecycleAccount
    let liveBalance: Int
    let liveTransactionCount: Int
    let liveFamilyCount: Int
    let pairedTransferCount: Int
}

struct AccountLifecycleDestinationFacts: Hashable, Sendable {
    let account: AccountLifecycleDestination
}

struct AccountLifecycleCategoryFacts: Hashable, Sendable {
    let category: AccountLifecycleCategory
}

struct AccountLifecycleReviewIdentity: Hashable, Sendable {
    let budgetID: String
    let accountID: String
    let action: AccountLifecycleRequestedAction
    let localDay: AccountLifecycleDay
    let sourceFacts: AccountLifecycleSourceFacts
    let destinationFacts: AccountLifecycleDestinationFacts?
    let categoryFacts: AccountLifecycleCategoryFacts?
    let transactionGraphDigest: String
    let scheduleDigest: String
    let bankLinkIdentity: AccountLifecycleBankLinkIdentity?
}

struct AccountClosingTransfer: Hashable, Sendable {
    let destinationAccountID: String
    let sourceAmount: Int
    let destinationAmount: Int
    let categoryID: String?
    let date: String
    let notes: String
}

enum AccountLifecycleResolvedAction: Hashable, Sendable {
    case deleteEmptyAccount
    case closeAtZero
    case closeWithTransfer(AccountClosingTransfer)
}

enum AccountLifecycleBlocker: Hashable, Sendable {
    case accountAlreadyClosed
    case destinationRequired
    case destinationIsSource
    case destinationUnavailable
    case categoryRequired
    case categoryUnavailable
    case unsupportedBankProvider(AccountLifecycleBankProvider)
    case scheduleInspectionUnavailable
}

struct AccountLifecycleReview: Hashable, Sendable {
    let identity: AccountLifecycleReviewIdentity
    let account: AccountLifecycleAccount
    let liveBalance: Int
    let liveTransactionCount: Int
    let liveFamilyCount: Int
    let pairedTransferCount: Int
    let bankLink: AccountLifecycleBankLink?
    let activeScheduleReferences: [AccountScheduleReference]
    let eligibleDestinations: [AccountLifecycleDestination]
    let eligibleCategories: [AccountLifecycleCategory]
    let resolvedAction: AccountLifecycleResolvedAction?
    let blockers: [AccountLifecycleBlocker]
}

enum AccountPostingEligibility: Hashable, Sendable {
    case eligible(AccountLifecycleAccount)
    case closed(AccountLifecycleAccount)
    case missing(accountID: String)
}

struct AccountEligibilitySnapshot: Hashable, Sendable {
    let accounts: [AccountLifecycleAccount]

    func postingEligibility(accountID: String) -> AccountPostingEligibility {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            return .missing(accountID: accountID)
        }
        return account.isClosed ? .closed(account) : .eligible(account)
    }

    var eligiblePostingAccounts: [AccountLifecycleAccount] {
        accounts.filter { !$0.isClosed }
    }
}
