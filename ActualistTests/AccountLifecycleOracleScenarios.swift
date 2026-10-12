import Foundation
@testable import Actualist

/// Production replays for the 16 oracle cases Actualist supports. The six oracle-only cases are
/// listed in the manifest with reasons.
enum AccountLifecycleScenarios {
    static let now = Date(timeIntervalSince1970: 1_790_510_400)
    static let localDay = AccountLifecycleDay(isoDate: "2026-09-27", transactionDate: 20260927)
    static let transferIDs = AccountClosingTransferIDs(source: "id2", destination: "id3")

    static let replayedCaseIDs = [
        "rename-open-history",
        "rename-closed",
        "rename-handler-input-boundary",
        "reopen-repeat-history",
        "close-empty-history",
        "close-zero",
        "close-positive-on-to-on-history",
        "close-negative-on-to-on",
        "close-on-to-off-hidden-category",
        "close-off-to-on",
        "close-off-to-off",
        "close-self-transfer-refusal",
        "close-split-balance",
        "unlink-simplefin",
        "close-unlink-undo-boundary",
        "schedule-close-reopen-eligibility",
    ]

    static func replay(_ caseID: String) async throws -> [String: OracleValue] {
        let permit = await OracleReplayGate.shared.acquire()
        defer { permit.release() }
        switch caseID {
        case "rename-open-history":
            return try await renameOpenHistory()
        case "rename-closed":
            return try await renameClosed()
        case "rename-handler-input-boundary":
            return try await renameHandlerInputBoundary()
        case "reopen-repeat-history":
            return try await reopenRepeatHistory()
        case "close-empty-history":
            return try await closeEmptyHistory()
        case "close-zero":
            return try await closeZero()
        case "close-positive-on-to-on-history":
            return try await transferClose(balance: 4250, sourceOffBudget: false, destinationOffBudget: false)
        case "close-negative-on-to-on":
            return try await transferClose(balance: -2300, sourceOffBudget: false, destinationOffBudget: false)
        case "close-on-to-off-hidden-category":
            return try await transferClose(
                balance: 3100,
                sourceOffBudget: false,
                destinationOffBudget: true,
                destinationSortOrder: 16384,
                category: "hidden-category"
            )
        case "close-off-to-on":
            return try await transferClose(
                balance: 1700,
                sourceOffBudget: true,
                destinationOffBudget: false,
                destinationSortOrder: 16384
            )
        case "close-off-to-off":
            return try await transferClose(balance: 900, sourceOffBudget: true, destinationOffBudget: true)
        case "close-self-transfer-refusal":
            return try await closeSelfTransferRefusal()
        case "close-split-balance":
            return try await closeSplitBalance()
        case "unlink-simplefin":
            return try await unlinkSimpleFIN()
        case "close-unlink-undo-boundary":
            return try await closeUnlinkUndoBoundary()
        case "schedule-close-reopen-eligibility":
            return try await scheduleCloseReopenEligibility()
        default:
            throw AccountLifecycleOracleError.unknownCase(caseID)
        }
    }

