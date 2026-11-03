import Foundation
import Testing
@testable import Actualist

@MainActor
private final class FakeWalletAccountLinks: WalletAccountLinkStoring {
    var linksByBudget: [String: [String: String]] = [:]

    func walletAccountLinks(budgetID: String) -> [String: String] {
        linksByBudget[budgetID] ?? [:]
    }

    func setWalletAccountLink(_ accountID: String?, walletAccountID: String, budgetID: String) {
        var links = linksByBudget[budgetID] ?? [:]
        links[walletAccountID] = accountID
        linksByBudget[budgetID] = links
    }
}

@Suite("Wallet import coordinator")
@MainActor
struct WalletImportCoordinatorTests {
    private func repository() -> UncategorizedRecordingTransactionRepository {
        UncategorizedRecordingTransactionRepository(
            loaded: LoadedUncategorizedTransactions(
                transactions: [],
                accountNames: [:],
                categoryNames: [:],
                payeeNames: [:],
                transferPayeeIDs: [],
                categoryGroups: []
            )
        )
    }

    private func field(_ index: Int, wallet: String, status: WalletTransactionStatus = .booked) -> WalletTransactionFields {
        WalletTransactionFields(
            id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!,
            amount: Decimal(index),
            creditDebitIndicator: .debit,
            merchantName: "Merchant \(index)",
            transactionDescription: "Merchant \(index)",
            transactionDate: Date(timeIntervalSince1970: 1_792_000_000),
            status: status,
            walletAccountID: wallet
        )
    }

    private func begin(
        _ coordinator: WalletImportCoordinator,
        _ fields: [WalletTransactionFields],
        links: FakeWalletAccountLinks,
        repository: UncategorizedRecordingTransactionRepository,
        openAccountIDs: [String] = ["checking", "card"],
        defaultAccountID: String? = "card"
    ) async {
        await coordinator.begin(
            fields,
            currency: .usd,
            budgetID: "budget",
            openAccountIDs: openAccountIDs,
            defaultAccountID: defaultAccountID,
            links: links,
            repository: repository
        )
    }

    @Test func aLinkedWalletAccountImportsWithoutAsking() async {
        let links = FakeWalletAccountLinks()
        links.linksByBudget["budget"] = ["wallet-a": "checking"]
        let repository = repository()
        var calls: [(Int, String)] = []
        repository.importWalletTransactionsHook = { candidates, accountID in
            calls.append((candidates.count, accountID))
            return WalletTransactionImportResult(addedCount: 1, matchedCount: 1)
        }
        let coordinator = WalletImportCoordinator()

        await begin(coordinator, [field(1, wallet: "wallet-a"), field(2, wallet: "wallet-a")], links: links, repository: repository)

        #expect(calls.map(\.0) == [2])
        #expect(calls.map(\.1) == ["checking"])
        #expect(coordinator.state == .finished(WalletTransactionImportResult(addedCount: 1, matchedCount: 1)))
    }

