import Foundation
import Observation

@MainActor
@Observable
final class SchedulesViewModel {
    private(set) var context: SchedulesViewContext
    private(set) var loadedIdentity: SchedulesBudgetIdentity?
    private(set) var snapshot: LoadedSchedules?
    private(set) var isLoading = true
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    var searchText = ""
    var showsCompleted = false

    @ObservationIgnored private var loadGeneration = 0

    init(context: SchedulesViewContext) {
        self.context = context
    }

    var budgetID: String? { loadedIdentity?.budgetID }

    var sections: [ScheduleListSection] {
        let rows = filteredRows
        return ScheduleListSectionKind.allCases.compactMap { kind in
            if kind == .completed && !showsCompleted { return nil }
            let matching = rows.filter { SchedulePresentation.section(for: $0.status) == kind }
            return matching.isEmpty ? nil : ScheduleListSection(kind: kind, rows: matching)
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

    var emptyState: ScheduleListEmptyState {
        guard snapshot != nil, !isLoading, sections.isEmpty else { return .none }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .noMatches
        }
        if completedScheduleCount > 0 && !showsCompleted {
            return .noActiveSchedules
        }
        return .noSchedules
    }

    func detailPresentation(id: String) -> ScheduleDetailPresentation? {
        guard let snapshot, let detail = snapshot.detail(id: id) else { return nil }
        return SchedulePresentation.detail(
            detail,
            defaultUpcomingLength: snapshot.defaultUpcomingLength,
            context: context
        )
    }

    func load(
        context: SchedulesViewContext,
        repository: any ScheduleRepositoryProtocol
    ) async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let previousIdentity = loadedIdentity
        let identityChanged = previousIdentity != context.identity
        let sessionChangedForBudget = previousIdentity?.budgetID == context.identity.budgetID
            && previousIdentity?.sessionGeneration != context.identity.sessionGeneration
        let displayChanged = self.context.currency != context.currency
            || self.context.isPrivacyModeEnabled != context.isPrivacyModeEnabled
        self.context = context
        if identityChanged {
            loadedIdentity = context.identity
            snapshot = nil
            searchText = ""
            showsCompleted = false
        } else if displayChanged {
            searchText = ""
        }

        let budgetID = context.identity.budgetID
        if !sessionChangedForBudget,
           let cached = repository.cachedSchedules(budgetID: budgetID),
           cached.budgetID == budgetID {
            snapshot = cached
        }
        isLoading = snapshot == nil
        isRefreshing = snapshot != nil
        errorMessage = nil

        do {
            let refreshed = try await repository.refreshSchedules(
                budgetID: budgetID,
                asOf: context.asOfDayID
            )
            try Task.checkCancellation()
            guard generation == loadGeneration,
                  self.context == context,
                  loadedIdentity == context.identity,
                  refreshed.budgetID == budgetID else { return }
            snapshot = refreshed
            isLoading = false
            isRefreshing = false
        } catch is CancellationError {
            guard generation == loadGeneration else { return }
            isLoading = false
            isRefreshing = false
        } catch {
            guard generation == loadGeneration,
                  self.context == context,
                  loadedIdentity == context.identity else { return }
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

    private var filteredRows: [ScheduleRowPresentation] {
        guard let schedules = snapshot?.schedules else { return [] }
        let rows = schedules.map { SchedulePresentation.row($0, context: context) }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        let normalizedQuery = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return rows.filter { row in
            row.searchableText
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(normalizedQuery)
        }
    }
}
