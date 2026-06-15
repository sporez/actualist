import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionEditorViewModelTests {
    @Test func formatsTypedDigitsAsCents() {
        let model = TransactionEditorViewModel()

        model.setAmountInput("500")
        #expect(model.amountCents == 500)
        #expect(model.formattedAmount.contains("5.00"))

        model.setAmountInput("50000")
        #expect(model.amountCents == 50000)
        #expect(model.formattedAmount.contains("500.00"))
    }

    @Test func filtersPayeesAndAllowsCustomName() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "amazon", name: "Amazon", category: nil, transferAccount: nil),
            ActualPayee(id: "target", name: "Target", category: nil, transferAccount: nil)
        ]

        #expect(model.filteredPayees(matching: "ama").map(\.name) == ["Amazon"])

        model.useCustomPayee("Local Coffee")
        #expect(model.payeeName == "Local Coffee")
        #expect(model.selectedPayeeID == nil)
    }

    @Test func buildsSpendDraftForCustomPayee() async throws {
        let model = configuredModel()
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.submissionState == .clean)

        let draft = try await repository.onlyDraft()
        #expect(draft.accountID == "checking")
        #expect(draft.amountMinorUnits == -1234)
        #expect(draft.payeeID == nil)
        #expect(draft.payeeName == "Corner Store")
        #expect(draft.categoryID == nil)
        #expect(draft.notes == "weekly groceries")
        #expect(draft.cleared == true)
    }

    @Test func buildsInflowDraftForSelectedPayeeAndCategory() async throws {
        let model = configuredModel()
        model.kind = .inflow
        model.selectedPayeeID = "employer"
        model.payeeName = "Employer"
        model.selectedCategoryID = "income"
        model.notes = "   "
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)

        let draft = try await repository.onlyDraft()
        #expect(draft.amountMinorUnits == 1234)
        #expect(draft.payeeID == "employer")
        #expect(draft.payeeName == "Employer")
        #expect(draft.categoryID == "income")
        #expect(draft.notes == nil)
    }

    @Test func prefilledEditModelMatchesTransaction() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-1",
                account: "savings",
                date: "2026-06-13",
                amount: 4512,
                payee: "employer",
                payeeName: nil,
                importedPayee: "Imported Employer",
                category: "income",
                notes: "paycheck",
                cleared: .bool(true)
            ),
            payeeName: "Employer",
            categoryName: "Income"
        )

        #expect(model.isEditing)
        #expect(model.title == "Edit Transaction")
        #expect(model.kind == .inflow)
        #expect(model.amountDigits == "4512")
        #expect(model.payeeName == "Employer")
        #expect(model.selectedPayeeID == "employer")
        #expect(model.selectedAccountID == "savings")
        #expect(model.selectedCategoryID == "income")
        #expect(model.selectedCategoryName == "Income")
        #expect(model.notes == "paycheck")
        #expect(model.isCleared)
        #expect(model.saveButtonTitle == "Update")
    }

    @Test func editingSubmitUpdatesExistingTransaction() async throws {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-1",
                account: "checking",
                date: "2026-05-31",
                amount: -1200,
                payee: nil,
                payeeName: "Corner Store",
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false)
            )
        )
        model.amountDigits = "1299"
        model.date = Self.date("2026-06-14")
        model.notes = "updated"
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.submissionState == .clean)
        #expect(await repository.draftCount() == 0)

        let update = try await repository.onlyUpdate()
        #expect(update.transactionID == "txn-1")
        #expect(update.originalAccountID == "checking")
        #expect(update.originalMonth == "2026-05")
        #expect(update.draft.amountMinorUnits == -1299)
        #expect(update.draft.notes == "updated")
    }

    @Test func doesNotSubmitInvalidDrafts() async {
        let repository = RecordingTransactionRepository()
        let missingEverything = TransactionEditorViewModel()
        #expect(await missingEverything.submit(budgetID: "budget", repository: repository) == false)

        let missingAmount = configuredModel()
        missingAmount.amountDigits = ""
        #expect(await missingAmount.submit(budgetID: "budget", repository: repository) == false)

        let missingPayee = configuredModel()
        missingPayee.payeeName = " "
        #expect(await missingPayee.submit(budgetID: "budget", repository: repository) == false)

        let missingAccount = configuredModel()
        missingAccount.selectedAccountID = nil
        #expect(await missingAccount.submit(budgetID: "budget", repository: repository) == false)

        #expect(await repository.draftCount() == 0)
    }

    @Test func successfulSubmitTransitionsThroughRefetching() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(pauseAfterDidCreate: true)

        let task = Task {
            await model.submit(budgetID: "budget", repository: repository)
        }

        while await !repository.didCreateFinished() {
            await Task.yield()
        }

        #expect(model.submissionState == .refetching)

        await repository.resumeAfterDidCreate()

        #expect(await task.value == true)
        #expect(model.submissionState == .clean)
    }

    @Test func createFailureLeavesDraftRetryable() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(createError: TestError("create failed"))

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved == false)
        #expect(model.submissionState == .failed("create failed"))
        #expect(model.errorMessage == "create failed")
        #expect(model.canSave)
    }

    @Test func refreshFailureLeavesDraftRetryable() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(refreshError: TestError("refresh failed"))

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved == false)
        #expect(model.submissionState == .failed("refresh failed"))
        #expect(model.errorMessage == "refresh failed")
        #expect(model.canSave)
    }

    @Test func duplicateSubmitIsBlockedWhileSubmitting() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(pauseBeforeDidCreate: true)

        let firstSubmit = Task {
            await model.submit(budgetID: "budget", repository: repository)
        }

        while await !repository.isPausedBeforeDidCreate() {
            await Task.yield()
        }

        #expect(model.submissionState == .submitting)
        #expect(await model.submit(budgetID: "budget", repository: repository) == false)
        #expect(await repository.draftCount() == 1)

        await repository.resumeBeforeDidCreate()

        #expect(await firstSubmit.value == true)
        #expect(model.submissionState == .clean)
    }

    @Test func rulePreviewAppliesSuggestedCategoryAndNotes() async throws {
        let model = configuredModel()
        model.selectedPayeeID = "target"
        model.payeeName = "Target"
        model.notes = "old note"
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(
                categoryID: "groceries",
                notes: "rule note"
            )
        )

        await model.previewRules(budgetID: "budget", repository: repository)

        #expect(model.selectedCategoryID == "groceries")
        #expect(model.notes == "rule note")

        let draft = try await repository.onlyRulePreviewDraft()
        #expect(draft.accountID == "checking")
        #expect(draft.amountMinorUnits == -1234)
        #expect(draft.payeeID == "target")
        #expect(draft.payeeName == "Target")
        #expect(draft.notes == "old note")
    }

    @Test func batchUpdatePayloadDisablesLearningAndTransferAutomation() throws {
        let payload = APITransactionBatchUpdatePayload(
            added: [
                APITransactionDraft(
                    id: "txn-id",
                    account: "checking",
                    date: "2026-06-14",
                    amount: -1234,
                    payee: nil,
                    payeeName: "Corner Store",
                    category: nil,
                    notes: nil,
                    cleared: false
                )
            ]
        )

        let dictionary = try encodedDictionary(payload)
        let added = try #require(dictionary["added"] as? [[String: Any]])
        let transaction = try #require(added.first)

        #expect(dictionary["learnCategories"] as? Bool == false)
        #expect(dictionary["runTransfers"] as? Bool == false)
        #expect(transaction["id"] as? String == "txn-id")
        #expect(transaction["payee"] == nil)
        #expect(transaction["payee_name"] as? String == "Corner Store")
    }

    @Test func batchUpdatePayloadUsesExistingPayeeIDWhenSelected() throws {
        let payload = APITransactionBatchUpdatePayload(
            added: [
                APITransactionDraft(
                    id: "txn-id",
                    account: "checking",
                    date: "2026-06-14",
                    amount: 1234,
                    payee: "employer",
                    payeeName: nil,
                    category: "income",
                    notes: nil,
                    cleared: true
                )
            ]
        )

        let dictionary = try encodedDictionary(payload)
        let added = try #require(dictionary["added"] as? [[String: Any]])
        let transaction = try #require(added.first)

        #expect(transaction["payee"] as? String == "employer")
        #expect(transaction["payee_name"] == nil)
    }

    @Test func batchUpdatePayloadCanCarryUpdatedTransactions() throws {
        let payload = APITransactionBatchUpdatePayload(
            added: [],
            updated: [
                APITransactionDraft(
                    id: "txn-id",
                    account: "checking",
                    date: "2026-06-14",
                    amount: -1234,
                    payee: nil,
                    payeeName: "Corner Store",
                    category: nil,
                    notes: nil,
                    cleared: false
                )
            ]
        )

        let dictionary = try encodedDictionary(payload)
        let updated = try #require(dictionary["updated"] as? [[String: Any]])
        let transaction = try #require(updated.first)
        let added = try #require(dictionary["added"] as? [[String: Any]])

        #expect(added.isEmpty)
        #expect(transaction["id"] as? String == "txn-id")
        #expect(transaction["payee_name"] as? String == "Corner Store")
    }

    @Test func rulesRunPayloadUsesExistingPayeeID() throws {
        let payload = APITransactionRulesRunPayload(
            transaction: APITransactionDraft(
                id: "preview-id",
                account: "checking",
                date: "2026-06-14",
                amount: -1234,
                payee: nil,
                payeeName: "Corner Store",
                category: nil,
                notes: nil,
                cleared: false
            )
        )

        let dictionary = try encodedDictionary(payload)
        let transaction = try #require(dictionary["transaction"] as? [String: Any])

        #expect(transaction["id"] as? String == "preview-id")
        #expect(transaction["payee"] == nil)
        #expect(transaction["payee_name"] as? String == "Corner Store")
    }

    private func configuredModel() -> TransactionEditorViewModel {
        let model = TransactionEditorViewModel()
        model.kind = .spend
        model.amountDigits = "1234"
        model.payeeName = "  Corner Store  "
        model.selectedAccountID = "checking"
        model.date = Self.date("2026-06-14")
        model.notes = "  weekly groceries  "
        model.isCleared = true
        return model
    }

    nonisolated static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: "\(value) 12:00:00")!
    }

    private func encodedDictionary(_ payload: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder.actual.encode(payload)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@Suite(.serialized)
struct TransactionRepositoryRefreshTests {
    @Test func createTransactionRefetchesAffectedResourcesBeforeReturning() async throws {
        let recorder = RequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            return try Self.response(for: request)
        }

        let result = try await repository.createTransactionAndRefresh(
            Self.draft(),
            budgetID: "budget"
        )

        let requests = recorder.requests()
        #expect(result.changed.accounts == ["checking"])
        #expect(result.changed.months == ["2026-06"])
        #expect(requests.contains("POST /v1/budgets/budget/transactions/batch-update"))
        #expect(requests.contains("GET /v1/budgets/budget/accounts/checking/balance"))
        #expect(requests.contains { $0.hasPrefix("GET /v1/budgets/budget/accounts/checking/transactions?") })
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06"))
    }

    @Test func updateTransactionRefetchesOriginalAndNewAffectedResources() async throws {
        let recorder = RequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            return try Self.response(for: request)
        }

        let result = try await repository.updateTransactionAndRefresh(
            "txn-1",
            with: Self.draft(accountID: "savings", date: "2026-06-14"),
            budgetID: "budget",
            originalAccountID: "checking",
            originalMonth: "2026-05"
        )

        let requests = recorder.requests()
        #expect(result.changed.accounts == ["checking", "savings"])
        #expect(result.changed.months == ["2026-05", "2026-06"])
        #expect(result.changed.transactions == ["txn-1"])
        #expect(requests.contains("POST /v1/budgets/budget/transactions/batch-update"))
        #expect(requests.contains("GET /v1/budgets/budget/accounts/checking/balance"))
        #expect(requests.contains("GET /v1/budgets/budget/accounts/savings/balance"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-05"))
        #expect(requests.contains("GET /v1/budgets/budget/months/2026-06"))
    }

    @Test func previewRulesRequestsRulesRunEndpoint() async throws {
        let recorder = RequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            return try Self.response(for: request)
        }

        let preview = try await repository.previewRules(for: Self.draft(), budgetID: "budget")

        #expect(preview.categoryID == "groceries")
        #expect(preview.notes == "rule note")
        #expect(recorder.requests().contains("POST /v1/budgets/budget/rules/run"))
    }

    @Test func transactionListRefreshFailureIsNotSwallowed() async throws {
        let recorder = RequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/transactions") == true {
                return try Self.errorResponse(for: request)
            }
            return try Self.response(for: request)
        }

        do {
            _ = try await repository.createTransactionAndRefresh(Self.draft(), budgetID: "budget")
            Issue.record("Expected transaction list refresh failure to throw")
        } catch {
            #expect(recorder.requests().contains { $0.hasPrefix("GET /v1/budgets/budget/accounts/checking/transactions?") })
            #expect(recorder.requests().contains("GET /v1/budgets/budget/months/2026-06") == false)
        }
    }

    @Test func budgetMonthRefreshFailureIsNotSwallowed() async throws {
        let recorder = RequestRecorder()
        let repository = Self.repository { request in
            recorder.record(request)
            if request.httpMethod == "GET", request.url?.path.hasSuffix("/months/2026-06") == true {
                return try Self.errorResponse(for: request)
            }
            return try Self.response(for: request)
        }

        do {
            _ = try await repository.createTransactionAndRefresh(Self.draft(), budgetID: "budget")
            Issue.record("Expected budget month refresh failure to throw")
        } catch {
            #expect(recorder.requests().contains("GET /v1/budgets/budget/months/2026-06"))
        }
    }

    private static func repository(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> TransactionRepository {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ActualAPIClient(
            baseURL: URL(string: "http://actual.test/v1")!,
            apiKey: "test-key",
            session: session
        )
        return TransactionRepository(client: client)
    }

    private static func draft(
        accountID: String = "checking",
        date: String = "2026-06-14"
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: accountID,
            date: TransactionEditorViewModelTests.date(date),
            amountMinorUnits: -1234,
            payeeID: nil,
            payeeName: "Corner Store",
            categoryID: nil,
            notes: nil,
            cleared: false
        )
    }

    private static func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""

        if method == "POST", path.hasSuffix("/transactions/batch-update") {
            return (try okResponse(for: request), #"{"data":{"added":[],"updated":[],"deleted":[]}}"#.data(using: .utf8)!)
        }

        if method == "POST", path.hasSuffix("/rules/run") {
            return (try okResponse(for: request), #"{"data":{"category":"groceries","notes":"rule note"}}"#.data(using: .utf8)!)
        }

        if method == "GET", path.hasSuffix("/balance") {
            return (try okResponse(for: request), #"{"data":1200}"#.data(using: .utf8)!)
        }

        if method == "GET", path.hasSuffix("/transactions") {
            return (try okResponse(for: request), #"{"data":[]}"#.data(using: .utf8)!)
        }

        if method == "GET", path.hasSuffix("/months/2026-06") {
            return (try okResponse(for: request), budgetMonthData())
        }

        if method == "GET", path.hasSuffix("/months/2026-05") {
            return (try okResponse(for: request), budgetMonthData(month: "2026-05"))
        }

        return try errorResponse(for: request)
    }

    private static func okResponse(for request: URLRequest) throws -> HTTPURLResponse {
        guard let url = request.url,
              let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw TestError("Could not build HTTP response")
        }

        return response
    }

    private static func errorResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            throw TestError("Could not build HTTP response")
        }

        return (response, #"{"error":"server failed"}"#.data(using: .utf8)!)
    }

    private static func budgetMonthData(month: String = "2026-06") -> Data {
        """
        {
          "data": {
            "month": "\(month)",
            "incomeAvailable": 0,
            "lastMonthOverspent": 0,
            "forNextMonth": 0,
            "totalBudgeted": 0,
            "toBudget": 0,
            "fromLastMonth": 0,
            "totalIncome": 0,
            "totalSpent": 0,
            "totalBalance": 0,
            "categoryGroups": []
          }
        }
        """.data(using: .utf8)!
    }
}

