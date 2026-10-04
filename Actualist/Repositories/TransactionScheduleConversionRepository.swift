import Foundation

struct ScheduleConversionTransactionFact: Hashable, Sendable {
    let transaction: ActualTransaction
    let rawPayeeID: String?
    let transferID: String?
    let isTransferPayee: Bool
}

struct ScheduleConversionSessionContext: Hashable, Sendable {
    let budgetID: String
    let generation: Int
}

struct ScheduleConversionIdentity: Hashable, Sendable {
    let scheduleID: String
    let ruleID: String
    let nextDateID: String

    static func make() -> ScheduleConversionIdentity {
        ScheduleConversionIdentity(
            scheduleID: UUID().uuidString,
            ruleID: UUID().uuidString,
            nextDateID: UUID().uuidString
        )
    }
}

struct ScheduleConversionReview: Hashable, Sendable {
    let context: ScheduleConversionSessionContext
    let sourceTransactionID: String
    let asOfDayID: String
    let identity: ScheduleConversionIdentity
    let family: [ScheduleConversionTransactionFact]

    var source: ActualTransaction? { family.first?.transaction }
    var sourceTransactionIDs: [String] { family.map { $0.transaction.id ?? "" } }
}

struct ScheduleConversionReceipt: Hashable, Sendable {
    let scheduleID: String
    let sourceTransactionIDs: [String]
    let appliedMessageCount: Int
    let refreshPending: Bool
}

enum ScheduleConversionError: Error, Hashable, Sendable {
    case reviewChanged
    case transactionNotFuture
    case unsupportedSource(String)
    case unsupportedSchema
    case identityConflict
}

extension ScheduleConversionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .reviewChanged:
            "This transaction changed or the selected budget session ended. Review it again before converting."
        case .transactionNotFuture:
            "Only a transaction dated after today can be converted to a schedule."
        case .unsupportedSource(let reason): reason
        case .unsupportedSchema: ScheduleMutationUserNotice.unsupportedBudgetSchedules
        case .identityConflict:
            "This schedule could not be created because its identity is already in use."
        }
    }
}

@MainActor
protocol TransactionScheduleConversionRepositoryProtocol: AnyObject {
    func scheduleConversionSessionContext(budgetID: String) throws -> ScheduleConversionSessionContext
    func scheduleConversionReview(
        budgetID: String,
        transactionID: String,
        asOfDayID: String
    ) async throws -> ScheduleConversionReview
    func convertFutureTransaction(
        review: ScheduleConversionReview
    ) async throws -> ScheduleConversionReceipt
}
