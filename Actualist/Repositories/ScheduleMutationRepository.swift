import Foundation

enum ScheduleAmountDraft: Hashable, Sendable {
    case exact(Int)
    case approximate(Int)
    case range(lower: Int, upper: Int)
}

struct ScheduleDefinitionDraft: Hashable, Sendable {
    let accountID: String
    let payeeMappingID: String?
    let amount: ScheduleAmountDraft
    let dateRule: ScheduleDateRule
}

struct ScheduleCreateIdentity: Hashable, Sendable {
    let scheduleID: String
    let ruleID: String
    let nextDateID: String
}

struct ScheduleCreateCommand: Hashable, Sendable {
    let budgetID: String
    let identity: ScheduleCreateIdentity
    let name: String?
    let definition: ScheduleDefinitionDraft
    let postsTransaction: Bool
    let customUpcomingLength: String?
    let asOfDayID: String
}

enum ScheduleOptionalChange<Value: Hashable & Sendable>: Hashable, Sendable {
    case unchanged
    case set(Value?)
}

struct ScheduleEditFields: Hashable, Sendable {
    var name: ScheduleOptionalChange<String> = .unchanged
    var accountID: ScheduleOptionalChange<String> = .unchanged
    var payeeMappingID: ScheduleOptionalChange<String> = .unchanged
    var amount: ScheduleOptionalChange<ScheduleAmountDraft> = .unchanged
    var dateRule: ScheduleOptionalChange<ScheduleDateRule> = .unchanged
    var postsTransaction: Bool?
    var customUpcomingLength: ScheduleOptionalChange<String> = .unchanged
    var resetNextDate = false

    var changesDefinition: Bool {
        accountID != .unchanged || payeeMappingID != .unchanged
            || amount != .unchanged || dateRule != .unchanged
    }

    var isEmpty: Bool {
        name == .unchanged && !changesDefinition && postsTransaction == nil
            && customUpcomingLength == .unchanged && !resetNextDate
    }
}

struct ScheduleMutationReview: Hashable, Sendable {
    let budgetID: String
    let scheduleID: String
    let ruleID: String
    let schedule: ScheduleRowRevision
    let rule: ScheduleRuleRevision
    let nextDates: [ScheduleNextDateRevision]
    let account: ScheduleAccountRevision?

    var uniqueNextDate: ScheduleNextDateRevision? {
        let liveRows = nextDates.filter { !$0.tombstone }
        return liveRows.count == 1 ? liveRows[0] : nil
    }
}

struct ScheduleRowRevision: Hashable, Sendable {
    let name: String?
    let completed: Bool
    let postsTransaction: Bool
    let customUpcomingLength: String?
    let sortOrder: Double?
    let tombstone: Bool
    let active: Bool
}

struct ScheduleRuleRevision: Hashable, Sendable {
    let conditionsJSON: String?
    let actionsJSON: String?
    let stage: String?
    let conditionsOperation: String?
    let tombstone: Bool
}

struct ScheduleNextDateRevision: Hashable, Sendable {
    let id: String
    let localDate: String?
    let localTimestamp: String?
    let baseDate: String?
    let baseTimestamp: String?
    let tombstone: Bool

    var effectiveDate: String? {
        let raw = localTimestamp != nil && localTimestamp == baseTimestamp ? localDate : baseDate
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 8, trimmed.allSatisfy(\.isNumber) {
            return "\(trimmed.prefix(4))-\(trimmed.dropFirst(4).prefix(2))-\(trimmed.suffix(2))"
        }
        return trimmed
    }
}

struct ScheduleAccountRevision: Hashable, Sendable {
    let id: String
    let name: String?
    let offBudget: Bool
    let isClosed: Bool
    let tombstone: Bool
}

enum ScheduleMutationKind: Hashable, Sendable {
    case created
    case updated
    case deleted
    case skipped
    case completed
    case unchanged
}

struct ScheduleMutationResult: Hashable, Sendable {
    let scheduleID: String
    let kind: ScheduleMutationKind
    let appliedMessageCount: Int
}

struct ScheduleMutationSessionContext: Hashable, Sendable {
    let budgetID: String
    let generation: Int
}

struct ReviewedScheduleMutation: Hashable, Sendable {
    let context: ScheduleMutationSessionContext
    let revision: ScheduleMutationReview
}

struct ScheduleMutationOutcome: Hashable, Sendable {
    let receipt: ScheduleMutationResult
    let refreshPending: Bool
}

enum ScheduleMutationCommandError: Error, Hashable, Sendable {
    case reviewChanged
    case identityConflict
    case duplicateName
    case unsupportedCapability(String)
    case invalidCommand(String)
}

extension ScheduleMutationCommandError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .reviewChanged:
            "This schedule changed. Review its latest details and try again."
        case .identityConflict:
            "This schedule could not be created because its identity is already in use."
        case .duplicateName:
            "A live schedule already uses this name."
        case .unsupportedCapability(let message), .invalidCommand(let message):
            message
        }
    }
}

@MainActor
protocol ScheduleMutationRepositoryProtocol: AnyObject {
    func scheduleMutationSessionContext(budgetID: String) throws -> ScheduleMutationSessionContext
    func scheduleMutationReview(budgetID: String, scheduleID: String) async throws -> ReviewedScheduleMutation
    func createSchedule(
        _ command: ScheduleCreateCommand,
        context: ScheduleMutationSessionContext
    ) async throws -> ScheduleMutationOutcome
    func updateSchedule(
        review: ReviewedScheduleMutation,
        fields: ScheduleEditFields,
        asOfDayID: String,
        now: Date
    ) async throws -> ScheduleMutationOutcome
    func deleteSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome
    func skipNextDate(review: ReviewedScheduleMutation, now: Date) async throws -> ScheduleMutationOutcome
    func completeSchedule(review: ReviewedScheduleMutation) async throws -> ScheduleMutationOutcome
}
