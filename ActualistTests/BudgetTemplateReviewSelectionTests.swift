import Foundation
import Testing
@testable import Actualist

/// Skipping tiles on the month Apply Templates review: the view model keeps the
/// skip set, the preview is reloaded with it, and Apply leaves out exactly what
/// the selected mode's preview priced.
@Suite("Budget template review selection")
@MainActor
struct BudgetTemplateReviewSelectionTests {
    @Test func toggleSkipsATileAndApplyExcludesIt() async {
        let repository = SkipPreviewRepository()
        let model = BudgetTemplateApplyPreviewViewModel()
        await load(model, repository)
        #expect(model.display?.categories.map(\.state) == [.included, .included])
        #expect(model.display?.categories.allSatisfy(\.isToggleable) == true)

        model.toggleCategory("dining")
        #expect(model.skippedCategoryIDs == ["dining"])
        await load(model, repository)
        #expect(await repository.recordedExclusions().last == ["dining"])
        let tiles = model.display?.categories ?? []
        #expect(tiles.map(\.id) == ["groceries", "dining"])
        #expect(tiles.map(\.state) == [.included, .skipped])
        #expect(model.display?.changeCountText == "1 category")
        #expect(model.reviewedExclusions == ["dining"])
        #expect(model.canApply)

        model.toggleCategory("dining")
        #expect(model.skippedCategoryIDs.isEmpty)
        await load(model, repository)
        #expect(model.reviewedExclusions.isEmpty)
    }

    @Test func blockedTilesAndUnknownIDsCannotBeToggled() async {
        let repository = SkipPreviewRepository(blocked: ["rent"])
        let model = BudgetTemplateApplyPreviewViewModel()
        await load(model, repository)
        let rent = model.display?.categories.last
        #expect(rent?.id == "rent")
        #expect(rent?.state == .blocked)
        #expect(rent?.isToggleable == false)
        #expect(rent?.statusText == "Template not supported")
        #expect(model.reviewedExclusions == ["rent"])

        model.toggleCategory("rent")
        model.toggleCategory("not-a-tile")
        #expect(model.skippedCategoryIDs.isEmpty)
    }

    @Test func skippingEveryTileDisablesApply() async {
        let repository = SkipPreviewRepository()
        let model = BudgetTemplateApplyPreviewViewModel()
        await load(model, repository)
        model.toggleCategory("groceries")
        model.toggleCategory("dining")
        await load(model, repository)
        #expect(model.display?.categories.allSatisfy { $0.state == .skipped } == true)
        #expect(model.display?.noOpExplanation == nil)
        #expect(!model.canApply)
    }

    @Test func applyStaysDisabledWhileASkipIsRepriced() async {
        let repository = SkipPreviewRepository()
        let model = BudgetTemplateApplyPreviewViewModel()
        await load(model, repository)
        model.toggleCategory("dining")
        await repository.suspendNext()
        let reload = Task { await load(model, repository) }
        await repository.waitForSuspension()
        // The previous tiles stay on screen, but they don't describe the new apply.
        #expect(model.display != nil)
        #expect(!model.canApply)
        await repository.resume()
        await reload.value
        #expect(model.canApply)
        #expect(model.reviewedExclusions == ["dining"])
    }

    @Test func skipsSurviveModeSwitchAndSampleValuesButResetForAnotherMonth() async {
        let repository = SkipPreviewRepository()
        let model = BudgetTemplateApplyPreviewViewModel()
        await load(model, repository)
        model.toggleCategory("dining")
        await load(model, repository)

        model.selectMode(.fillEmpty)
        #expect(model.skippedCategoryIDs == ["dining"])
        await load(model, repository, randomized: true)
        #expect(model.skippedCategoryIDs == ["dining"])

        await load(model, repository, month: "2026-08")
        #expect(model.skippedCategoryIDs.isEmpty)
    }

    @Test func cancelClearsSkips() async {
        let repository = SkipPreviewRepository()
        let model = BudgetTemplateApplyPreviewViewModel()
        await load(model, repository)
        model.toggleCategory("dining")
        model.cancel()
        #expect(model.skippedCategoryIDs.isEmpty)
    }

    @Test func singleCategoryReviewHasNoToggles() async {
        let repository = SkipPreviewRepository()
        let model = BudgetTemplateApplyPreviewViewModel()
        await model.load(confirmation: .category, categoryID: "groceries", month: "2026-07",
                         budgetID: "budget", randomized: false, repository: repository)
        #expect(model.display?.categories.map(\.isToggleable) == [false])
        model.toggleCategory("groceries")
        #expect(model.skippedCategoryIDs.isEmpty)
    }

    private func load(
        _ model: BudgetTemplateApplyPreviewViewModel,
        _ repository: SkipPreviewRepository,
        month: String = "2026-07",
        randomized: Bool = false
    ) async {
        await model.loadIfNeeded(
            revision: 1, confirmation: .monthOverwrite, categoryID: nil, month: month,
            budgetID: "budget", randomized: randomized, repository: repository
        )
    }
}

/// Prices Groceries and Dining like the database preview: a skip only counts
/// for a tile, and blocked categories are always left out.
private actor SkipPreviewRepository: BudgetTemplatePreviewTestRepository {
    private static let tiles = ["groceries", "dining"]
    private let blocked: [String]
    private var exclusions: [Set<String>] = []
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let suspension = TestLatch()

    init(blocked: [String] = []) {
        self.blocked = blocked
    }

    func recordedExclusions() -> [Set<String>] { exclusions }
    func suspendNext() { shouldSuspend = true }
    func waitForSuspension() async { await suspension.wait() }
    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func previewBudgetTemplate(
        command: BudgetTemplateCommand,
        budgetID: String,
        month: String
    ) async throws -> BudgetTemplateApplyPreview {
        preview(month: month, included: Self.tiles.filter(command.categoryIDs.contains), skipped: [])
    }

    func previewBudgetTemplatePair(
        budgetID: String,
        month: String,
        excluding: Set<String>
    ) async throws -> BudgetTemplateApplyPreviewPair {
        exclusions.append(excluding)
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                suspension.trip()
            }
        }
        let skipped = Self.tiles.filter(excluding.contains)
        var preview = preview(month: month, included: Self.tiles.filter { !skipped.contains($0) }, skipped: skipped)
        preview.baselineTileIDs = Self.tiles
        preview.blocked = blocked.map { .init(categoryID: $0, name: $0.capitalized, reason: .unsupported) }
        preview.excludedCategoryIDs = Set(skipped).union(blocked)
        return BudgetTemplateApplyPreviewPair(fillEmpty: .ready(preview), overwrite: .ready(preview))
    }

    private func preview(month: String, included: [String], skipped: [String]) -> BudgetTemplateApplyPreview {
        var preview = BudgetTemplateApplyPreview(
            assigned: included.count * 1_000,
            leftover: 0,
            isTrackingBudget: false,
            currency: .usd,
            categories: included.map(Self.category)
        )
        preview.skipped = skipped.map(Self.category)
        preview.reviewRevision = BudgetTemplateReviewRevision(
            month: month,
            modeIdentity: BudgetModeIdentity(storageID: "selection-fixture", table: .envelope, revision: nil),
            messageCount: 1,
            maxMessageTimestamp: nil
        )
        return preview
    }

    private static func category(_ id: String) -> BudgetTemplateApplyPreview.Category {
        BudgetTemplateApplyPreview.Category(
            categoryID: id, name: id.capitalized, current: 0, proposed: 1_000,
            perTemplate: [1_000], drafts: [], metric: .init(kind: .available, before: 0, after: 1_000)
        )
    }
}
