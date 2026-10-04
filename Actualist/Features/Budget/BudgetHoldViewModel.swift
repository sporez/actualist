import Foundation
import Observation

@MainActor
@Observable
final class BudgetHoldViewModel {
    struct Draft {
        let review: BudgetHoldReview
        var text: String
        var error: String?
    }

    enum State {
        case idle
        case loading
        case editing(Draft)
        case reviewingRelease(Draft)
        case saving(Draft)
        case failed(String)
        case completed
        case invalidated
    }

    let target: BudgetHoldTarget
    private let locale: Locale
    private var generation = 0
    private(set) var state: State = .idle

    init(target: BudgetHoldTarget, locale: Locale = .current) {
        self.target = target
        self.locale = locale
    }

    var draft: Draft? {
        switch state {
        case .editing(let draft), .reviewingRelease(let draft), .saving(let draft): draft
        default: nil
        }
    }

    var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var isReviewingRelease: Bool {
        if case .reviewingRelease = state { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return draft?.error
    }

    var amountText: String { draft?.text ?? "" }
    var monthTitle: String { BudgetMonthNavigationPresentation.title(for: target.month) }

    private var nextMonth: String { BudgetViewportModel.monthID(target.month, offsetBy: 1) }
    var monthContext: String {
        "\(monthTitle) → \(BudgetMonthNavigationPresentation.title(for: nextMonth))"
    }
    var nextMonthName: String {
        guard let month = try? BudgetTemplateCalendar.parseMonth(nextMonth),
              let date = try? BudgetTemplateCalendar.monthStartDate(month) else { return nextMonth }
        return date.formatted(Date.FormatStyle(
            locale: locale, calendar: BudgetTemplateCalendar.gregorian,
            timeZone: BudgetTemplateCalendar.gregorian.timeZone
        ).month(.wide))
    }
    var holdTitle: String { "Hold for \(nextMonthName)" }
    var hasHeldMoney: Bool { (draft?.review.heldAmount ?? 0) > 0 }

    var amount: Int? {
        guard let draft else { return nil }
        return BudgetHoldAmountInput.amount(
            from: draft.text, available: draft.review.toBudget,
            currency: draft.review.currency, locale: locale
        )
    }

    var amountDisplayText: String {
        guard let draft else { return "—" }
        return amount.map(draft.review.currency.formatted) ?? draft.text
    }

    var canHold: Bool {
        guard canEnterHold, let amount, let draft else { return false }
        let total = draft.review.manualHeldAmount.addingReportingOverflow(amount)
        return !total.overflow && total.partialValue >= 0 && total.partialValue <= Money.maximumUserAmountMinorUnits
    }

    var canEnterHold: Bool {
        guard case .editing(let draft) = state, draft.error == nil else { return false }
        return draft.review.automaticHeldAmount == 0 && draft.review.toBudget > 0
    }

    var holdExplanation: String {
        if draft?.review.automaticHeldAmount != 0 {
            return "This month has an automatic income hold. Release the current hold before holding a different amount. Future months’ automatic holds stay enabled."
        }
        if (draft?.review.toBudget ?? 0) <= 0 {
            return "There is no unassigned money to hold in this month. You can still release an existing hold."
        }
        return "Set aside unassigned money for \(nextMonthName). Bank balances and category assignments won’t change."
    }

    var canRelease: Bool {
        guard case .editing(let draft) = state, draft.error == nil else { return false }
        return draft.review.heldAmount > 0
    }

    var availableText: String { draft.map { $0.review.currency.formatted($0.review.toBudget) } ?? "—" }
    var heldText: String { draft.map { $0.review.currency.formatted($0.review.heldAmount) } ?? "—" }

    var resultingAvailableText: String {
        guard canHold, let draft, let amount else { return "—" }
        return draft.review.currency.formatted(draft.review.toBudget - amount)
    }

    var resultingHeldText: String {
        guard canHold, let draft, let amount else { return "—" }
        return draft.review.currency.formatted(draft.review.manualHeldAmount + amount)
    }

    var releaseTitle: String {
        guard let review = draft?.review else { return "Release Held Money" }
        if review.manualHeldAmount != 0 && review.automaticHeldAmount != 0 { return "Reset Manual Hold" }
        return review.isAutomaticHold ? "Disable Current Auto Hold" : "Release Held Money"
    }

    var releaseConfirmationTitle: String {
        draft?.review.automaticHeldAmount == 0 ? "Release All" : releaseTitle
    }

    var releaseMessage: String {
        guard let review = draft?.review else { return "" }
        if review.manualHeldAmount != 0 && review.automaticHeldAmount != 0 {
            return "Reset the manual hold of \(review.currency.formatted(review.manualHeldAmount))? The automatic hold of \(review.currency.formatted(review.automaticHeldAmount)) will take its place. You can then disable that current auto hold separately."
        }
        if review.isAutomaticHold {
            return "Release \(review.currency.formatted(review.heldAmount)) back to \(monthTitle)? Automatic holds for future months stay enabled."
        }
        return "Release the full \(review.currency.formatted(review.heldAmount)) held for next month back to \(monthTitle)?"
    }

    func setAmountText(_ text: String) {
        guard case .editing(var draft) = state else { return }
        draft.text = text
        state = .editing(draft)
    }

    func useAllAvailable() {
        guard canEnterHold, case .editing(var draft) = state else { return }
        draft.text = BudgetHoldAmountInput.text(
            amount: max(0, draft.review.toBudget), currency: draft.review.currency, locale: locale
        )
        state = .editing(draft)
    }

    func requestRelease() {
        guard canRelease, let draft else { return }
        state = .reviewingRelease(draft)
    }

    func cancelRelease() {
        guard case .reviewingRelease(let draft) = state else { return }
        state = .editing(draft)
    }

    func cancel() {
        guard !isSaving else { return }
        invalidate()
    }

    func invalidate() {
        generation += 1
        state = .invalidated
    }

    func load(using appState: AppState) async {
        guard contextIsCurrent(appState) else { invalidate(); return }
        await load(repository: appState.budgetRepository)
    }

    func prepare(using appState: AppState) async {
        guard case .idle = state else { return }
        await load(using: appState)
    }

    func load(repository: any BudgetRepositoryProtocol) async {
        guard !isSaving else { return }
        generation += 1
        let request = generation
        let previousText = draft?.text
        state = .loading
        do {
            let review = try await repository.budgetHoldReview(budgetID: target.budgetID, month: target.month)
            guard request == generation else { return }
            try Task.checkCancellation()
            guard review.month == target.month, review.modeIdentity == target.modeIdentity else {
                state = .failed(BudgetModeWriteError.budgetChanged.localizedDescription)
                return
            }
            state = .editing(Draft(
                review: review,
                text: previousText ?? BudgetHoldAmountInput.text(
                    amount: max(0, review.toBudget), currency: review.currency, locale: locale
                )
            ))
        } catch {
            guard request == generation else { return }
            state = error.userFacingMessage.map(State.failed) ?? .idle
        }
    }

    /// How a submit ended. `committedButInvalidated` means the repository
    /// committed the write but the sheet was invalidated while it ran, so the
    /// caller must still publish the data mutation.
    enum SubmitOutcome: Equatable {
        case completed
        case failed
        case committedButInvalidated
    }

    func submitHold(using appState: AppState) async -> Bool {
        guard contextIsCurrent(appState) else { invalidate(); return false }
        let outcome = await holdOutcome(repository: appState.budgetRepository)
        return finish(outcome, using: appState)
    }

    func submitRelease(using appState: AppState) async -> Bool {
        guard contextIsCurrent(appState) else { invalidate(); return false }
        let outcome = await releaseOutcome(repository: appState.budgetRepository)
        return finish(outcome, using: appState)
    }

    private func finish(_ outcome: SubmitOutcome, using appState: AppState) -> Bool {
        if outcome != .failed { appState.recordLocalDataMutation() }
        guard contextIsCurrent(appState) else { invalidate(); return false }
        return outcome == .completed
    }

    func submitHold(repository: any BudgetRepositoryProtocol) async -> Bool {
        await holdOutcome(repository: repository) == .completed
    }

    func submitRelease(repository: any BudgetRepositoryProtocol) async -> Bool {
        await releaseOutcome(repository: repository) == .completed
    }

    func holdOutcome(repository: any BudgetRepositoryProtocol) async -> SubmitOutcome {
        guard canHold, let amount else { return .failed }
        return await submit(.hold(amount: amount), repository: repository)
    }

    func releaseOutcome(repository: any BudgetRepositoryProtocol) async -> SubmitOutcome {
        // SwiftUI may dismiss the alert binding before its action's Task starts.
        guard isReviewingRelease || canRelease else { return .failed }
        return await submit(.reset, repository: repository)
    }

    private func submit(_ command: BudgetHoldCommand, repository: any BudgetRepositoryProtocol) async -> SubmitOutcome {
        guard var draft else { return .failed }
        let request = generation
        state = .saving(draft)
        do {
            let loaded = try await repository.applyBudgetHoldAndRefresh(
                command: command, review: draft.review, budgetID: target.budgetID
            )
            // The repository already committed. Invalidation only means the sheet
            // no longer owns the result, so callers must still publish it.
            guard request == generation else { return .committedButInvalidated }
            guard loaded.selectedMonth == target.month, loaded.modeIdentity == target.modeIdentity else {
                invalidate()
                return .committedButInvalidated
            }
            state = .completed
            return .completed
        } catch {
            guard request == generation else { return .failed }
            draft.error = error.userFacingMessage
            state = .editing(draft)
            return .failed
        }
    }

    private func contextIsCurrent(_ appState: AppState) -> Bool {
        appState.settings.selectedBudgetID == target.budgetID
            && !appState.settings.randomizedDisplayValuesEnabled
    }
}
