import Foundation

@MainActor
protocol ScheduleRepositoryProtocol: AnyObject {
    func cachedSchedules(budgetID: String) -> LoadedSchedules?

    func refreshSchedules(
        budgetID: String,
        asOf today: String
    ) async throws -> LoadedSchedules
}
