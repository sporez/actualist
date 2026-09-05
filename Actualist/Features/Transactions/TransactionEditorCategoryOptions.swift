import Foundation

/// Shared category picker projection for regular transactions and split children.
enum TransactionEditorCategoryOptions {
    static func matching(_ groups: [TransactionEditorCategoryGroup], query: String) -> [TransactionEditorCategoryGroup] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            guard !group.options.isEmpty else { return nil }
            if group.name.localizedCaseInsensitiveContains(query) { return group }
            let options = group.options.filter { $0.title.localizedCaseInsensitiveContains(query) }
            guard !options.isEmpty else { return nil }
            return TransactionEditorCategoryGroup(id: group.id, name: group.name, options: options)
        }
    }

    static func fallbackGroups(categories: [ActualCategory]) -> [TransactionEditorCategoryGroup] {
        let incomeCategories = categories.filter { ($0.isIncome ?? false) }
        let expenseCategories = categories.filter { !($0.isIncome ?? false) }

        var result: [TransactionEditorCategoryGroup] = []

        if let incomeID = incomeCategories.first(where: { $0.id != nil })?.id {
            result.append(TransactionEditorCategoryGroup(
                id: "to-budget",
                name: "To Budget",
                options: [
                    TransactionEditorCategoryOption(
                        id: incomeID,
                        title: "To Budget",
                        amount: nil,
                        valueText: nil
                    )
                ]
            ))
        }

        let expenseOptions = expenseCategories.compactMap { category -> TransactionEditorCategoryOption? in
            guard let categoryID = category.id else {
                return nil
            }

            return TransactionEditorCategoryOption(
                id: categoryID,
                title: category.name.actualistCategoryNameParts.name,
                amount: nil,
                valueText: nil
            )
        }

        if !expenseOptions.isEmpty {
            result.append(TransactionEditorCategoryGroup(
                id: "categories",
                name: "Categories",
                options: expenseOptions
            ))
        }

        return result
    }
}