actor RecordingTransactionRepository: TransactionRepositoryProtocol {
    private var drafts: [TransactionDraft] = []
    private var updates: [RecordedTransactionUpdate] = []
    private var rulePreviewDrafts: [TransactionDraft] = []
    private let rulePreview: TransactionRulePreview
    private let createError: Error?
    private let refreshError: Error?
    private let pauseBeforeDidCreate: Bool
    private let pauseAfterDidCreate: Bool
    private var didCreateCallbackFinished = false
    private var pausedBeforeDidCreate = false
    private var beforeDidCreateContinuation: CheckedContinuation<Void, Never>?
    private var afterDidCreateContinuation: CheckedContinuation<Void, Never>?

    init(
        rulePreview: TransactionRulePreview = TransactionRulePreview(categoryID: nil, notes: nil),
        createError: Error? = nil,
        refreshError: Error? = nil,
        pauseBeforeDidCreate: Bool = false,
        pauseAfterDidCreate: Bool = false
    ) {
        self.rulePreview = rulePreview
        self.createError = createError
        self.refreshError = refreshError
        self.pauseBeforeDidCreate = pauseBeforeDidCreate
        self.pauseAfterDidCreate = pauseAfterDidCreate
    }

    func editorOptions(budgetID: String) async throws -> TransactionEditorOptions {
        TransactionEditorOptions(accounts: [], categories: [], payees: [])
    }

    func previewRules(
        for draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionRulePreview {
        rulePreviewDrafts.append(draft)
        return rulePreview
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        drafts.append(draft)

        if pauseBeforeDidCreate {
            await withCheckedContinuation { continuation in
                pausedBeforeDidCreate = true
                beforeDidCreateContinuation = continuation
            }
            pausedBeforeDidCreate = false
        }

        if let createError {
            throw createError
        }

        await didCreate()
        didCreateCallbackFinished = true

        if pauseAfterDidCreate {
            await withCheckedContinuation { continuation in
                afterDidCreateContinuation = continuation
            }
        }

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [draft.accountID],
                months: [draft.month.rawValue],
                transactions: []
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        updates.append(
            RecordedTransactionUpdate(
                transactionID: transactionID,
                draft: draft,
                originalAccountID: originalAccountID,
                originalMonth: originalMonth
            )
        )

        if let createError {
            throw createError
        }

        await didUpdate()
        didCreateCallbackFinished = true

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [originalAccountID, draft.accountID],
                months: [originalMonth, draft.month.rawValue],
                transactions: [transactionID]
            )
        )
    }

    func onlyDraft() throws -> TransactionDraft {
        try #require(drafts.first)
    }

    func onlyUpdate() throws -> RecordedTransactionUpdate {
        try #require(updates.first)
    }

    func onlyRulePreviewDraft() throws -> TransactionDraft {
        try #require(rulePreviewDrafts.first)
    }

    func draftCount() -> Int {
        drafts.count
    }

    func didCreateFinished() -> Bool {
        didCreateCallbackFinished
    }

    func isPausedBeforeDidCreate() -> Bool {
        pausedBeforeDidCreate
    }

    func resumeBeforeDidCreate() {
        beforeDidCreateContinuation?.resume()
        beforeDidCreateContinuation = nil
    }

    func resumeAfterDidCreate() {
        afterDidCreateContinuation?.resume()
        afterDidCreateContinuation = nil
    }
}

struct RecordedTransactionUpdate: Sendable {
    let transactionID: String
    let draft: TransactionDraft
    let originalAccountID: String
    let originalMonth: String
}

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TestError("Missing URLProtocol handler"))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [String] = []

    func record(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }

        let method = request.httpMethod ?? ""
        let url = request.url
        let path = url?.path ?? ""
        let query = url?.query.map { "?\($0)" } ?? ""
        recordedRequests.append("\(method) \(path)\(query)")
    }

    func requests() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}

struct TestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
