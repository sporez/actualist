import Foundation
@testable import Actualist

/// Production replays for the 20 oracle cases Actualist supports. The six oracle-only cases are
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
        "link-simplefin-new-bank",
        "link-simplefin-existing-bank",
        "link-simplefin-same-domain-other-name",
        "link-simplefin-no-institution-or-domain",
        "unlink-simplefin",
        "close-unlink-undo-boundary",
        "schedule-close-reopen-eligibility",
    ]

    /// Oracle message lists a replay deliberately leaves out. A link's `operationMessages` include
    /// the mocked first download's `last_sync` and `bank_sync_status`; its `linkMessages` are compared.
    static let messageKeysNotReplayed: [String: Set<String>] = Dictionary(
        uniqueKeysWithValues: [
            "link-simplefin-new-bank",
            "link-simplefin-existing-bank",
            "link-simplefin-same-domain-other-name",
            "link-simplefin-no-institution-or-domain",
        ].map { ($0, ["operationMessages"]) }
    )

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
        case "link-simplefin-new-bank":
            return try await linkSimpleFIN()
        case "link-simplefin-existing-bank":
            return try await linkSimpleFIN(existingBank: (bankID: "synthetic.example", name: "Synthetic Bank"))
        case "link-simplefin-same-domain-other-name":
            return try await linkSimpleFIN(existingBank: (bankID: "synthetic.example", name: "Other Bank"))
        case "link-simplefin-no-institution-or-domain":
            return try await linkSimpleFIN(institution: nil, orgDomain: nil)
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

    /// The account cells a link writes. The oracle's mocked first download also writes `last_sync`
    /// and `bank_sync_status`; Actualist links without downloading, so those are not compared.
    private static let linkColumns: Set<String> = ["account_id", "bank", "account_sync_source"]

    /// Links the unlinked account `source`. Actual's `institution` is SimpleFIN's `org.name`, which
    /// Actualist decodes as `orgName`. An existing bank is seeded with a stored message, as the
    /// oracle seeds it through `insertWithUUID`. The bank a link creates is aliased to the oracle's `id2`.
    private static func linkSimpleFIN(
        existingBank: (bankID: String, name: String)? = nil,
        institution: String? = "Synthetic Bank",
        orgDomain: String? = "synthetic.example"
    ) async throws -> [String: OracleValue] {
        var seeds = [
            ReplaySQL.account("source", name: "Synthetic source"),
            ReplaySQL.payee("source"),
        ]
        if let existingBank {
            seeds.append(ReplaySQL.syncedBank(id: "bank-existing", bankID: existingBank.bankID, name: existingBank.name))
        }
        let budget = try AccountLifecycleReplayBudget(seeds: seeds.joined())
        let remote = SimpleFINRemoteAccount(
            accountID: "remote-account-simplefin",
            name: "Synthetic checking",
            balance: "0.00",
            currency: "USD",
            institution: nil,
            orgName: institution,
            orgDomain: orgDomain,
            orgID: "org-synthetic"
        )
        try await budget.linkBankAccount("source", to: remote)
        let messages = try await budget.capturedMessages()
        let minted = Set(messages.filter { $0.dataset == "banks" }.map(\.row)).subtracting(["bank-existing"])
        let aliases = Dictionary(uniqueKeysWithValues: minted.map { ($0, "id2") })
        let linkMessages = messages
            .filter { $0.dataset == "banks" || ($0.dataset == "accounts" && linkColumns.contains($0.column)) }
            .map { message in
                ActualSyncDecodedMessage(
                    timestamp: message.timestamp,
                    dataset: message.dataset,
                    row: aliases[message.row] ?? message.row,
                    column: message.column,
                    serializedValue: aliases.first { "S:\($0.key)" == message.serializedValue }
                        .map { "S:\($0.value)" } ?? message.serializedValue
                )
            }
        guard case .object(let account) = try budget.record("accounts", id: "source") else {
            throw AccountLifecycleOracleError.malformedReplay("link: account source")
        }
        var accountLink = account.filter { linkColumns.contains($0.key) }
        if case .string(let bank)? = accountLink["bank"], let alias = aliases[bank] {
            accountLink["bank"] = .string(alias)
        }
        return [
            "linkMessages": ReplayNormalizer.messages(linkMessages),
            "bankRows": .array(try budget.rows("banks", aliases: aliases)),
            "accountLink": .object(accountLink),
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
        _ = try await AccountLifecycleCommitSQL.commitAccountLifecycleMutation(
            .rename(AccountRenameCommand(accountID: accountID, expectedCurrentName: current, newName: newName)),
            now: AccountLifecycleScenarios.now,
            in: database
        )
    }

    func reopen(_ accountID: String) async throws {
        _ = try await AccountLifecycleCommitSQL.commitAccountLifecycleMutation(
            .reopen(AccountReopenCommand(accountID: accountID, expectedClosed: true)),
            now: AccountLifecycleScenarios.now,
            in: database
        )
    }

    /// Reviews first, as the close sheet does. A blocked review is not committed.
    func close(_ accountID: String, destination: String?, category: String? = nil) async throws {
        let review = try await AccountLifecycleReviewSQL.accountLifecycleReview(
            request: AccountLifecycleReviewRequest(
                budgetID: Self.budgetID,
                accountID: accountID,
                requestedAction: .close(destinationAccountID: destination, categoryID: category)
            ),
            localDay: AccountLifecycleScenarios.localDay,
            in: database
        )
        guard review.blockers.isEmpty else { return }
        _ = try await AccountLifecycleCommitSQL.commitAccountLifecycleReview(
            review,
            now: AccountLifecycleScenarios.now,
            localDay: { AccountLifecycleScenarios.localDay },
            transferIDs: AccountLifecycleScenarios.transferIDs,
            in: database
        )
    }

    /// `BankSyncWorkflows.linkBankAccount` without the store: build the link messages, then commit them.
    func linkBankAccount(_ accountID: String, to remote: SimpleFINRemoteAccount) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await BankSyncLinkSQL.makeBankSyncLinkMessages(
            accountID: accountID, remote: remote, builder: &builder, in: database
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(drafts, now: AccountLifecycleScenarios.now)
    }

    func unlinkBankAccount(_ accountID: String) async throws {
        var builder = LocalFirstSyncMessageBuilder()
        let drafts = try await BankSyncLinkSQL.makeBankSyncUnlinkMessages(accountID: accountID, builder: &builder, in: database)
        _ = try await database.commitLocalSyncMessagesAndEnqueue(drafts, now: AccountLifecycleScenarios.now)
    }

    func advanceSchedules() async throws {
        try clearScheduleDayMarker()
        _ = try await SchedulePostingSQL.advanceSchedules(
            budgetID: Self.budgetID,
            today: AccountLifecycleScenarios.localDay.isoDate,
            now: AccountLifecycleScenarios.now,
            in: database
        )
    }
}
