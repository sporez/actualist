import Foundation
import Testing
@testable import Actualist

@MainActor
struct BudgetHoldViewModelTests {
    private let identity = BudgetModeIdentity(storageID: "hold-fixture", table: .envelope, revision: nil)

    @Test func reviewDefaultsToAvailableAndSubmitsOnlyEnteredAmount() async throws {
        let review = makeReview()
        let requests = Requests()
        let result = loaded(review)
        let repository = RecordingBudgetRepository(holdReview: { review }, holdApply: { command, received in
            await requests.record(command, review: received)
            return result
        })
        let model = makeModel()
        await model.load(repository: repository)
        #expect(model.amount == 10_000)
        #expect(model.canHold)
        #expect(model.canRelease)
        model.setAmountText("25.50")
        #expect(model.resultingAvailableText == review.currency.formatted(7_450))
        #expect(model.resultingHeldText == review.currency.formatted(7_550))
        #expect(await model.submitHold(repository: repository))
        #expect(await requests.commands == [.hold(amount: 2_550)])
        #expect(await requests.reviews == [review])
        #expect(!model.canHold)
        #expect(!(await model.submitHold(repository: repository)))
    }

    @Test func invalidTextDoesNotReusePreviousAmount() async {
        let review = makeReview()
        let model = makeModel()
        await model.load(repository: RecordingBudgetRepository(holdReview: { review }))
        for text in ["", "no", "100.01", "-1", "0"] {
            model.setAmountText(text)
            #expect(!model.canHold)
            #expect(model.amount == nil)
            #expect(model.resultingHeldText == "—")
        }
        model.useAllAvailable()
        #expect(model.amount == 10_000)
        #expect(model.canHold)
    }

    @Test func releaseRemainsAvailableWhenToBudgetIsNegativeAndCancelDoesNotWrite() async {
        let review = makeReview(available: -5_000)
        let requests = Requests()
        let result = loaded(review)
        let repository = RecordingBudgetRepository(holdReview: { review }, holdApply: { command, received in
            await requests.record(command, review: received)
            return result
        })
        let model = makeModel()
        await model.load(repository: repository)
        #expect(!model.canHold)
        #expect(model.canRelease)
        model.requestRelease()
        #expect(model.isReviewingRelease)
        model.cancelRelease()
        #expect(!model.isReviewingRelease)
        #expect(await requests.commands.isEmpty)
        model.requestRelease()
        model.cancelRelease() // SwiftUI dismisses the alert binding before starting its action task.
        #expect(await model.submitRelease(repository: repository))
        #expect(await requests.commands == [.reset])
    }

    @Test func failureRequiresFreshReviewAndKeepsInput() async {
        let review = makeReview()
        let repository = RecordingBudgetRepository(holdReview: { review }, holdApply: { _, _ in
            throw LocalFirstError.unsupportedWrite
        })
        let model = makeModel()
        await model.load(repository: repository)
        model.setAmountText("25")
        #expect(!(await model.submitHold(repository: repository)))
        #expect(model.errorMessage != nil)
        #expect(!model.canHold)
        model.setAmountText("30")
        #expect(!model.canHold)
        await model.load(repository: repository)
        #expect(model.amount == 3_000)
        #expect(model.errorMessage == nil)
        #expect(model.canHold)
    }

    @Test func automaticHoldDisablesManualEntryButAllowsCurrentRelease() async {
        let review = BudgetHoldReview(month: "2026-07", modeIdentity: identity, currency: .usd,
                                      toBudget: 10_000, heldAmount: 5_000,
                                      manualHeldAmount: 0, automaticHeldAmount: 5_000)
        let model = makeModel()
        await model.load(repository: RecordingBudgetRepository(holdReview: { review }))
        #expect(!model.canHold)
        #expect(!model.canEnterHold)
        #expect(model.canRelease)
        #expect(model.releaseTitle == "Disable Current Auto Hold")
        #expect(model.releaseMessage.contains("future months stay enabled"))
    }

    @Test func nonpositiveHoldDoesNotOfferRelease() async {
        for held in [0, -100] {
            let review = BudgetHoldReview(month: "2026-07", modeIdentity: identity, currency: .usd,
                                          toBudget: 10_000, heldAmount: held,
                                          manualHeldAmount: 0, automaticHeldAmount: held)
            let model = makeModel()
            await model.load(repository: RecordingBudgetRepository(holdReview: { review }))
            #expect(!model.canRelease)
            model.requestRelease()
            #expect(!model.isReviewingRelease)
        }
    }

    @Test func mixedHoldReviewExplainsAutomaticHoldWillReplaceManualAmount() async {
        let review = BudgetHoldReview(month: "2026-07", modeIdentity: identity, currency: .usd,
                                      toBudget: 10_000, heldAmount: 5_000,
                                      manualHeldAmount: 5_000, automaticHeldAmount: 20_000)
        let model = makeModel()
        await model.load(repository: RecordingBudgetRepository(holdReview: { review }))
        #expect(!model.canHold)
        #expect(model.canRelease)
        #expect(model.releaseTitle == "Reset Manual Hold")
        #expect(model.releaseMessage.contains(review.currency.formatted(20_000)))
        #expect(model.releaseMessage.contains("will take its place"))
    }

