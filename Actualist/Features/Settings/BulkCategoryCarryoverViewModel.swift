import Foundation
import Observation

struct BulkCategoryCarryoverStatus: Equatable, Sendable {
    let month: String
    let categoryCount: Int
    let enabledCount: Int

    init(loadedMonth: LoadedBudgetMonth) {
        let categories = loadedMonth.month.categoryGroups
            .flatMap(\.categories)
            .filter { !$0.isIncome }
        month = loadedMonth.selectedMonth
        categoryCount = categories.count
        enabledCount = categories.reduce(0) { $0 + ($1.carryover ? 1 : 0) }
    }

    var allEnabled: Bool {
        categoryCount > 0 && enabledCount == categoryCount
    }

    var canEnableAll: Bool {
        enabledCount < categoryCount
    }

    var canDisableAll: Bool {
        enabledCount > 0
    }

    var detail: String {
        guard categoryCount > 0 else {
            return "No expense categories"
        }
        if allEnabled {
            return "On for all \(categoryCount) categories"
        }
        if enabledCount == 0 {
            return "Off for all \(categoryCount) categories"
        }
        return "On for \(enabledCount) of \(categoryCount) categories"
    }

    var monthTitle: String {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]),
              let date = Calendar(identifier: .gregorian).date(
                from: DateComponents(year: year, month: monthNumber, day: 1)
              ) else {
            return month
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

@MainActor
@Observable
final class BulkCategoryCarryoverViewModel {
    enum State: Equatable {
        case loading(previous: BulkCategoryCarryoverStatus?)
        case ready(BulkCategoryCarryoverStatus)
        case applying(BulkCategoryCarryoverStatus, carryover: Bool)
        case failed(previous: BulkCategoryCarryoverStatus?, message: String)

        var status: BulkCategoryCarryoverStatus? {
            switch self {
            case let .loading(previous), let .failed(previous, _):
                previous
            case let .ready(status), let .applying(status, _):
                status
            }
        }
    }

    private(set) var state: State = .loading(previous: nil)
    private var generation = 0

    var status: BulkCategoryCarryoverStatus? { state.status }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    var isApplying: Bool {
        if case .applying = state { return true }
        return false
    }

    var errorMessage: String? {
        if case let .failed(_, message) = state { return message }
        return nil
    }

    func reset() {
        generation += 1
        state = .loading(previous: nil)
    }

    func load(
        budgetID: String,
        preferredMonth: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        generation += 1
        let requestGeneration = generation
        state = .loading(previous: state.status)

        do {
            let loaded = try await repository.currentBudgetMonth(
                budgetID: budgetID,
                preferredMonth: preferredMonth
            )
            guard requestGeneration == generation else { return }
            state = .ready(BulkCategoryCarryoverStatus(loadedMonth: loaded))
        } catch {
            guard requestGeneration == generation else { return }
            state = .failed(previous: state.status, message: error.localizedDescription)
        }
    }

    func setAll(
        carryover: Bool,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async {
        guard let currentStatus = state.status,
              !isApplying,
              carryover ? currentStatus.canEnableAll : currentStatus.canDisableAll else {
            return
        }

        generation += 1
        let requestGeneration = generation
        state = .applying(currentStatus, carryover: carryover)

        do {
            let loaded = try await repository.setAllExpenseCategoryCarryoverAndRefresh(
                carryover: carryover,
                budgetID: budgetID,
                startMonth: currentStatus.month
            )
            guard requestGeneration == generation else { return }
            state = .ready(BulkCategoryCarryoverStatus(loadedMonth: loaded))
        } catch {
            guard requestGeneration == generation else { return }
            state = .failed(previous: currentStatus, message: error.localizedDescription)
        }
    }
}
