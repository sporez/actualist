import Foundation
import Observation

/// Temporary presentation only; the store remains the budget-data owner.
@MainActor @Observable
final class BudgetMonthSwipeTransition {
    struct Request {
        let id = UUID()
        let direction: BudgetMonthSwipePolicy.Direction
        let budgetID: String
        let origin: BudgetMonth
        let target: String
        let collapsed: Set<String>
    }

    enum Release { case tracking, committed }
    enum State {
        case idle
        case loading(Request, Release)
        case ready(Request, BudgetViewModel, Release)
        case completing(Request, BudgetViewModel)
        case returning(Request, BudgetViewModel?)
    }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    private let navigation = BudgetMonthSwipeNavigation()

    var request: Request? {
        switch state {
        case .idle: nil
        case .loading(let request, _), .ready(let request, _, _), .completing(let request, _), .returning(let request, _): request
        }
    }

    var preview: BudgetViewModel? {
        switch state {
        case .ready(_, let model, _), .completing(_, let model): model
        case .returning(_, let model): model
        case .idle, .loading: nil
        }
    }

    var commitReadyID: UUID? {
        if case .ready(let request, _, .committed) = state { return request.id }
        return nil
    }

    var isReleased: Bool {
        switch state {
        case .loading(_, .committed), .ready(_, _, .committed), .completing, .returning: true
        default: false
        }
    }

    @discardableResult
    func prepare(_ direction: BudgetMonthSwipePolicy.Direction, model: BudgetViewModel, budgetID: String?,
                 read: @escaping @Sendable (String, String) async throws -> LoadedBudgetMonth) -> Task<Void, Never>? {
        guard request == nil, BudgetMonthSwipeNavigation.isAvailable(model: model, budgetID: budgetID),
              let budgetID, let origin = model.budgetMonth else { return nil }
        let target = BudgetViewportModel.monthID(origin.month, offsetBy: direction.monthOffset)
        guard target != origin.month, target >= "1900-01", target <= "9999-12" else { return nil }
        let request = Request(direction: direction, budgetID: budgetID, origin: origin, target: target,
                              collapsed: Set(model.visibleGroups.map(\.id)).subtracting(model.expandedGroupIDs))
        state = .loading(request, .tracking)
        let next = Task { [weak self] in
            do {
                let loaded = try await read(budgetID, target)
                try Task.checkCancellation()
                guard let self, case .loading(let current, let release) = self.state,
                      current.id == request.id else { return }
                guard self.matchesOrigin(model), loaded.month.month == target else { self.cancel(); return }
                let preview = BudgetViewModel(initialMonth: loaded, initialBudgetID: budgetID)
                preview.expandedGroupIDs.subtract(request.collapsed)
                preview.includeCarryoverCategoriesInOverspentAlerts = model.includeCarryoverCategoriesInOverspentAlerts
                self.state = .ready(request, preview, release)
            } catch {
                guard let self, case .loading(let current, _) = self.state, current.id == request.id else { return }
                if self.matchesOrigin(model) { model.errorMessage = error.userFacingMessage }
                self.cancel()
            }
        }
        task = next
        return next
    }

    func release(commit: Bool) {
        guard commit else {
            if let request {
                let retained = preview
                task?.cancel()
                task = nil
                state = .returning(request, retained)
            }
            return
        }
        switch state {
        case .loading(let request, _): state = .loading(request, .committed)
        case .ready(let request, let preview, _): state = .ready(request, preview, .committed)
        default: break
        }
    }

    /// Called by SwiftUI's actual animation completion, never a guessed timer.
    @discardableResult
    func complete(id: UUID, model: BudgetViewModel, repository: any BudgetRepositoryProtocol) -> Task<Void, Never>? {
        guard case .ready(let request, let preview, .committed) = state, request.id == id,
              matchesOrigin(model) else { return nil }
        state = .completing(request, preview)
        let next = Task { [weak self] in
            guard let self, self.request?.id == id else { return }
            await self.navigation.navigate(request.direction, model: model, budgetID: request.budgetID, repository: repository)?.value
            guard self.request?.id == id else { return }
            self.cancel()
        }
        task = next
        return next
    }

    func invalidateIfNeeded(model: BudgetViewModel) {
        // The owned navigation changes the main model only after the slide ends.
        if case .completing = state { return }
        if request != nil && !matchesOrigin(model) { cancel() }
    }

    private func matchesOrigin(_ model: BudgetViewModel) -> Bool {
        guard let request else { return false }
        return BudgetMonthSwipeNavigation.isAvailable(model: model, budgetID: request.budgetID)
            && model.budgetMonth == request.origin && model.selectedMonth == request.origin.month
    }

    func cancel() {
        task?.cancel()
        task = nil
        navigation.cancel()
        state = .idle
    }
}