    @Test func wrongMonthAndConvertedReviewsCannotEnableWrites() async {
        let model = makeModel()
        let otherMonth = makeReview(month: "2026-08")
        await model.load(repository: RecordingBudgetRepository(holdReview: { otherMonth }))
        #expect(!model.canHold)
        #expect(model.errorMessage != nil)
        let otherMode = makeReview(identity: .init(storageID: "hold-fixture", table: .tracking, revision: "converted"))
        await model.load(repository: RecordingBudgetRepository(holdReview: { otherMode }))
        #expect(!model.canHold)
        #expect(model.errorMessage != nil)
    }

    @Test func cancellationDoesNotBecomeAnError() async {
        let model = makeModel()
        await model.load(repository: RecordingBudgetRepository(holdReview: { throw CancellationError() }))
        #expect(!model.canHold)
        #expect(model.errorMessage == nil)
    }

    @Test func cancelledSaveReturnsToDraftWithoutClaimingSuccess() async {
        let review = makeReview()
        let repository = RecordingBudgetRepository(holdReview: { review }, holdApply: { _, _ in
            throw CancellationError()
        })
        let model = makeModel()
        await model.load(repository: repository)
        #expect(!(await model.submitHold(repository: repository)))
        #expect(model.errorMessage == nil)
        #expect(model.canHold)
        #expect(!model.isSaving)
    }

    @Test func changedIdentityAtSaveCompletionCannotCloseAsSuccess() async {
        let review = makeReview()
        var result = loaded(review)
        result.modeIdentity = .init(storageID: "other-session", table: .envelope, revision: nil)
        let changed = result
        let repository = RecordingBudgetRepository(holdReview: { review }, holdApply: { _, _ in changed })
        let model = makeModel()
        await model.load(repository: repository)
        #expect(!(await model.submitHold(repository: repository)))
        #expect(model.draft == nil)
        #expect(!model.canHold)
    }

    @Test func obsoleteLoadCannotReplaceRefreshedReview() async throws {
        let entered = TestLatch()
        let release = TestLatch()
        let calls = Requests()
        let old = makeReview()
        let repository = RecordingBudgetRepository(holdReview: {
            await calls.noteEntry()
            entered.trip()
            await release.wait()
            return old
        })
        let model = makeModel()
        let task = Task { await model.load(repository: repository) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            entered.trip()
            release.trip()
        }
        defer { deadline.cancel(); task.cancel(); release.trip() }
        await entered.wait()
        try #require(await calls.didEnter)
        model.cancel()
        let fresh = makeReview(available: 2_000)
        await model.load(repository: RecordingBudgetRepository(holdReview: { fresh }))
        release.trip()
        await task.value
        #expect(model.amount == 2_000)
        #expect(model.canHold)
    }

    @Test func savingRejectsDoubleSubmitAndDismissalAndIgnoresObsoleteCompletion() async throws {
        let entered = TestLatch()
        let release = TestLatch()
        let requests = Requests()
        let review = makeReview()
        let result = loaded(review)
        let repository = RecordingBudgetRepository(holdReview: { review }, holdApply: { command, received in
            await requests.record(command, review: received)
            entered.trip()
            await release.wait()
            return result
        })
        let model = makeModel()
        await model.load(repository: repository)
        let task = Task { await model.submitHold(repository: repository) }
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            entered.trip()
            release.trip()
        }
        defer { deadline.cancel(); task.cancel(); release.trip() }
        await entered.wait()
        try #require(await requests.commands.count == 1)
        #expect(model.isSaving)
        model.cancel()
        #expect(model.isSaving)
        #expect(!(await model.submitHold(repository: repository)))
        model.invalidate()
        release.trip()
        #expect(!(await task.value))
        #expect(!model.canHold)
        #expect(model.draft == nil)
        #expect(await requests.commands.count == 1)
    }

    @Test func monthContextCrossesYearBoundary() {
        let model = BudgetHoldViewModel(
            target: BudgetHoldTarget(budgetID: "budget", month: "2026-12", modeIdentity: identity),
            locale: Locale(identifier: "en_US")
        )
        #expect(model.monthContext == "Dec 2026 → Jan 2027")
        #expect(model.holdTitle == "Hold for January")
    }

    private func makeModel() -> BudgetHoldViewModel {
        BudgetHoldViewModel(
            target: BudgetHoldTarget(budgetID: "budget", month: "2026-07", modeIdentity: identity),
            locale: Locale(identifier: "en_US")
        )
    }

    private func makeReview(available: Int = 10_000, month: String = "2026-07", identity: BudgetModeIdentity? = nil) -> BudgetHoldReview {
        BudgetHoldReview(month: month, modeIdentity: identity ?? self.identity, currency: .usd,
                         toBudget: available, heldAmount: 5_000)
    }

    private func loaded(_ review: BudgetHoldReview) -> LoadedBudgetMonth {
        LoadedBudgetMonth(
            modeIdentity: review.modeIdentity, availableMonths: [review.month], selectedMonth: review.month,
            month: BudgetMonth(month: review.month, incomeAvailable: 0, lastMonthOverspent: 0,
                               forNextMonth: review.heldAmount, totalBudgeted: 0, toBudget: review.toBudget,
                               fromLastMonth: 0, totalIncome: 0, totalSpent: 0, totalBalance: 0, categoryGroups: []),
            alerts: [], currency: review.currency
        )
    }

    private actor Requests {
        private(set) var commands: [BudgetHoldCommand] = []
        private(set) var reviews: [BudgetHoldReview] = []
        private(set) var didEnter = false
        func noteEntry() { didEnter = true }
        func record(_ command: BudgetHoldCommand, review: BudgetHoldReview) {
            commands.append(command)
            reviews.append(review)
        }
    }
}
