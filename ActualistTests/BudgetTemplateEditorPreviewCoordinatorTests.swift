import Foundation
import Testing
@testable import Actualist

@Suite("Budget template editor preview coordinator")
@MainActor
struct BudgetTemplateEditorPreviewCoordinatorTests {
    @Test func replacingARequestSuppressesTheOlderPreview() async throws {
        let debounce = ManualTestDelay()
        let coordinator = BudgetTemplateEditorPreviewCoordinator(sleep: { try await debounce.sleep(for: $0) })
        var results: [Int] = []
        let finished = TestLatch()

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
        #expect(try await debounce.waitUntilSleeping() == .milliseconds(40))
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
                finished.trip()
            }
        )
        await finished.wait()
        // The older request wakes only after the newer one completed.
        debounce.resume()
        let barrier = TestLatch()
        coordinator.schedule(drafts: [], delay: .zero, load: { _ in nil }, completion: { _ in barrier.trip() })
        await barrier.wait()
        #expect(results == [200])
    }

    @Test func cancelPreventsAQueuedPreviewFromLoading() async throws {
        let debounce = ManualTestDelay()
        let coordinator = BudgetTemplateEditorPreviewCoordinator(sleep: { try await debounce.sleep(for: $0) })
        var didLoad = false
        var completions = 0

        coordinator.schedule(
            drafts: [.monthlyFixed(amount: 100)],
            delay: .milliseconds(40),
            load: { _ in
                didLoad = true
                return BudgetTemplateCategoryDryRun(budgeted: 100, perTemplate: [100])
            },
            completion: { _ in completions += 1 }
        )
        _ = try await debounce.waitUntilSleeping()
        coordinator.cancel()
        debounce.resume()
        let barrier = TestLatch()
        coordinator.schedule(drafts: [], delay: .zero, load: { _ in nil }, completion: { _ in barrier.trip() })
        await barrier.wait()

        #expect(!didLoad)
        #expect(completions == 0)
    }
}
