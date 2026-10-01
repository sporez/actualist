import Foundation
import Observation

enum ScheduleManagementAction: String, Identifiable, Sendable {
    case delete
    case skip
    case complete

    var id: String { rawValue }
    var title: String {
        switch self {
        case .delete: "Delete Schedule"
        case .skip: "Skip Next Date"
        case .complete: "Mark Completed"
        }
    }
}

struct ScheduleEditorSession: Hashable, Sendable {
    let identity: ScheduleMutationSessionContext
    let originalReview: ReviewedScheduleMutation?
    let scheduleID: String?
    let createIdentity: ScheduleCreateIdentity?
    let capabilities: ScheduleMutationCapabilities
    let choices: ScheduleEditorChoices
    let currency: BudgetCurrency
    let asOfDayID: String
    let isPrivacyModeEnabled: Bool
    var draft: ScheduleEditorDraft
    var notice: String?

    var canEditDate: Bool {
        capabilities.canEditDate && !draft.hasUnsupportedDatePatterns
    }
}

struct ScheduleActionReview: Hashable, Sendable {
    let action: ScheduleManagementAction
    let reviewed: ReviewedScheduleMutation
    let detail: ScheduleDetail
    let currency: BudgetCurrency
    let isPrivacyModeEnabled: Bool
}

enum ScheduleManagementState: Hashable, Sendable {
    case idle
    case loading(String)
    case editing(ScheduleEditorSession)
    case reviewingSave(ScheduleEditorSession)
    case reviewingAction(ScheduleActionReview)
    case submitting(String)
    case committed(ScheduleMutationOutcome)
    case noChanges(ScheduleMutationOutcome)
    case failed(String)

    var isSubmitting: Bool {
        if case .submitting = self { return true }
        return false
    }
}

@MainActor
@Observable
final class ScheduleManagementCoordinator {
    private(set) var state: ScheduleManagementState = .idle
    private(set) var contentRevision: UInt64 = 0

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    var isPresented: Bool {
        get { state != .idle }
        set { if !newValue { cancel() } }
    }

    var isSubmitting: Bool { state.isSubmitting }

