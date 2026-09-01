import Foundation
import Testing
@testable import Actualist

struct TransactionEditorCategoryStateTests {
    @Test func selectAndClearSingleCategory() {
        var state = TransactionEditorCategoryState(categoryID: "services", fallbackName: "Services")

        #expect(state.selectedCategoryID == "services")
        #expect(state.selectedCategoryFallbackName == "Services")

        state.selectCategory(id: "phone", name: "Phone")
        #expect(state.selectedCategoryID == "phone")
        #expect(state.selectedCategoryFallbackName == "Phone")

        state.clear()
        #expect(state.selectedCategoryID == nil)
        #expect(state.selectedCategoryFallbackName == nil)
    }

    @Test func resolveNamesUpdatesSelectedCategory() {
        var state = TransactionEditorCategoryState(categoryID: "services", fallbackName: "services")
        state.resolveNames(["services": "Services"])
        #expect(state.selectedCategoryFallbackName == "Services")
    }
}
