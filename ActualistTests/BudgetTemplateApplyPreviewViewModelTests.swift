import Foundation
import Testing
@testable import Actualist

@Suite("Budget template apply preview view model")
@MainActor
struct BudgetTemplateApplyPreviewViewModelTests {
    @Test(arguments: [BudgetTemplateConfirmation.monthFillEmpty, .category],
          [BudgetCurrency.usd, .catalog(code: "EUR", hideFraction: true), .jpy, .none])
    func displayUsesSnapshotCurrency(_ confirmation: BudgetTemplateConfirmation, currency: BudgetCurrency) async {
        var snapshot = preview(assigned: 12_345, modeIdentity: nil)
        snapshot.currency = currency
        let repository = ApplyPreviewRepository(preview: snapshot)
        let model = BudgetTemplateApplyPreviewViewModel()
        await model.load(confirmation: confirmation, categoryID: "category", month: "2026-07",
                         budgetID: "budget", randomized: false, repository: repository)
        let revision = model.reviewRevision
        #expect(model.display?.assignedText == currency.formatted(12_345))
        #expect(model.reviewRevision == revision)
        #expect(model.canApply)
        #expect(await repository.previewCallCount() + repository.previewPairCallCount() == 1)
    }

    @Test(arguments: CancellationTestCase.allCases)
    func cancelledPreviewCannotEnableApply(_ kind: CancellationTestCase) async {
        let model = BudgetTemplateApplyPreviewViewModel()
        await model.load(confirmation: .monthOverwrite, categoryID: nil, month: "2026-07",
                         budgetID: "budget", randomized: false,
                         repository: ApplyPreviewRepository(error: kind.error))
        #expect(model.phase == .idle)
        #expect(model.errorMessage == nil)
        #expect(!model.canApply)
    }

