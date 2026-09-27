import Foundation
import Observation

@MainActor
@Observable
final class SchedulesViewModel {
    private let currency: BudgetCurrency
    private(set) var budgetID: String?
    private(set) var snapshot: LoadedSchedules?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    var searchText = ""
    var showsCompleted = false

    @ObservationIgnored private var loadGeneration = 0

    init(currency: BudgetCurrency = .usd) {
        self.currency = currency
    }

    var sections: [ScheduleListSection] {
        let schedules = filteredSchedules
        return ScheduleListSectionKind.allCases.compactMap { kind in
            if kind == .completed && !showsCompleted { return nil }
            let matching = schedules.filter { SchedulePresentation.section(for: $0.status) == kind }
            return matching.isEmpty ? nil : ScheduleListSection(kind: kind, schedules: matching)
        }
    }

    var activeScheduleCount: Int {
        snapshot?.schedules.count { $0.status != .completed } ?? 0
    }

    var completedScheduleCount: Int {
        snapshot?.schedules.count { $0.status == .completed } ?? 0
    }

    var isEmpty: Bool {
        snapshot?.schedules.isEmpty == true && !isLoading
    }

    func detail(id: String) -> ScheduleDetail? {
        snapshot?.detail(id: id)
    }

    func load(
        budgetID: String,
        repository: any ScheduleRepositoryProtocol,
        today: String
    ) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        if self.budgetID != budgetID {
            self.budgetID = budgetID
            snapshot = nil
            searchText = ""
            showsCompleted = false
        }

        if let cached = repository.cachedSchedules(budgetID: budgetID),
           cached.budgetID == budgetID {
            snapshot = cached
        }
        isLoading = snapshot == nil
        isRefreshing = snapshot != nil
        errorMessage = nil

        do {
            let refreshed = try await repository.refreshSchedules(budgetID: budgetID, asOf: today)
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  self.budgetID == budgetID,
                  refreshed.budgetID == budgetID else { return }
            snapshot = refreshed
            isLoading = false
            isRefreshing = false
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            isLoading = false
            isRefreshing = false
        } catch {
            guard generation == loadGeneration, self.budgetID == budgetID else { return }
            guard !Task.isCancelled else {
                isLoading = false
                isRefreshing = false
                return
            }
            errorMessage = error.userFacingMessage
            isLoading = false
            isRefreshing = false
        }
    }

    func cancelLoad() {
        loadGeneration &+= 1
        isLoading = false
        isRefreshing = false
    }

    private var filteredSchedules: [ScheduleSummary] {
        guard let schedules = snapshot?.schedules else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return schedules }
        let normalizedQuery = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return schedules.filter { schedule in
            SchedulePresentation.searchableText(schedule, currency: currency)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(normalizedQuery)
        }
    }
}
