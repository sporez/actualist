import Foundation

struct TransactionEditorCategoryState: Equatable, Sendable {
    struct Category: Equatable, Sendable {
        let id: String?
        let name: String?
    }

    enum Selection: Equatable, Sendable {
        case single(Category)
        case selectingSplit(original: Category, rows: [TransactionSplitEditorRow])
        case split([TransactionSplitEditorRow])
    }

    private(set) var selection: Selection

    init(
        categoryID: String? = nil,
        fallbackName: String? = nil
    ) {
        selection = .single(Category(id: categoryID, name: fallbackName))
    }

    var selectedCategoryID: String? {
        if case .single(let category) = selection {
            return category.id
        }
        return nil
    }

    var selectedCategoryFallbackName: String? {
        if case .single(let category) = selection {
            return category.name
        }
        return nil
    }

    mutating func clear() {
        selection = .single(Category(id: nil, name: nil))
    }

    mutating func selectCategory(id: String, name: String?) {
        selection = .single(Category(id: id, name: name))
    }

    mutating func resolveNames(_ namesByID: [String: String]) {
        guard case .single(let category) = selection,
              let id = category.id,
              let name = namesByID[id] else {
            return
        }
        selection = .single(Category(id: id, name: name))
    }
}
