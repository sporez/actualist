import Foundation
import Observation

struct TransactionFilterOption: Identifiable, Hashable {
    let id: String
    let title: String
    var isUnavailable = false
}

enum TransactionFilterField: String, CaseIterable, Hashable {
    case account
    case payee
    case category

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .account: "building.2"
        case .payee: "person.crop.circle"
        case .category: "square.grid.2x2"
        }
    }
}

enum TransactionFilterDraftError: LocalizedError, Equatable {
    case chooseOne(TransactionFilterField)
    case nullRequiresScalar(TransactionFilterField)
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .chooseOne(.account): "Choose one account for this condition."
        case .chooseOne(.payee): "Choose one payee for this condition."
        case .chooseOne(.category): "Choose one category for this condition."
        case .nullRequiresScalar(.payee): "Use “Is” or “Is not” to filter transactions with no payee."
        case .nullRequiresScalar(.category): "Use “Is” or “Is not” to filter uncategorized transactions."
        case .nullRequiresScalar(.account): "No account conditions cannot be authored here."
        case .invalidDate: "Choose a valid date."
        }
    }
}

@MainActor
@Observable
final class TransactionFilterWorkflow {
    typealias ApplyHandler = ([TransactionQueryCondition], TransactionQueryJoin) -> Void

    var conditionsJoin: TransactionQueryJoin = .and
    var includesDate = false
    var dateOperation: TransactionQueryDateOperation = .isOn
    var date = Date()
    var accountOperation: TransactionQueryIDOperation = .isOneOf
    var payeeOperation: TransactionQueryIDOperation = .isOneOf
    var categoryOperation: TransactionQueryIDOperation = .isOneOf
    var selectedAccountIDs: Set<String> = []
    var selectedPayeeIDs: Set<String> = []
    var selectedCategoryIDs: Set<String> = []
    var includesNoPayee = false
    var includesUncategorized = false
    private(set) var accounts: [TransactionFilterOption] = []
    private(set) var payees: [TransactionFilterOption] = []
    private(set) var categories: [TransactionFilterOption] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var validationMessage: String?
    var optionSearchText = ""

    private var preservedConditions: [TransactionQueryCondition] = []
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var optionLoadTask: Task<Void, Never>?
    @ObservationIgnored private var onApply: ApplyHandler = { _, _ in }

    var preservedConditionSummaries: [String] { preservedConditions.map(conditionSummary) }

    init(
        conditions: [TransactionQueryCondition] = [],
        join: TransactionQueryJoin = .and,
        onApply: @escaping ApplyHandler = { _, _ in }
    ) {
        self.onApply = onApply
        configure(conditions: conditions, join: join, onApply: onApply)
    }

    func configure(
        conditions: [TransactionQueryCondition],
        join: TransactionQueryJoin,
        onApply: @escaping ApplyHandler
    ) {
        cancelLoading()
        self.onApply = onApply
        conditionsJoin = join
        includesDate = false
        dateOperation = .isOn
        date = Date()
        accountOperation = .isOneOf
        payeeOperation = .isOneOf
        categoryOperation = .isOneOf
        selectedAccountIDs.removeAll()
        selectedPayeeIDs.removeAll()
        selectedCategoryIDs.removeAll()
        includesNoPayee = false
        includesUncategorized = false
        preservedConditions.removeAll()
        accounts = []
        payees = []
        categories = []
        optionSearchText = ""
        errorMessage = nil
        validationMessage = nil
        hydrate(conditions)
    }

