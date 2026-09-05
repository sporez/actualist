import Foundation

struct TransactionEditorCategoryState: Equatable, Sendable {
    private(set) var selectedCategoryID: String?
    private(set) var selectedCategoryFallbackName: String?

    init(categoryID: String? = nil, fallbackName: String? = nil) {
        selectedCategoryID = categoryID
        selectedCategoryFallbackName = fallbackName
    }

    mutating func clear() {
        selectedCategoryID = nil
        selectedCategoryFallbackName = nil
    }

    mutating func selectCategory(id: String, name: String?) {
        selectedCategoryID = id
        selectedCategoryFallbackName = name
    }

    mutating func resolveNames(_ namesByID: [String: String]) {
        guard let id = selectedCategoryID, let name = namesByID[id] else { return }
        selectedCategoryFallbackName = name
    }
}
