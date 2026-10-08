import Foundation
import Testing
@testable import Actualist

@Suite("Payees view model write guard")
@MainActor
struct PayeesViewModelWriteGuardTests {
    private let fixtures = LocalFirstActualStoreTests()

    @Test func secondTriggerWhileAWriteRunsIsRefusedAndOnlyOneWriteHappens() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let model = PayeesViewModel()

        let first = Task { await model.create(name: "Alpha Payee", using: appState) }
        let second = Task { await model.create(name: "Beta Payee", using: appState) }
        let results = [await first.value, await second.value]

        try await bundle.store.refreshPayeeManagementSnapshot(budgetID: "group-1")
        let names = try #require(bundle.store.cachedPayeeManagementSnapshot(budgetID: "group-1")).payees.map(\.name)
        #expect(results == [true, false])
        #expect(names.contains("Alpha Payee"))
        #expect(!names.contains("Beta Payee"))
        #expect(!model.isSubmitting)
        #expect(model.successFeedback == 1)
    }
}
