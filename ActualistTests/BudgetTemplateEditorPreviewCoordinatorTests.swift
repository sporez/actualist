import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor preview coordinator")
@MainActor
struct BudgetTemplateEditorPreviewCoordinatorTests {
    @Test func replacingARequestSuppressesTheOlderPreview() async throws {
        let coordinator = BudgetTemplateEditorPreviewCoordinator()
        var results: [Int] = []

        coordinator.schedule(
            drafts: [.monthlyFixed(amount: 100)],
            delay: .milliseconds(40),
            load: { _ in
                BudgetTemplateCategoryDryRun(budgeted: 100, perTemplate: [100])
            },
            completion: { result in
                if case .success(let preview) = result {
                    results.append(preview?.budgeted ?? -1)
                }
            }
        )
        coordinator.schedule(
            drafts: [.monthlyFixed(amount: 200)],
            delay: .zero,
            load: { _ in
                BudgetTemplateCategoryDryRun(budgeted: 200, perTemplate: [200])
            },
            completion: { result in
                if case .success(let preview) = result {
                    results.append(preview?.budgeted ?? -1)
                }
            }
        )

        try await Task.sleep(for: .milliseconds(100))
        #expect(results == [200])
    }

    @Test func cancelPreventsAQueuedPreviewFromLoading() async throws {
        let coordinator = BudgetTemplateEditorPreviewCoordinator()
        var didLoad = false
        coordinator.schedule(
            drafts: [.monthlyFixed()],
            delay: .milliseconds(40),
            load: { _ in
                didLoad = true
                return BudgetTemplateCategoryDryRun(budgeted: 100, perTemplate: [100])
            },
            completion: { _ in }
        )
        coordinator.cancel()

        try await Task.sleep(for: .milliseconds(100))
        #expect(!didLoad)
    }
}