    @Test func readyPreviewCanApply() async {
        let repository = ApplyPreviewRepository(
            preview: BudgetTemplateApplyPreview(
                assigned: 40_000,
                leftover: 0,
                isTrackingBudget: false,
                currency: .usd,
                categories: [
                    BudgetTemplateApplyPreview.Category(
                        categoryID: "groceries",
                        name: "Groceries",
                        current: 0,
                        proposed: 40_000,
                        perTemplate: [40_000],
                        drafts: [],
                        metric: .init(kind: .available, before: 0, after: 40_000)
                    )
                ]
            )
        )
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: repository
        )
        #expect(viewModel.phase == .ready)
        #expect(viewModel.canApply)
        #expect(viewModel.display?.changeCountText == "1 category")
        #expect(viewModel.errorMessage == nil)
    }

    @Test func failedPreviewCannotApply() async {
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthFillEmpty,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: ApplyPreviewRepository(error: LocalFirstError.unsupportedTemplate("stale notes"))
        )
        #expect(viewModel.phase == .failed)
        #expect(!viewModel.canApply)
        #expect(viewModel.display == nil)
        #expect(viewModel.errorMessage != nil)
    }

    @Test func missingCategoryCannotApply() async {
        let repository = ApplyPreviewRepository(preview: .empty)
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .category,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: repository
        )
        #expect(viewModel.phase == .failed)
        #expect(!viewModel.canApply)
        #expect(await repository.previewCallCount() == 0)
    }

    @Test func convertedPreviewFailsInsteadOfRemainingLoading() async {
        let reviewed = BudgetModeIdentity(storageID: "fixture", table: .envelope, revision: "before")
        let converted = BudgetModeIdentity(storageID: "fixture", table: .tracking, revision: "after")
        var preview = BudgetTemplateApplyPreview.empty
        preview.modeIdentity = converted
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite, categoryID: nil, month: "2026-07",
            budgetID: "budget-1", modeIdentity: reviewed, randomized: false,
            repository: ApplyPreviewRepository(preview: preview)
        )
        #expect(viewModel.phase == .failed)
        #expect(!viewModel.canApply)
        #expect(viewModel.errorMessage == BudgetModeWriteError.budgetChanged.localizedDescription)
    }

    @Test func readyPreviewKeepsItsReviewedIdentity() async {
        let reviewed = BudgetModeIdentity(storageID: "fixture", table: .tracking, revision: "review")
        var preview = BudgetTemplateApplyPreview.empty
        preview.modeIdentity = reviewed
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite, categoryID: nil, month: "2026-07",
            budgetID: "budget-1", modeIdentity: reviewed, randomized: false,
            repository: ApplyPreviewRepository(preview: preview)
        )
        #expect(viewModel.canApply)
        #expect(viewModel.reviewRevision?.modeIdentity == reviewed)
    }

    @Test func pairedPreviewLoadsOnceAndSwitchesTheReviewedCommand() async {
        let fill = preview(assigned: 10_000, modeIdentity: nil)
        let overwrite = preview(assigned: 20_000, modeIdentity: nil)
        let repository = ApplyPreviewRepository(
            pair: BudgetTemplateApplyPreviewPair(
                fillEmpty: .ready(fill),
                overwrite: .ready(overwrite)
            )
        )
        let viewModel = BudgetTemplateApplyPreviewViewModel()

        await viewModel.load(
            confirmation: .monthOverwrite,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: repository
        )

        #expect(await repository.previewPairCallCount() == 1)
        #expect(viewModel.selectedMode == .overwrite)
        #expect(viewModel.selectedConfirmation == .monthOverwrite)
        #expect(viewModel.display?.assignedText == BudgetCurrency.usd.formatted(20_000))

        viewModel.selectMode(.fillEmpty)
        #expect(viewModel.selectedConfirmation == .monthFillEmpty)
        #expect(viewModel.display?.assignedText == BudgetCurrency.usd.formatted(10_000))
        #expect(viewModel.canApply)
    }

    @Test func oneFailedPairedModeDoesNotEraseTheOtherMode() async {
        let repository = ApplyPreviewRepository(
            pair: BudgetTemplateApplyPreviewPair(
                fillEmpty: .failed("Fill Empty is unavailable."),
                overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
            )
        )
        let viewModel = BudgetTemplateApplyPreviewViewModel()

        await viewModel.load(
            confirmation: .monthFillEmpty,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: repository
        )
        #expect(!viewModel.canApply)
        #expect(viewModel.errorMessage == "Fill Empty is unavailable.")

        viewModel.selectMode(.overwrite)
        #expect(viewModel.canApply)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func privatePairedFailureDoesNotExposeCategoryOrAmount() async {
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthFillEmpty,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: true,
            repository: ApplyPreviewRepository(pair: BudgetTemplateApplyPreviewPair(
                fillEmpty: .failed("Groceries needs 123.45 to fund."),
                overwrite: .ready(.empty)
            ))
        )
        #expect(viewModel.errorMessage == "Template preview unavailable for this option.")
        #expect(!viewModel.canApply)
    }

    @Test func selectedDoorIsPreservedWhilePairLoads() async {
        let repository = ApplyPreviewRepository(
            pair: BudgetTemplateApplyPreviewPair(
                fillEmpty: .ready(preview(assigned: 10_000, modeIdentity: nil)),
                overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
            )
        )
        await repository.suspendNextPair()
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        let task = Task {
            await viewModel.load(
                confirmation: .monthOverwrite,
                categoryID: nil,
                month: "2026-07",
                budgetID: "budget-1",
                randomized: false,
                repository: repository
            )
        }

        await repository.waitForPairCall()
        #expect(viewModel.phase == .loading)
        #expect(viewModel.selectedMode == .overwrite)
        viewModel.selectMode(.fillEmpty)
        await repository.resolvePair()
        await task.value
        #expect(viewModel.selectedConfirmation == .monthFillEmpty)
        #expect(viewModel.canApply)
    }

    @Test func stalePairFromContextChangeCannotReplaceCurrentResult() async {
        let firstRepository = ApplyPreviewRepository()
        await firstRepository.suspendNextPair()
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        let firstTask = Task {
            await viewModel.load(
                confirmation: .monthFillEmpty,
                categoryID: nil,
                month: "2026-07",
                budgetID: "budget-1",
                randomized: false,
                repository: firstRepository
            )
        }
        await firstRepository.waitForPairCall()

        let secondRepository = ApplyPreviewRepository()
        await secondRepository.suspendNextPair()
        let secondTask = Task {
            await viewModel.load(
                confirmation: .monthFillEmpty,
                categoryID: nil,
                month: "2026-08",
                budgetID: "budget-1",
                randomized: false,
                repository: secondRepository
            )
        }
        await secondRepository.waitForPairCall()

        await firstRepository.resolvePair(
            BudgetTemplateApplyPreviewPair(
                fillEmpty: .ready(preview(assigned: 10_000, modeIdentity: nil)),
                overwrite: .ready(preview(assigned: 10_000, modeIdentity: nil))
            )
        )
        await secondRepository.resolvePair(
            BudgetTemplateApplyPreviewPair(
                fillEmpty: .ready(preview(assigned: 20_000, modeIdentity: nil)),
                overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
            )
        )
        await firstTask.value
        await secondTask.value

        #expect(viewModel.display?.assignedText == BudgetCurrency.usd.formatted(20_000))
    }

    @Test func cancelledPairCannotPublishItsResult() async {
        let repository = ApplyPreviewRepository()
        await repository.suspendNextPair()
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        let task = Task {
            await viewModel.load(
                confirmation: .monthFillEmpty,
                categoryID: nil,
                month: "2026-07",
                budgetID: "budget-1",
                randomized: false,
                repository: repository
            )
        }
        await repository.waitForPairCall()
        viewModel.cancel()
        await repository.resolvePair()
        await task.value

        #expect(viewModel.phase == .idle)
        #expect(viewModel.display == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func revisionReloadPreservesTheChosenMode() async {
        let firstRepository = ApplyPreviewRepository(
            pair: BudgetTemplateApplyPreviewPair(
                fillEmpty: .ready(preview(assigned: 10_000, modeIdentity: nil)),
                overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
            )
        )
        let secondRepository = ApplyPreviewRepository(
            pair: BudgetTemplateApplyPreviewPair(
                fillEmpty: .ready(preview(assigned: 30_000, modeIdentity: nil)),
                overwrite: .ready(preview(assigned: 40_000, modeIdentity: nil))
            )
        )
        let viewModel = BudgetTemplateApplyPreviewViewModel()
        await viewModel.load(
            confirmation: .monthOverwrite,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: firstRepository
        )
        viewModel.selectMode(.fillEmpty)

        await viewModel.load(
            confirmation: .monthOverwrite,
            categoryID: nil,
            month: "2026-07",
            budgetID: "budget-1",
            randomized: false,
            repository: secondRepository
        )

        #expect(viewModel.selectedMode == .fillEmpty)
        #expect(viewModel.display?.assignedText == BudgetCurrency.usd.formatted(30_000))
    }

    @Test func resumedSheetReusesReviewUntilForegroundRevisionChanges() async {
        let repository = ApplyPreviewRepository(pair: BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview(assigned: 10_000, modeIdentity: nil)),
            overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
        ))
        let model = BudgetTemplateApplyPreviewViewModel()
        await model.loadIfNeeded(revision: 1, confirmation: .monthOverwrite,
                                 categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                 randomized: false, repository: repository)
        let firstReview = model.reviewRevision
        model.selectMode(.fillEmpty)

        // Re-entering the sheet task without a local revision must not read again.
        await model.loadIfNeeded(revision: 1, confirmation: .monthOverwrite,
                                 categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                 randomized: false, repository: repository)
        #expect(await repository.previewPairCallCount() == 1)
        #expect(model.reviewRevision == firstReview)
        #expect(model.selectedMode == .fillEmpty)

        await repository.suspendNextPair()
        let refresh = Task {
            await model.loadIfNeeded(revision: 2, confirmation: .monthOverwrite,
                                     categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                     randomized: false, repository: repository)
        }
        await repository.waitForPairCall(expected: 2)
        #expect(model.phase == .loading)
        #expect(!model.canApply)
        #expect(model.reviewRevision == nil)
        #expect(model.display?.assignedText == BudgetCurrency.usd.formatted(10_000))
        await repository.resolvePair(BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview(assigned: 30_000, modeIdentity: nil)),
            overwrite: .ready(preview(assigned: 40_000, modeIdentity: nil))
        ))
        await refresh.value
        #expect(model.canApply)
        #expect(model.selectedMode == .fillEmpty)
        #expect(model.display?.assignedText == BudgetCurrency.usd.formatted(30_000))

        await model.loadIfNeeded(revision: 2, confirmation: .monthOverwrite,
                                 categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                 randomized: false, repository: repository)
        #expect(await repository.previewPairCallCount() == 2)
    }

    @Test func foregroundCalendarAndSyncCauseOnlyOneReviewReload() async throws {
        let fixtures = LocalFirstActualStoreTests()
        let transport = RecordingSyncTransport()
        let bundle = try await fixtures.makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")
        let appState = try fixtures.makeAppState(for: bundle)
        let calendar = BudgetCalendarCoordinator(publishWidgets: {})
        calendar.configure(appState: appState)
        defer {
            calendar.endForeground()
            appState.endForegroundSession()
        }

        await appState.beginForegroundSession()
        await appState.budgetDidPresent("group-1")?.value
        await calendar.beginForeground()?.value
        let repository = ApplyPreviewRepository(pair: BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview(assigned: 10_000, modeIdentity: nil)),
            overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
        ))
        let model = BudgetTemplateApplyPreviewViewModel()
        func updateReview() async {
            await model.loadIfNeeded(revision: appState.localDataRevision,
                                     confirmation: .monthFillEmpty, categoryID: nil,
                                     month: "2026-07", budgetID: "group-1",
                                     randomized: false, repository: repository)
        }
        await updateReview()
        model.selectMode(.overwrite)
        let beforeReturn = appState.localDataRevision
        #expect(await repository.previewPairCallCount() == 1)

        calendar.endForeground()
        appState.endForegroundSession()

        // The scene starts both coordinators on return. Let the calendar finish
        // first so a redundant revision cannot hide through update coalescing.
        await calendar.beginForeground()?.value
        await updateReview()
        #expect(appState.localDataRevision == beforeReturn)
        #expect(await repository.previewPairCallCount() == 1)

        await appState.beginForegroundSession()
        await appState.budgetDidPresent("group-1")?.value
        await updateReview()
        #expect(appState.localDataRevision == beforeReturn + 1)
        #expect(await transport.messageCounts() == [0, 0])
        #expect(await repository.previewPairCallCount() == 2)
        #expect(model.selectedMode == .overwrite)
        #expect(model.canApply)
    }

    @Test func olderForegroundResultCannotMarkNewerRevisionComplete() async {
        let repository = ApplyPreviewRepository()
        await repository.suspendNextPair()
        let model = BudgetTemplateApplyPreviewViewModel()
        let older = Task {
            await model.loadIfNeeded(revision: 1, confirmation: .monthFillEmpty,
                                     categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                     randomized: false, repository: repository)
        }
        await repository.waitForPairCall()
        let newer = ApplyPreviewRepository(pair: BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview(assigned: 30_000, modeIdentity: nil)),
            overwrite: .ready(preview(assigned: 40_000, modeIdentity: nil))
        ))
        await model.loadIfNeeded(revision: 2, confirmation: .monthFillEmpty,
                                 categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                 randomized: false, repository: newer)
        await repository.resolvePair()
        await older.value
        #expect(model.display?.assignedText == BudgetCurrency.usd.formatted(30_000))
        await model.loadIfNeeded(revision: 2, confirmation: .monthFillEmpty,
                                 categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                 randomized: false, repository: newer)
        #expect(await newer.previewPairCallCount() == 1)
    }

    @Test func privacyChangeNeverShowsPreviousRealAmountsDuringRefresh() async {
        let repository = ApplyPreviewRepository(pair: BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview(assigned: 10_000, modeIdentity: nil)),
            overwrite: .ready(preview(assigned: 20_000, modeIdentity: nil))
        ))
        let model = BudgetTemplateApplyPreviewViewModel()
        await model.loadIfNeeded(revision: 1, confirmation: .monthFillEmpty,
                                 categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                 randomized: false, repository: repository)
        await repository.suspendNextPair()
        let privacyRefresh = Task {
            await model.loadIfNeeded(revision: 1, confirmation: .monthFillEmpty,
                                     categoryID: nil, month: "2026-07", budgetID: "budget-1",
                                     randomized: true, repository: repository)
        }
        await repository.waitForPairCall(expected: 2)
        #expect(model.phase == .loading)
        #expect(model.display == nil)
        #expect(!model.canApply)
        await repository.resolvePair()
        await privacyRefresh.value
        #expect(model.canApply)
        #expect(model.display?.assignedText != BudgetCurrency.usd.formatted(10_000))
    }

    private func preview(assigned: Int, modeIdentity: BudgetModeIdentity?) -> BudgetTemplateApplyPreview {
        var preview = BudgetTemplateApplyPreview(
            assigned: assigned,
            leftover: 0,
            isTrackingBudget: false,
            currency: .usd,
            categories: []
        )
        preview.modeIdentity = modeIdentity
        return preview
    }

}