    @discardableResult
    func loadOptions(
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        availableAccounts: [ActualAccount]? = nil
    ) -> Task<Void, Never> {
        guard !Task.isCancelled else { return Task {} }
        optionLoadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.performOptionsLoad(
                generation: generation,
                budgetID: budgetID,
                repository: repository,
                availableAccounts: availableAccounts
            )
        }
        optionLoadTask = task
        return task
    }

    func cancelLoading() {
        loadGeneration &+= 1
        optionLoadTask?.cancel()
        optionLoadTask = nil
        isLoading = false
    }

    func isSelected(_ id: String, in field: TransactionFilterField) -> Bool {
        selectedIDs(in: field).contains(id)
    }

    func isNullSelected(in field: TransactionFilterField) -> Bool {
        switch field {
        case .account: false
        case .payee: includesNoPayee
        case .category: includesUncategorized
        }
    }

    func optionsForSelection(in field: TransactionFilterField) -> [TransactionFilterOption] {
        let options = options(in: field)
        let availableIDs = Set(options.map(\.id))
        let unavailable = selectedIDs(in: field).subtracting(availableIDs).map {
            TransactionFilterOption(id: $0, title: "Unavailable (\($0))", isUnavailable: true)
        }
        return (options + unavailable).sorted(by: optionOrder)
    }

    func visibleOptions(in field: TransactionFilterField) -> [TransactionFilterOption] {
        let query = optionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = optionsForSelection(in: field)
        guard !query.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func beginOptionSelection() {
        optionSearchText = ""
    }

    func toggleSelection(_ id: String, in field: TransactionFilterField) {
        switch field {
        case .account: toggle(id, in: &selectedAccountIDs)
        case .payee: toggle(id, in: &selectedPayeeIDs)
        case .category: toggle(id, in: &selectedCategoryIDs)
        }
        validationMessage = nil
    }

    func setNullSelection(_ field: TransactionFilterField, isSelected: Bool) {
        switch field {
        case .account:
            return
        case .payee:
            includesNoPayee = isSelected
            if isSelected, !payeeOperation.isScalar { payeeOperation = .isEqual }
        case .category:
            includesUncategorized = isSelected
            if isSelected, !categoryOperation.isScalar { categoryOperation = .isEqual }
        }
        validationMessage = nil
    }

    func operation(for field: TransactionFilterField) -> TransactionQueryIDOperation {
        switch field {
        case .account: accountOperation
        case .payee: payeeOperation
        case .category: categoryOperation
        }
    }

    func setOperation(_ operation: TransactionQueryIDOperation, for field: TransactionFilterField) {
        switch field {
        case .account: accountOperation = operation
        case .payee: payeeOperation = operation
        case .category: categoryOperation = operation
        }
        validationMessage = nil
    }

    func selectionSummary(for field: TransactionFilterField) -> String {
        var labels = selectedIDs(in: field).sorted().map { optionTitle(for: $0, in: field) }
        if field == .payee, includesNoPayee { labels.append("No payee") }
        if field == .category, includesUncategorized { labels.append("No category") }
        guard !labels.isEmpty else { return "Any" }
        if labels.count > 2 {
            return "\(labels.prefix(2).joined(separator: ", ")) +\(labels.count - 2)"
        }
        return labels.joined(separator: ", ")
    }

    func optionTitle(for id: String, in field: TransactionFilterField) -> String {
        options(in: field).first(where: { $0.id == id })?.title ?? "Unavailable (\(id))"
    }

    func apply() -> Bool {
        do {
            let conditions = try validatedConditions()
            validationMessage = nil
            errorMessage = nil
            onApply(conditions, conditionsJoin)
            return true
        } catch let error as TransactionFilterDraftError {
            validationMessage = error.localizedDescription
            return false
        } catch {
            validationMessage = error.userFacingMessage
            return false
        }
    }

    func clearAndApply() -> Bool {
        clearDraft()
        return apply()
    }

    private func clearDraft() {
        includesDate = false
        selectedAccountIDs.removeAll()
        selectedPayeeIDs.removeAll()
        selectedCategoryIDs.removeAll()
        includesNoPayee = false
        includesUncategorized = false
        preservedConditions.removeAll()
        conditionsJoin = .and
        errorMessage = nil
        validationMessage = nil
    }

    private func performOptionsLoad(
        generation: Int,
        budgetID: String,
        repository: any TransactionRepositoryProtocol,
        availableAccounts: [ActualAccount]?
    ) async {
        defer {
            if generation == loadGeneration {
                isLoading = false
                optionLoadTask = nil
            }
        }
        do {
            let options = try await repository.editorOptions(
                budgetID: budgetID,
                month: YearMonth(date: Date()).rawValue
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            var accountByID = Dictionary(uniqueKeysWithValues: options.accounts.map { ($0.id, $0) })
            for account in availableAccounts ?? [] { accountByID[account.id] = account }
            accounts = accountByID.values.map { account in
                TransactionFilterOption(id: account.id, title: account.closed ? "\(account.name) (Closed)" : account.name)
            }.sorted(by: optionOrder)
            payees = options.payees.compactMap { payee in
                guard let id = payee.id, !payee.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return TransactionFilterOption(id: id, title: payee.name)
            }.sorted(by: optionOrder)
            categories = options.categories.compactMap { category in
                guard let id = category.id,
                      !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return TransactionFilterOption(id: id, title: category.name.actualistCategoryNameParts.name)
            }.sorted(by: optionOrder)
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !error.isCancellation else { return }
            errorMessage = error.userFacingMessage
        }
    }

    private func hydrate(_ conditions: [TransactionQueryCondition]) {
        var hasDate = false
        var hasAccount = false
        var hasPayee = false
        var hasCategory = false
        for condition in conditions {
            switch condition {
            case .date(let value):
                guard !hasDate else { preservedConditions.append(condition); continue }
                hasDate = true
                includesDate = true
                dateOperation = value.operation
                if let decodedDate = Self.date(from: value.day) { date = decodedDate }
            case .account(let value):
                guard !value.values.isEmpty, !value.values.contains(where: { $0 == nil }), !hasAccount else {
                    preservedConditions.append(condition)
                    continue
                }
                hasAccount = true
                accountOperation = value.operation
                selectedAccountIDs.formUnion(value.values.compactMap { $0 })
            case .payee(let value):
                guard !value.values.isEmpty, Self.supportsScalarNull(value), !hasPayee else {
                    preservedConditions.append(condition)
                    continue
                }
                hasPayee = true
                payeeOperation = value.operation
                selectedPayeeIDs.formUnion(value.values.compactMap { $0 })
                includesNoPayee = value.values.contains(where: { $0 == nil })
            case .category(let value):
                guard !value.values.isEmpty, Self.supportsScalarNull(value), !hasCategory else {
                    preservedConditions.append(condition)
                    continue
                }
                hasCategory = true
                categoryOperation = value.operation
                selectedCategoryIDs.formUnion(value.values.compactMap { $0 })
                includesUncategorized = value.values.contains(where: { $0 == nil })
            case .transfer:
                preservedConditions.append(condition)
            }
        }
    }

    private func validatedConditions() throws -> [TransactionQueryCondition] {
        try validateIDs(selectedAccountIDs, nullSelected: false, operation: accountOperation, field: .account)
        try validateIDs(selectedPayeeIDs, nullSelected: includesNoPayee, operation: payeeOperation, field: .payee)
        try validateIDs(
            selectedCategoryIDs,
            nullSelected: includesUncategorized,
            operation: categoryOperation,
            field: .category
        )

        var conditions = preservedConditions
        if includesDate {
            guard let day = Self.day(for: date) else { throw TransactionFilterDraftError.invalidDate }
            conditions.append(.date(TransactionQueryDateCondition(operation: dateOperation, day: day)))
        }
        if let condition = idCondition(operation: accountOperation, ids: selectedAccountIDs) {
            conditions.append(.account(condition))
        }
        if let condition = idCondition(operation: payeeOperation, ids: selectedPayeeIDs, includesNull: includesNoPayee) {
            conditions.append(.payee(condition))
        }
        if let condition = idCondition(
            operation: categoryOperation,
            ids: selectedCategoryIDs,
            includesNull: includesUncategorized
        ) {
            conditions.append(.category(condition))
        }
        return conditions
    }

    private func validateIDs(
        _ ids: Set<String>,
        nullSelected: Bool,
        operation: TransactionQueryIDOperation,
        field: TransactionFilterField
    ) throws {
        if operation.isScalar, ids.count + (nullSelected ? 1 : 0) > 1 {
            throw TransactionFilterDraftError.chooseOne(field)
        }
        if nullSelected, !operation.isScalar {
            throw TransactionFilterDraftError.nullRequiresScalar(field)
        }
    }

    private func idCondition(
        operation: TransactionQueryIDOperation,
        ids: Set<String>,
        includesNull: Bool = false
    ) -> TransactionQueryIDCondition? {
        let values: [String?] = ids.sorted().map(Optional.some) + (includesNull ? [nil] : [])
        guard !values.isEmpty else { return nil }
        switch operation {
        case .isEqual:
            guard values.count == 1 else { return nil }
            return .equals(values[0])
        case .isNotEqual:
            guard values.count == 1 else { return nil }
            return .doesNotEqual(values[0])
        case .isOneOf:
            guard !includesNull else { return nil }
            return .oneOf(values)
        case .isNotOneOf:
            guard !includesNull else { return nil }
            return .notOneOf(values)
        }
    }

    private func selectedIDs(in field: TransactionFilterField) -> Set<String> {
        switch field {
        case .account: selectedAccountIDs
        case .payee: selectedPayeeIDs
        case .category: selectedCategoryIDs
        }
    }

    private func options(in field: TransactionFilterField) -> [TransactionFilterOption] {
        switch field {
        case .account: accounts
        case .payee: payees
        case .category: categories
        }
    }

    private func toggle(_ id: String, in selection: inout Set<String>) {
        if !selection.insert(id).inserted { selection.remove(id) }
    }

    private func optionOrder(_ lhs: TransactionFilterOption, _ rhs: TransactionFilterOption) -> Bool {
        let order = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    private func summary(field: TransactionFilterField, value: TransactionQueryIDCondition) -> String {
        let values = value.values.map { id in
            guard let id else { return "No \(field.title.lowercased())" }
            return optionTitle(for: id, in: field)
        }
        let condition = values.isEmpty ? "with no value" : "\(value.operation.displayName) \(values.joined(separator: ", "))"
        return "\(field.title) \(condition) (kept unchanged)"
    }

    private func conditionSummary(_ condition: TransactionQueryCondition) -> String {
        switch condition {
        case .date(let value):
            "Date \(value.operation.displayName) \(value.day.rawValue) (kept unchanged)"
        case .account(let value): summary(field: .account, value: value)
        case .payee(let value): summary(field: .payee, value: value)
        case .category(let value): summary(field: .category, value: value)
        case .transfer(let value): "\(value ? "Transfer" : "Non-transfer") transactions (kept unchanged)"
        }
    }

    private static func supportsScalarNull(_ value: TransactionQueryIDCondition) -> Bool {
        guard value.values.contains(where: { $0 == nil }) else { return true }
        return value.values.count == 1 && value.operation.isScalar
    }

    private static func day(for date: Date) -> TransactionQueryDay? {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return TransactionQueryDay(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }

    private static func date(from day: TransactionQueryDay) -> Date? {
        let parts = day.rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

private extension TransactionQueryIDOperation {
    var isScalar: Bool { self == .isEqual || self == .isNotEqual }

    var displayName: String {
        switch self {
        case .isEqual: "is"
        case .isNotEqual: "is not"
        case .isOneOf: "is one of"
        case .isNotOneOf: "is not one of"
        }
    }
}

private extension TransactionQueryDateOperation {
    var displayName: String {
        switch self {
        case .isOn: "is"
        case .isApproximately: "is approximately"
        case .isAfter: "is after"
        case .isOnOrAfter: "is on or after"
        case .isBefore: "is before"
        case .isOnOrBefore: "is on or before"
        }
    }
}
