import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.1: template inputs read history once per plan (shared by the
/// preview pair) instead of per category and per month. The digests below were
/// captured from the pre-Phase-5 implementation on this exact fixture.
@MainActor
struct BudgetTemplateHistoryEquivalenceTests {
    private let fixtures = LocalFirstActualStoreTests()

    private static let month = "2026-08"
    private static let now = Date(timeIntervalSince1970: 1_786_000_000)

    private static let goalDefs: [String: String] = [
        "groceries": #"[{"directive":"template","type":"copy","lookBack":1,"priority":0}]"#,
        "dining": #"[{"directive":"template","type":"average","numMonths":6,"adjustment":10,"adjustmentType":"percent","priority":0}]"#,
        "rent": #"[{"directive":"template","type":"limit","amount":900,"period":"monthly","hold":true,"priority":null},{"directive":"template","type":"refill","priority":0}]"#,
        "fun": #"[{"directive":"template","type":"spend","amount":1200,"from":"2025-06","month":"2026-10","annual":false,"repeat":null,"priority":0}]"#,
        "savings": #"[{"directive":"template","type":"percentage","percent":10,"category":"all income","previous":false,"priority":1}]"#
    ]

    private func database(tracking: Bool) throws -> BudgetDatabase {
        try BudgetDatabase(databaseURL: fixtures.makeSQLiteFixture(
            extraSQL: BudgetHistoryFixture.sql(seed: 42, tracking: tracking, goalDefs: Self.goalDefs)
        ))
    }

    static func describe(_ outcome: BudgetTemplatePreviewOutcome) -> String {
        switch outcome {
        case .failed(let message):
            return "failed(\(message))"
        case .ready(let preview):
            let categories = preview.categories.sorted { $0.categoryID < $1.categoryID }.map {
                "\($0.categoryID)=\($0.current)>\($0.proposed) t\($0.perTemplate) d\($0.evaluatedDemand) s\($0.shortfall) g\($0.goalBefore ?? -1)>\($0.goalAfter ?? -1) \($0.metric)"
            }
            return "assigned \(preview.assigned) released \(preview.released) leftover \(preview.leftover) "
                + "demand \(preview.evaluatedDemand) funding \(preview.fundingRequired) "
                + "still \(preview.stillNeeded) before \(preview.availableBefore) after \(preview.availableAfter) "
                + "[\(categories.joined(separator: "; "))]"
        }
    }

    static func describe(_ pair: BudgetTemplateApplyPreviewPair) -> String {
        "fill: \(describe(pair.fillEmpty))\noverwrite: \(describe(pair.overwrite))"
    }

    @Test(arguments: [false, true])
    func previewPairMatchesCapturedPreviousImplementation(tracking: Bool) async throws {
        let database = try database(tracking: tracking)
        let pair = try await database.previewBudgetTemplatePair(
            month: Self.month,
            currentMonth: Self.month,
            now: Self.now
        )
        let digest = Self.describe(pair)
        #expect(digest == Self.golden[tracking], "DIGEST[\(tracking)]=\n\(digest)")
        // The pair shares one history; a lone preview builds its own.
        let fill = try await database.previewBudgetTemplate(
            command: .fillEmpty,
            month: Self.month,
            currentMonth: Self.month,
            now: Self.now
        )
        #expect(Self.describe(.ready(fill)) == Self.describe(pair.fillEmpty))
    }

    /// Scans of the spending and budget tables while a preview runs.
    private func scanCounts(
        _ database: BudgetDatabase,
        _ run: () async throws -> Void
    ) async throws -> (spending: Int, budget: Int) {
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        try await run()
        try await database.stopStatementTraceForTesting()
        return (
            log.count(containing: "GROUP BY", "FROM transactions"),
            log.count(containing: "FROM \"zero_budgets\"")
        )
    }

    /// Before Phase 5 one pair ran 24 spending scans and 42 budget scans on
    /// this fixture (a lone preview about half of each).
    @Test func previewPairReadsHistoryOnce() async throws {
        let database = try database(tracking: false)
        let single = try await scanCounts(database) {
            _ = try await database.previewBudgetTemplate(
                command: .fillEmpty,
                month: Self.month,
                currentMonth: Self.month,
                now: Self.now
            )
        }
        let pair = try await scanCounts(database) {
            _ = try await database.previewBudgetTemplatePair(
                month: Self.month,
                currentMonth: Self.month,
                now: Self.now
            )
        }
        // One of a lone preview's scans is the history read, the other belongs
        // to the plan itself. A pair shares the history across both modes.
        #expect(single.spending == 2, "single spending scans \(single.spending)")
        #expect(pair.spending == 2 * single.spending - 1, "pair \(pair.spending) single \(single.spending)")
        #expect(pair.budget <= 2 * single.budget - 1, "pair \(pair.budget) single \(single.budget)")
        #expect(pair.budget <= 12, "pair budget scans \(pair.budget)")
    }

    static let golden: [Bool: String] = [
        false: """
            fill: assigned 142925 released 0 leftover 1439918 demand 142925 funding 142925 still 0 before 1582843 after 1439918 [groceries=0>50000 t[50000] d50000 s0 g-1>50000 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: 31743, after: 81743); rent=0>92925 t[0, 92925] d92925 s0 g-1>92925 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: -64853, after: 28072)]
            overwrite: assigned 180578 released 86450 leftover 1488715 demand 105621 funding 94128 still 0 before 1582843 after 1488715 [dining=1739>34734 t[34734] d34734 s0 g-1>34734 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: -5099, after: 27896); fun=14412>-72038 t[0] d-72038 s0 g-1>-72038 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: 134315, after: 47865); groceries=0>50000 t[50000] d50000 s0 g-1>50000 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: 31743, after: 81743); rent=0>92925 t[0, 92925] d92925 s0 g-1>92925 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: -64853, after: 28072); savings=-4658>0 t[0] d0 s0 g-1>0 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.available, before: 182968, after: 187626)]
            """,
        true: """
            fill: assigned 119880 released 0 leftover -25168 demand 119880 funding 119880 still 0 before 94712 after -25168 [groceries=0>0 t[0] d0 s0 g-1>0 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: -6211, after: -6211); rent=0>119880 t[0, 119880] d119880 s0 g-1>119880 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: -91808, after: 28072)]
            overwrite: assigned 157533 released 56911 leftover -5910 demand 112115 funding 100622 still 0 before 94712 after -5910 [dining=1739>34734 t[34734] d34734 s0 g-1>34734 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: -5099, after: 27896); fun=14412>-42499 t[0] d-42499 s0 g-1>-42499 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: 14412, after: -42499); groceries=0>0 t[0] d0 s0 g-1>0 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: -6211, after: -6211); rent=0>119880 t[0, 119880] d119880 s0 g-1>119880 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: -91808, after: 28072); savings=-4658>0 t[0] d0 s0 g-1>0 BudgetTemplateCategoryMetric(kind: Actualist.BudgetTemplateCategoryMetric.Kind.balance, before: -66777, after: -62119)]
            """
    ]
}