private extension BudgetTemplateApplyPreview {
    static let empty = BudgetTemplateApplyPreview(
        assigned: 0,
        leftover: 0,
        isTrackingBudget: false,
        currency: .usd,
        categories: []
    )
}

private actor ApplyPreviewRepository: BudgetRepositoryProtocol {
    private static let fallbackIdentity = BudgetModeIdentity(
        storageID: "preview-fixture", table: .envelope, revision: nil
    )
    var preview: BudgetTemplateApplyPreview
    var error: Error?
    var pair: BudgetTemplateApplyPreviewPair?
    private var calls = 0
    private var pairCalls = 0
    private var shouldSuspendPair = false
    private var pairContinuation: CheckedContinuation<BudgetTemplateApplyPreviewPair, Never>?

    init(
        preview: BudgetTemplateApplyPreview = .empty,
        error: Error? = nil,
        pair: BudgetTemplateApplyPreviewPair? = nil
    ) {
        self.preview = preview
        self.error = error
        self.pair = pair
    }

    func previewCallCount() -> Int { calls }
    func previewPairCallCount() -> Int { pairCalls }

    func suspendNextPair() { shouldSuspendPair = true }

    func waitForPairCall(expected: Int = 1) async {
        while pairCalls < expected {
            await Task.yield()
        }
    }

    func resolvePair(_ result: BudgetTemplateApplyPreviewPair? = nil) {
        pairContinuation?.resume(returning: result ?? pair ?? BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview),
            overwrite: .ready(preview)
        ))
        pairContinuation = nil
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        calls += 1
        if let error {
            throw error
        }
        return Self.withReviewRevision(preview, month: month)
    }

    func previewBudgetTemplatePair(
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreviewPair {
        pairCalls += 1
        if let error { throw error }
        if shouldSuspendPair {
            shouldSuspendPair = false
            let result = await withCheckedContinuation { continuation in
                pairContinuation = continuation
            }
            return Self.withReviewRevision(result, month: month)
        }
        return Self.withReviewRevision(pair ?? BudgetTemplateApplyPreviewPair(
            fillEmpty: .ready(preview),
            overwrite: .ready(preview)
        ), month: month)
    }

    private static func withReviewRevision(
        _ pair: BudgetTemplateApplyPreviewPair,
        month: String
    ) -> BudgetTemplateApplyPreviewPair {
        BudgetTemplateApplyPreviewPair(
            fillEmpty: withReviewRevision(pair.fillEmpty, month: month),
            overwrite: withReviewRevision(pair.overwrite, month: month)
        )
    }

    private static func withReviewRevision(
        _ outcome: BudgetTemplatePreviewOutcome,
        month: String
    ) -> BudgetTemplatePreviewOutcome {
        guard case .ready(let preview) = outcome else { return outcome }
        return .ready(withReviewRevision(preview, month: month))
    }

    private static func withReviewRevision(
        _ preview: BudgetTemplateApplyPreview,
        month: String
    ) -> BudgetTemplateApplyPreview {
        var preview = preview
        preview.reviewRevision = BudgetTemplateReviewRevision(
            month: month,
            modeIdentity: preview.modeIdentity ?? fallbackIdentity,
            messageCount: 0,
            maxMessageTimestamp: nil
        )
        return preview
    }

    func budgets() async throws -> [ActualBudget] { [] }

    func currentBudgetMonth(
        budgetID: String,
        preferredMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func budgetMonth(
        budgetID: String,
        selectedMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func assignCategoryBudgetAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        budgeted: Int,
        budgetID: String,
        month: String,
        didAssign: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        categoryID: String,
        carryover: Bool,
        budgetID: String,
        startMonth: String,
        didSetCarryover: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setAllExpenseCategoryCarryoverAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        carryover: Bool,
        budgetID: String,
        startMonth: String
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryHiddenAndRefresh(
        categoryID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func setCategoryGroupHiddenAndRefresh(
        groupID: String,
        hidden: Bool,
        budgetID: String,
        month: String,
        didUpdate: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func applyBudgetTemplateAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String,
        didApply: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        command: BudgetMoveMoneyCommand,
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func moveMoneyAndRefresh(expectedMode: BudgetModeIdentity? = nil,
        commands: [BudgetMoveMoneyCommand],
        budgetID: String,
        month: String,
        didMove: @escaping @MainActor @Sendable () async -> Void
    ) async throws -> LoadedBudgetMonth {
        Self.dummyMonth
    }

    func recentBudgetActions(budgetID: String) async throws -> [BudgetActionRecord] { [] }

    func budgetActionCategoryNames(budgetID: String) async throws -> [String: String] { [:] }

    func budgetActionUndoPreview(
        actionID: String,
        budgetID: String
    ) async throws -> BudgetActionUndoPreview {
        BudgetActionUndoPreview(actionID: actionID, month: "", entries: [], block: nil)
    }

    func undoBudgetActionAndRefresh(actionID: String, budgetID: String) async throws {}

    private static let dummyMonth = LoadedBudgetMonth(
        availableMonths: ["2026-07"],
        selectedMonth: "2026-07",
        month: try! JSONDecoder().decode(BudgetMonth.self, from: Data(#"""
            {
              "month": "2026-07",
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
            """#.utf8)),
        alerts: []
    )
}