    private static func renameOpenHistory() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Before"),
            ReplaySQL.payee("source"),
        ].joined())
        try await budget.rename("source", from: "Before", to: "After")
        let messages = try await budget.capturedMessages()
        let after = try budget.record("accounts", id: "source")
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "afterOperation": after,
        ]
    }

    private static func renameClosed() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Closed before", closed: true),
            ReplaySQL.payee("source"),
        ].joined())
        let before = try budget.record("accounts", id: "source")
        try await budget.rename("source", from: "Closed before", to: "Closed after")
        let messages = try await budget.capturedMessages()
        let after = try budget.record("accounts", id: "source")
        return [
            "before": before,
            "operationMessages": ReplayNormalizer.messages(messages),
            "after": after,
        ]
    }

    /// Submits each name against the current name, as the rename sheet does.
    private static func renameHandlerInputBoundary() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Original"),
            ReplaySQL.account("peer", name: "Duplicate", sortOrder: 32768),
            ReplaySQL.payee("source"),
            ReplaySQL.payee("peer"),
        ].joined())
        var messages: [ActualSyncDecodedMessage] = []
        for submitted in ["Original", "  Original  ", "Duplicate", "duplicate"] {
            let current = try budget.accountName("source")
            try await budget.rename("source", from: current, to: submitted)
            messages += try await budget.capturedMessages()
        }
        let after = try budget.snapshot()
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "after": after,
        ]
    }

    private static func reopenRepeatHistory() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Closed", closed: true),
            ReplaySQL.payee("source"),
        ].joined())
        try await budget.reopen("source")
        let firstMessages = try await budget.capturedMessages()
        try await budget.reopen("source")
        let repeatMessages = try await budget.capturedMessages()
        let afterRepeat = try budget.record("accounts", id: "source")
        return [
            "firstMessages": ReplayNormalizer.messages(firstMessages),
            // The oracle records the messages of both calls under this key.
            "repeatMessages": ReplayNormalizer.messages(firstMessages + repeatMessages),
            "afterRepeat": afterRepeat,
        ]
    }

    private static func closeEmptyHistory() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Empty"),
            ReplaySQL.payee("source"),
        ].joined())
        try await budget.close("source", destination: nil)
        let messages = try await budget.capturedMessages()
        let afterOperation = try budget.snapshot()
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "afterOperation": afterOperation,
        ]
    }

    private static func closeZero() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Zero"),
            ReplaySQL.transaction("zero-row", acct: "source", amount: 0),
            ReplaySQL.payee("source"),
        ].joined())
        try await budget.close("source", destination: nil)
        let messages = try await budget.capturedMessages()
        let after = try budget.snapshot()
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "after": after,
        ]
    }

    /// Closes `source` into `destination` with the balance held in `opening-row`. The injected
    /// transfer IDs are `id2` on the source and `id3` on the destination.
    private static func transferClose(
        balance: Int,
        sourceOffBudget: Bool,
        destinationOffBudget: Bool,
        destinationSortOrder: Int = 32768,
        category: String? = nil
    ) async throws -> [String: OracleValue] {
        var seeds = [
            ReplaySQL.account("source", name: "Synthetic source", offBudget: sourceOffBudget),
            ReplaySQL.account(
                "destination",
                name: "Synthetic destination",
                offBudget: destinationOffBudget,
                sortOrder: destinationSortOrder
            ),
            ReplaySQL.payee("source"),
            ReplaySQL.payee("destination"),
            ReplaySQL.transaction("opening-row", acct: "source", amount: balance),
        ]
        if category != nil {
            seeds.append(ReplaySQL.hiddenCategory)
        }
        let budget = try AccountLifecycleReplayBudget(seeds: seeds.joined())
        try await budget.close("source", destination: "destination", category: category)
        let messages = try await budget.capturedMessages()
        let afterOperation = try budget.snapshot()
        let sourceTransaction = try budget.record("transactions", id: "id2")
        let destinationTransaction = try budget.record("transactions", id: "id3")
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "afterOperation": afterOperation,
            "sourceTransaction": sourceTransaction,
            "destinationTransaction": destinationTransaction,
        ]
    }

    /// A blocked review is not committable, so no write happens.
    private static func closeSelfTransferRefusal() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Self"),
            ReplaySQL.payee("source"),
            ReplaySQL.transaction("balance-row", acct: "source", amount: 500),
        ].joined())
        let before = try budget.snapshot()
        try await budget.close("source", destination: "source")
        let messages = try await budget.capturedMessages()
        let after = try budget.snapshot()
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "before": before,
            "after": after,
        ]
    }

    /// The split parent is excluded from the balance; its children and the ordinary row are included.
    private static func closeSplitBalance() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Split source"),
            ReplaySQL.account("destination", name: "Split destination", sortOrder: 32768),
            ReplaySQL.payee("source"),
            ReplaySQL.payee("destination"),
            ReplaySQL.transaction("split-parent", acct: "source", amount: 1000, isParent: true),
            ReplaySQL.transaction("split-child-a", acct: "source", amount: 400, parentID: "split-parent", isChild: true),
            ReplaySQL.transaction("split-child-b", acct: "source", amount: 600, parentID: "split-parent", isChild: true),
            ReplaySQL.transaction("ordinary-row", acct: "source", amount: 300),
        ].joined())
        try await budget.close("source", destination: "destination")
        let messages = try await budget.capturedMessages()
        let after = try budget.snapshot()
        let sourceClosingRow = try budget.record("transactions", id: "id2")
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "after": after,
            "sourceClosingRow": sourceClosingRow,
        ]
    }

    private static func unlinkSimpleFIN() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.bank,
            ReplaySQL.account("source", name: "SimpleFIN", bankLinked: true),
            ReplaySQL.payee("source"),
        ].joined())
        try await budget.unlinkBankAccount("source")
        let messages = try await budget.capturedMessages()
        let after = try budget.record("accounts", id: "source")
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
            "after": after,
        ]
    }

    private static func closeUnlinkUndoBoundary() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.bank,
            ReplaySQL.account("source", name: "Synthetic source", bankLinked: true),
            ReplaySQL.transaction("zero-row", acct: "source", amount: 0),
            ReplaySQL.payee("source"),
        ].joined())
        try await budget.close("source", destination: nil)
        let messages = try await budget.capturedMessages()
        return [
            "operationMessages": ReplayNormalizer.messages(messages),
        ]
    }

    /// Clears the day marker before each forced run, so a run on the same fixed day is not skipped.
    private static func scheduleCloseReopenEligibility() async throws -> [String: OracleValue] {
        let budget = try AccountLifecycleReplayBudget(seeds: [
            ReplaySQL.account("source", name: "Synthetic source"),
            ReplaySQL.transaction("zero-row", acct: "source", amount: 0),
            ReplaySQL.payee("source"),
            ReplaySQL.scheduleSeeds,
        ].joined())

        let before = try budget.scheduleSnapshot()
        try await budget.close("source", destination: nil)
        let closeMessages = try await budget.capturedMessages()
        let afterClose = try budget.scheduleSnapshot()

        try await budget.advanceSchedules()
        let closedServiceMessages = try await budget.capturedMessages()
        let closedScheduledTransactions = try budget.rows(
            "transactions",
            where: " WHERE schedule = 'schedule-source'"
        )

        try await budget.reopen("source")
        let reopenMessages = try await budget.capturedMessages()
        let afterReopen = try budget.scheduleSnapshot()

        try await budget.advanceSchedules()
        let openServiceMessages = try await budget.capturedMessages()
        let aliases = try budget.scheduledTransactionAliases()
        let openScheduledTransactions = try budget.rows(
            "transactions",
            where: " WHERE schedule = 'schedule-source'",
            aliases: aliases
        )

        return [
            "before": before,
            "closeMessages": ReplayNormalizer.messages(closeMessages),
            "afterClose": afterClose,
            "closedServiceMessages": ReplayNormalizer.messages(closedServiceMessages),
            "closedScheduledTransactions": .array(closedScheduledTransactions),
            "reopenMessages": ReplayNormalizer.messages(reopenMessages),
            "afterReopen": afterReopen,
            "openServiceMessages": ReplayNormalizer.messages(openServiceMessages, aliases: aliases),
            "openScheduledTransactions": .array(openScheduledTransactions),
        ]
    }
}