    func beginCreate(
        expectedBudgetID: String,
        expectedGeneration: Int,
        today: String,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool,
        mutationRepository: any ScheduleMutationRepositoryProtocol,
        transactionRepository: any TransactionRepositoryProtocol
    ) {
        guard !isSubmitting else { return }
        let request = beginRequest(title: "Loading Schedule Editor")
        let context: ScheduleMutationSessionContext
        do {
            context = try mutationRepository.scheduleMutationSessionContext(budgetID: expectedBudgetID)
            guard contextMatches(context, budgetID: expectedBudgetID, generation: expectedGeneration) else {
                state = .failed("The selected budget changed. Reopen Schedules before adding a schedule.")
                finish(request)
                return
            }
        } catch {
            state = .failed(message(for: error))
            finish(request)
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let options = try await transactionRepository.editorOptions(
                    budgetID: expectedBudgetID,
                    month: String(today.prefix(7))
                )
                try Task.checkCancellation()
                guard isCurrent(request), currentContextMatches(
                    context,
                    expectedBudgetID: expectedBudgetID,
                    expectedGeneration: expectedGeneration,
                    repository: mutationRepository
                ) else { return }
                guard isCurrent(request) else { return }
                let draft = ScheduleEditorDraft(todayDayID: today)
                state = .editing(ScheduleEditorSession(
                    identity: context,
                    originalReview: nil,
                    scheduleID: nil,
                    createIdentity: ScheduleCreateIdentity(
                        scheduleID: UUID().uuidString,
                        ruleID: UUID().uuidString,
                        nextDateID: UUID().uuidString
                    ),
                    capabilities: Self.createCapabilities,
                    choices: .project(options, privacyEnabled: isPrivacyModeEnabled),
                    currency: currency,
                    asOfDayID: today,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    draft: draft
                ))
                finish(request)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func beginEdit(
        detail: ScheduleDetail,
        expectedBudgetID: String,
        expectedGeneration: Int,
        today: String,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool,
        scheduleRepository: any ScheduleRepositoryProtocol,
        mutationRepository: any ScheduleMutationRepositoryProtocol,
        transactionRepository: any TransactionRepositoryProtocol
    ) {
        guard !isSubmitting else { return }
        let request = beginRequest(title: "Loading Schedule Editor")
        let context: ScheduleMutationSessionContext
        do {
            context = try mutationRepository.scheduleMutationSessionContext(budgetID: expectedBudgetID)
            guard contextMatches(context, budgetID: expectedBudgetID, generation: expectedGeneration) else {
                state = .failed("The selected budget changed. Reopen Schedules before editing this schedule.")
                finish(request)
                return
            }
        } catch {
            state = .failed(message(for: error))
            finish(request)
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reviewed = try await mutationRepository.scheduleMutationReview(
                    budgetID: expectedBudgetID,
                    scheduleID: detail.id
                )
                try Task.checkCancellation()
                guard isCurrent(request) else { return }
                let options = try await transactionRepository.editorOptions(
                    budgetID: expectedBudgetID,
                    month: String(today.prefix(7))
                )
                try Task.checkCancellation()
                guard isCurrent(request) else { return }
                guard reviewed.context == context, currentContextMatches(
                        context,
                        expectedBudgetID: expectedBudgetID,
                        expectedGeneration: expectedGeneration,
                        repository: mutationRepository
                      ) else {
                    state = .failed("The selected budget changed while the schedule was loading. Reopen Schedules and try again.")
                    finish(request)
                    return
                }
                let loaded = try await scheduleRepository.refreshSchedules(budgetID: expectedBudgetID, asOf: today)
                try Task.checkCancellation()
                guard isCurrent(request), loaded.budgetID == expectedBudgetID,
                      currentContextMatches(
                        context,
                        expectedBudgetID: expectedBudgetID,
                        expectedGeneration: expectedGeneration,
                        repository: mutationRepository
                      ),
                      let currentDetail = loaded.detail(id: detail.id) else {
                    state = .failed("This schedule is no longer available in the selected budget.")
                    finish(request)
                    return
                }
                let draft = ScheduleEditorDraft(review: reviewed.revision, detail: currentDetail, currency: currency)
                state = .editing(ScheduleEditorSession(
                    identity: context,
                    originalReview: reviewed,
                    scheduleID: detail.id,
                    createIdentity: nil,
                    capabilities: currentDetail.capabilities,
                    choices: .project(options, privacyEnabled: isPrivacyModeEnabled),
                    currency: currency,
                    asOfDayID: today,
                    isPrivacyModeEnabled: isPrivacyModeEnabled,
                    draft: draft
                ))
                finish(request)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func beginActionReview(
        _ action: ScheduleManagementAction,
        detail: ScheduleDetail,
        expectedBudgetID: String,
        expectedGeneration: Int,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool,
        today: String,
        scheduleRepository: any ScheduleRepositoryProtocol,
        mutationRepository: any ScheduleMutationRepositoryProtocol
    ) {
        guard !isSubmitting else { return }
        let request = beginRequest(title: "Preparing Schedule Review")
        let context: ScheduleMutationSessionContext
        do {
            context = try mutationRepository.scheduleMutationSessionContext(budgetID: expectedBudgetID)
            guard contextMatches(context, budgetID: expectedBudgetID, generation: expectedGeneration) else {
                state = .failed("The selected budget changed. Reopen Schedules before continuing.")
                finish(request)
                return
            }
        } catch {
            state = .failed(message(for: error))
            finish(request)
            return
        }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reviewed = try await mutationRepository.scheduleMutationReview(
                    budgetID: expectedBudgetID,
                    scheduleID: detail.id
                )
                guard isCurrent(request) else { return }
                guard reviewed.context == context else {
                    state = .failed("The selected budget changed while the schedule was loading. Reopen Schedules and try again.")
                    finish(request)
                    return
                }
                let loaded = try await scheduleRepository.refreshSchedules(budgetID: expectedBudgetID, asOf: today)
                try Task.checkCancellation()
                guard isCurrent(request), currentContextMatches(
                    context,
                    expectedBudgetID: expectedBudgetID,
                    expectedGeneration: expectedGeneration,
                    repository: mutationRepository
                ), loaded.budgetID == expectedBudgetID,
                   let currentDetail = loaded.detail(id: detail.id) else {
                    guard isCurrent(request) else { return }
                    state = .failed("This schedule is no longer available in the selected budget.")
                    finish(request)
                    return
                }
                let allowed: Bool
                switch action {
                case .delete: allowed = currentDetail.capabilities.canDelete
                case .skip: allowed = currentDetail.capabilities.canSkip
                case .complete: allowed = currentDetail.capabilities.canComplete
                }
                guard allowed else {
                    state = .failed("This action is not available for the current schedule definition.")
                    finish(request)
                    return
                }
                state = .reviewingAction(ScheduleActionReview(
                    action: action,
                    reviewed: reviewed,
                    detail: currentDetail,
                    currency: currency,
                    isPrivacyModeEnabled: isPrivacyModeEnabled
                ))
                finish(request)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func updateDraft(_ update: (inout ScheduleEditorDraft) -> Void) {
        guard case .editing(var session) = state else { return }
        update(&session.draft)
        session.notice = nil
        state = .editing(session)
    }

    func setName(_ value: String) { updateDraft { $0.name = value; $0.nameWasChanged = true } }
    func setAccount(_ value: String?) { updateDraft { $0.accountID = value; $0.accountWasChanged = true } }
    func setPayee(_ value: String?) { updateDraft { $0.payeeID = value; $0.payeeWasChanged = true } }
    func setAmountMode(_ value: ScheduleEditorAmountMode) { updateDraft { $0.amountMode = value; $0.amountWasChanged = true } }
    func setAmount(_ value: String) {
        updateDraft {
            $0.amountText = value
            $0.amountInputWasEdited = true
            $0.amountWasChanged = true
        }
    }
    func setRangeEnd(_ value: String) {
        updateDraft {
            $0.rangeEndText = value
            $0.rangeEndInputWasEdited = true
            $0.amountWasChanged = true
        }
    }
    func setDateMode(_ value: ScheduleEditorDateMode) {
        updateDraft {
            if $0.dateMode != value, value == .recurring { $0.recurrenceStartDayID = $0.oneTimeDayID }
            if $0.dateMode != value, value == .oneTime { $0.oneTimeDayID = $0.recurrenceStartDayID }
            $0.dateMode = value
            $0.dateWasChanged = true
        }
    }
    func setDay(_ value: Date, recurringStart: Bool) {
        updateDraft {
            let dayID = ScheduleEditorDraft.dayID(from: value)
            if recurringStart { $0.recurrenceStartDayID = dayID } else { $0.oneTimeDayID = dayID }
            $0.dateWasChanged = true
        }
    }
    func setFrequency(_ value: ActualScheduleFrequency) {
        updateDraft {
            $0.frequency = value
            if value != .monthly { $0.patterns = [] }
            $0.dateWasChanged = true
        }
    }
    func setInterval(_ value: String) { updateDraft { $0.intervalText = value; $0.dateWasChanged = true } }
    func setOperation(_ value: String) { updateDraft { $0.operation = value; $0.dateWasChanged = true } }
    func addMonthlyDayPattern() { updateDraft { $0.addMonthlyDayPattern() } }
    func addMonthlyWeekdayPattern() { updateDraft { $0.addMonthlyWeekdayPattern() } }
    func replacePattern(at index: Int, with pattern: ActualSchedulePattern) {
        updateDraft { $0.replacePattern(at: index, with: pattern) }
    }
    func removePattern(at index: Int) { updateDraft { $0.removePattern(at: index) } }
    func setEndingMode(_ mode: ScheduleEditorEndingMode) {
        updateDraft {
            switch mode {
            case .never: $0.ending = .never
            case .afterOccurrences: $0.ending = .afterOccurrences(Int($0.endingCountText) ?? 12)
            case .onDate: $0.ending = .onDate($0.endingDayID)
            }
            $0.dateWasChanged = true
        }
    }
    func setSkipWeekend(_ value: Bool) { updateDraft { $0.skipWeekend = value; $0.dateWasChanged = true } }
    func setWeekendAdjustment(_ value: ActualScheduleWeekendAdjustment) { updateDraft { $0.weekendAdjustment = value; $0.dateWasChanged = true } }
    func setEnding(_ value: ActualScheduleEnding) { updateDraft { $0.ending = value; $0.dateWasChanged = true } }
    func setEndingCount(_ value: String) { updateDraft { $0.ending = .afterOccurrences(Int(value) ?? 0); $0.endingCountText = value; $0.dateWasChanged = true } }
    func setEndingDay(_ value: Date) { updateDraft { $0.endingDayID = ScheduleEditorDraft.dayID(from: value); $0.ending = .onDate($0.endingDayID); $0.dateWasChanged = true } }
    func setPostsTransaction(_ value: Bool) { updateDraft { $0.postsTransaction = value; $0.postingWasChanged = true } }
    func setUpcomingLength(_ value: String?) { updateDraft { $0.upcomingLength = value; $0.upcomingWasChanged = true } }

    func reviewSave(locale: Locale) {
        guard case .editing(let session) = state,
              session.capabilities.canEdit else { return }
        guard session.draft.canReview(
            isCreate: session.originalReview == nil,
            capabilities: session.capabilities,
            currency: session.currency,
            locale: locale
        ) else {
            state = .editing(session.withNotice(session.draft.validationMessage(
                isCreate: session.originalReview == nil,
                capabilities: session.capabilities,
                currency: session.currency,
                locale: locale
            )))
            return
        }
        state = .reviewingSave(session)
    }

    func backToEditor() {
        if case .reviewingSave(let session) = state { state = .editing(session) }
    }

    func confirmSave(
        locale: Locale,
        mutationRepository: any ScheduleMutationRepositoryProtocol
    ) {
        guard case .reviewingSave(let session) = state, !isSubmitting else { return }
        guard currentContextMatches(
                session.identity,
                expectedBudgetID: session.identity.budgetID,
                expectedGeneration: session.identity.generation,
                repository: mutationRepository
              ) else {
            state = .failed("The selected budget changed. Reopen Schedules before saving this schedule.")
            return
        }
        let fields = session.draft.editFields(currency: session.currency, locale: locale)
        if let fields, fields.isEmpty {
            state = .idle
            return
        }
        guard session.originalReview != nil || session.draft.createDefinition(currency: session.currency, locale: locale) != nil else {
            state = .editing(session.withNotice("Enter a valid account, amount, and date."))
            return
        }
        let request = beginRequest(title: "Saving Schedule")
        let context = session.identity
        state = .submitting("Saving Schedule")
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: ScheduleMutationOutcome
                if let reviewed = session.originalReview {
                    guard let fields else {
                        state = .editing(session.withNotice("Enter a valid amount and date."))
                        finish(request)
                        return
                    }
                    result = try await mutationRepository.updateSchedule(
                        review: reviewed,
                        fields: fields,
                        asOfDayID: session.asOfDayID,
                        now: Date()
                    )
                } else {
                    guard let identity = session.createIdentity,
                          let definition = session.draft.createDefinition(currency: session.currency, locale: locale) else {
                        state = .editing(session.withNotice("Enter a valid account, amount, and date."))
                        finish(request)
                        return
                    }
                    let command = ScheduleCreateCommand(
                        budgetID: context.budgetID,
                        identity: identity,
                        name: session.draft.name,
                        definition: definition,
                        postsTransaction: session.draft.postsTransaction,
                        customUpcomingLength: session.draft.upcomingLength,
                        asOfDayID: session.asOfDayID
                    )
                    result = try await mutationRepository.createSchedule(command, context: context)
                }
                guard currentContextMatches(
                    context,
                    expectedBudgetID: context.budgetID,
                    expectedGeneration: context.generation,
                    repository: mutationRepository
                ) else {
                    finishMutation(request, outcome: result)
                    return
                }
                finishMutation(request, outcome: result)
            } catch {
                guard isCurrent(request) else { return }
                if let commandError = error as? ScheduleMutationCommandError {
                    switch commandError {
                    case .reviewChanged, .identityConflict:
                        state = .failed(message(for: error))
                    case .duplicateName, .unsupportedCapability(_), .invalidCommand(_):
                        state = .editing(session.withNotice(message(for: error)))
                    }
                } else {
                    state = .editing(session.withNotice(message(for: error)))
                }
                finish(request)
            }
        }
    }

    func confirmAction(
        now: Date = Date(),
        mutationRepository: any ScheduleMutationRepositoryProtocol
    ) {
        guard case .reviewingAction(let review) = state, !isSubmitting else { return }
        guard currentContextMatches(
                review.reviewed.context,
                expectedBudgetID: review.reviewed.context.budgetID,
                expectedGeneration: review.reviewed.context.generation,
                repository: mutationRepository
              ) else {
            state = .failed("The selected budget changed. Reopen Schedules before continuing.")
            return
        }
        let request = beginRequest(title: review.action.title)
        state = .submitting(review.action.title)
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome: ScheduleMutationOutcome
                switch review.action {
                case .delete:
                    outcome = try await mutationRepository.deleteSchedule(review: review.reviewed)
                case .skip:
                    outcome = try await mutationRepository.skipNextDate(review: review.reviewed, now: now)
                case .complete:
                    outcome = try await mutationRepository.completeSchedule(review: review.reviewed)
                }
                guard currentContextMatches(
                    review.reviewed.context,
                    expectedBudgetID: review.reviewed.context.budgetID,
                    expectedGeneration: review.reviewed.context.generation,
                    repository: mutationRepository
                ) else {
                    finishMutation(request, outcome: outcome)
                    return
                }
                finishMutation(request, outcome: outcome)
            } catch {
                guard isCurrent(request) else { return }
                state = .failed(message(for: error))
                finish(request)
            }
        }
    }

    func finishCommitted() {
        guard isCommittedOrNoChanges else { return }
        state = .idle
    }

    @discardableResult
    func cancel() -> Task<Void, Never>? {
        guard !isSubmitting else { return nil }
        let canceledOperation = operationTask
        canceledOperation?.cancel()
        operationTask = nil
        generation &+= 1
        state = .idle
        return canceledOperation
    }

    func dismissFailure() {
        guard !isSubmitting else { return }
        cancel()
    }

    private func beginRequest(title: String) -> Int {
        operationTask?.cancel()
        generation &+= 1
        state = .loading(title)
        return generation
    }

    private func finish(_ request: Int) {
        guard generation == request else { return }
        operationTask = nil
    }

    private func finishMutation(_ request: Int, outcome: ScheduleMutationOutcome) {
        if outcome.receipt.kind == .unchanged {
            state = .noChanges(outcome)
        } else {
            state = .committed(outcome)
            contentRevision &+= 1
        }
        finish(request)
    }

    private var isCommittedOrNoChanges: Bool {
        switch state {
        case .committed, .noChanges: true
        default: false
        }
    }

    private func isCurrent(_ request: Int) -> Bool {
        generation == request && !Task.isCancelled
    }

    private func currentContextMatches(
        _ expected: ScheduleMutationSessionContext,
        expectedBudgetID: String,
        expectedGeneration: Int,
        repository: any ScheduleMutationRepositoryProtocol
    ) -> Bool {
        guard let current = try? repository.scheduleMutationSessionContext(budgetID: expectedBudgetID) else {
            return false
        }
        return current == expected && contextMatches(
            current,
            budgetID: expectedBudgetID,
            generation: expectedGeneration
        )
    }

    private func contextMatches(
        _ context: ScheduleMutationSessionContext,
        budgetID: String,
        generation: Int
    ) -> Bool {
        context.budgetID == budgetID && context.generation == generation
    }

    private func message(for error: Error) -> String {
        switch error {
        case let commandError as ScheduleMutationCommandError:
            ScheduleMutationUserNotice.commandError(commandError)
        case let localFirstError as LocalFirstError:
            // Unwrapped local-write refusals carry internal detail strings.
            if case .invalidLocalWrite = localFirstError { ScheduleMutationUserNotice.saveFailed }
            else { localFirstError.errorDescription ?? ScheduleMutationUserNotice.saveFailed }
        default:
            error.userFacingMessage ?? ScheduleMutationUserNotice.saveFailed
        }
    }

    private static let createCapabilities = ScheduleMutationCapabilities(
        canRead: true,
        canEditMetadata: true,
        canEditAccount: true,
        canEditPayee: true,
        canEditAmount: true,
        canEditDate: true,
        canSkip: true,
        canComplete: true,
        canDelete: true,
        canPost: false
    )
}

private extension ScheduleEditorSession {
    func withNotice(_ notice: String?) -> ScheduleEditorSession {
        var copy = self
        copy.notice = notice
        return copy
    }
}

/// Single source of tester-voiced copy for schedule write failures that reach
/// feature coordinators. Raw database details (for example "missing column
/// schedules.posts_transaction" from budgets saved by older versions of
/// Actual) must never reach the UI.
enum ScheduleMutationUserNotice {
    static let unsupportedBudgetSchedules =
        "This budget's schedule data is from an older version of Actual, so schedules can't be changed in Actualist yet."
    static let saveFailed =
        "Actualist couldn't save this schedule. Try again."

    static func commandError(_ error: ScheduleMutationCommandError) -> String {
        switch error {
        case .reviewChanged, .identityConflict, .duplicateName, .invalidCommand:
            error.errorDescription ?? saveFailed
        case .unsupportedCapability(let detail):
            capabilityDetail(detail)
        }
    }

    static func conversionSource(_ reason: String) -> String {
        capabilityDetail(reason)
    }

    static func capabilityDetail(_ detail: String) -> String {
        isInternalSchemaDetail(detail) ? unsupportedBudgetSchedules : detail
    }

    private static func isInternalSchemaDetail(_ detail: String) -> Bool {
        detail.contains("missing column ")
            || (detail.hasPrefix("missing ") && detail.hasSuffix(" table"))
    }
}