    @Test func anUnlinkedWalletAccountAsksOnceThenRemembersTheAccount() async {
        let links = FakeWalletAccountLinks()
        let repository = repository()
        var accounts: [String] = []
        repository.importWalletTransactionsHook = { candidates, accountID in
            accounts.append(accountID)
            return WalletTransactionImportResult(addedCount: candidates.count, matchedCount: 0)
        }
        let coordinator = WalletImportCoordinator()

        await begin(coordinator, [field(1, wallet: "wallet-a")], links: links, repository: repository)
        #expect(coordinator.state == .needsAccount(.init(
            walletAccountID: "wallet-a", transactionCount: 1, selectedAccountID: "card"
        )))
        #expect(accounts.isEmpty)

        coordinator.selectAccount("checking")
        await coordinator.confirmAccount(links: links, repository: repository)

        #expect(accounts == ["checking"])
        #expect(links.linksByBudget["budget"] == ["wallet-a": "checking"])
        #expect(coordinator.state == .finished(WalletTransactionImportResult(addedCount: 1, matchedCount: 0)))

        await begin(coordinator, [field(2, wallet: "wallet-a")], links: links, repository: repository)
        #expect(accounts == ["checking", "checking"])
        #expect(!coordinator.isAskingForAccount)
    }

    @Test func aLinkToAClosedAccountAsksAgain() async {
        let links = FakeWalletAccountLinks()
        links.linksByBudget["budget"] = ["wallet-a": "closed-account"]
        let repository = repository()
        repository.importWalletTransactionsHook = { _, _ in
            Issue.record("must not import before an account is chosen")
            return .empty
        }
        let coordinator = WalletImportCoordinator()

        await begin(coordinator, [field(1, wallet: "wallet-a")], links: links, repository: repository)

        #expect(coordinator.isAskingForAccount)
    }

    @Test func twoWalletAccountsAskOnlyForTheUnlinkedOneAndSumTheResult() async {
        let links = FakeWalletAccountLinks()
        links.linksByBudget["budget"] = ["wallet-a": "checking"]
        let repository = repository()
        var accounts: [String] = []
        repository.importWalletTransactionsHook = { candidates, accountID in
            accounts.append(accountID)
            return WalletTransactionImportResult(addedCount: candidates.count, matchedCount: 1, skippedCount: 0)
        }
        let coordinator = WalletImportCoordinator()

        await begin(
            coordinator,
            [field(1, wallet: "wallet-a"), field(2, wallet: "wallet-b"), field(3, wallet: "wallet-b")],
            links: links,
            repository: repository
        )
        #expect(coordinator.state == .needsAccount(.init(
            walletAccountID: "wallet-b", transactionCount: 2, selectedAccountID: "card"
        )))
        await coordinator.confirmAccount(links: links, repository: repository)

        #expect(accounts == ["checking", "card"])
        #expect(coordinator.state == .finished(WalletTransactionImportResult(addedCount: 3, matchedCount: 2)))
    }

    @Test func cancellingTheQuestionImportsNothingAndSavesNoLink() async {
        let links = FakeWalletAccountLinks()
        let repository = repository()
        repository.importWalletTransactionsHook = { _, _ in
            Issue.record("must not import after cancel")
            return .empty
        }
        let coordinator = WalletImportCoordinator()

        await begin(coordinator, [field(1, wallet: "wallet-a")], links: links, repository: repository)
        coordinator.cancel()
        await coordinator.confirmAccount(links: links, repository: repository)

        #expect(coordinator.state == .idle)
        #expect(links.linksByBudget.isEmpty)
    }

    @Test func aLaterSelectionDropsAnOlderRunsLateResult() async {
        let links = FakeWalletAccountLinks()
        links.linksByBudget["budget"] = ["wallet-a": "checking"]
        let repository = repository()
        let entered = TestLatch()
        let release = TestLatch()
        repository.importWalletTransactionsHook = { candidates, _ in
            if candidates.first?.payeeName == "Merchant 1" {
                entered.trip()
                await release.wait()
                return WalletTransactionImportResult(addedCount: 9, matchedCount: 9)
            }
            return WalletTransactionImportResult(addedCount: 1, matchedCount: 0)
        }
        let coordinator = WalletImportCoordinator()

        let older = Task { await begin(coordinator, [field(1, wallet: "wallet-a")], links: links, repository: repository) }
        defer { older.cancel(); release.trip() }
        let started = await entered.wait(timeout: .seconds(5), onTimeout: { release.trip() })
        #expect(started)
        await begin(coordinator, [field(2, wallet: "wallet-a")], links: links, repository: repository)
        #expect(coordinator.state == .finished(WalletTransactionImportResult(addedCount: 1, matchedCount: 0)))

        release.trip()
        await older.value

        #expect(coordinator.state == .finished(WalletTransactionImportResult(addedCount: 1, matchedCount: 0)))
    }

    @Test func aFailureAfterOneWalletAccountReportsWhatWasAdded() async {
        let links = FakeWalletAccountLinks()
        links.linksByBudget["budget"] = ["wallet-a": "checking", "wallet-b": "card"]
        let repository = repository()
        repository.importWalletTransactionsHook = { _, accountID in
            if accountID == "card" { throw LocalFirstError.importedTransactionConflict }
            return WalletTransactionImportResult(addedCount: 2, matchedCount: 0)
        }
        let coordinator = WalletImportCoordinator()

        await begin(coordinator, [field(1, wallet: "wallet-a"), field(2, wallet: "wallet-b")], links: links, repository: repository)

        guard case .failed(_, let partial) = coordinator.state else {
            Issue.record("expected a failure, got \(coordinator.state)")
            return
        }
        #expect(partial == WalletTransactionImportResult(addedCount: 2, matchedCount: 0))
    }

    @Test func groupingKeepsFirstSeenOrderAndDropsRejectedRows() {
        let groups = WalletImportPlanning.groups(
            [field(1, wallet: "b"), field(2, wallet: "a"), field(3, wallet: "b"), field(4, wallet: "a", status: .rejected)],
            currency: .usd
        )
        #expect(groups.map(\.walletAccountID) == ["b", "a"])
        #expect(groups.map { $0.candidates.map(\.payeeName) } == [["Merchant 1", "Merchant 3"], ["Merchant 2"]])
    }

    @Test func linkRowsListOnlyLinksWhoseAccountExists() {
        let rows = WalletImportPlanning.linkRows(
            links: ["w1": "card", "w2": "gone", "w3": "checking"],
            accountNames: ["card": "Apple Card", "checking": "Checking"]
        )
        #expect(rows.map(\.accountName) == ["Apple Card", "Checking"])
        #expect(rows.map(\.walletAccountID) == ["w1", "w3"])
    }

    @Test func walletLinksPersistInAppSettings() throws {
        var settings = AppSettings()
        settings.walletAccountLinksByBudgetID = ["budget": ["wallet-a": "checking"]]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.walletAccountLinksByBudgetID == ["budget": ["wallet-a": "checking"]])

        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(legacy.walletAccountLinksByBudgetID.isEmpty)
    }
}
