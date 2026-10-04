import Foundation

@MainActor
protocol ScheduleRepositoryProtocol: AnyObject {
    func cachedSchedules(budgetID: String) -> LoadedSchedules?

    /// Schedules the latest automatic posting run skipped. Read-only; replaced
    /// by each run and cleared on budget switch.
    var scheduleAutoPostRefusals: [ScheduleAutoPostRefusal] { get }

    func refreshSchedules(
        budgetID: String,
        asOf today: String
    ) async throws -> LoadedSchedules
}