extension AccountLifecycleReplayBudget {
    func rename(_ accountID: String, from current: String, to newName: String) async throws {
        _ = try await database.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(accountID: accountID, expectedCurrentName: current, newName: newName)),
            now: AccountLifecycleScenarios.now
        )
    }

    func reopen(_ accountID: String) async throws {
        _ = try await database.commitAccountLifecycleMutation(
            .reopen(AccountReopenCommand(accountID: accountID, expectedClosed: true)),
            now: AccountLifecycleScenarios.now
        )
    }

    /// Reviews first, as the close sheet does. A blocked review is not committed.
    func close(_ accountID: String, destination: String?, category: String? = nil) async throws {
        let review = try await database.accountLifecycleReview(
            request: AccountLifecycleReviewRequest(
                budgetID: Self.budgetID,
                accountID: accountID,
                requestedAction: .close(destinationAccountID: destination, categoryID: category)
            ),
            localDay: AccountLifecycleScenarios.localDay
        )
        guard review.blockers.isEmpty else { return }
        _ = try await database.commitAccountLifecycleReview(
            review,
            now: AccountLifecycleScenarios.now,
            localDay: { AccountLifecycleScenarios.localDay },
            transferIDs: AccountLifecycleScenarios.transferIDs
        )
    }

    func unlinkBankAccount(_ accountID: String) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await database.makeBankSyncUnlinkMessages(accountID: accountID, builder: &builder)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(drafts, now: AccountLifecycleScenarios.now)
    }

    func advanceSchedules() async throws {
        try clearScheduleDayMarker()
        _ = try await database.advanceSchedules(
            budgetID: Self.budgetID,
            today: AccountLifecycleScenarios.localDay.isoDate,
            now: AccountLifecycleScenarios.now
        )
    }
}
