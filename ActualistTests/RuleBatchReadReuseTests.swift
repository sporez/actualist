import Foundation
import GRDB
import Testing
@testable import Actualist

/// Phase 5.8: rule `matches` patterns compile once, and a batch resolves
/// unknown payee names against one payee read.
@MainActor
struct RuleBatchReadReuseTests {
    @Test func cachedExpressionsMatchFreshCompilationAndCompileOncePerPattern() {
        let patterns = ["^cof+ee", "shop$", "(", "[a-", "a|b", "\\d{3}", "^$"]
        let subjects = ["coffee shop", "cofee", "ab", "123 main", "", "(", "a-"]
        let before = RuleRegexCache.compileCount
        for round in 0..<20 {
            for pattern in patterns {
                let fresh = try? NSRegularExpression(pattern: pattern)
                let cached = RuleRegexCache.expression(for: pattern)
                #expect((fresh == nil) == (cached == nil), "\(pattern) round \(round)")
                for subject in subjects {
                    let range = NSRange(subject.startIndex..., in: subject)
                    #expect(
                        (fresh?.firstMatch(in: subject, range: range) != nil)
                            == (cached?.firstMatch(in: subject, range: range) != nil),
                        "\(pattern) vs \(subject)"
                    )
                }
            }
        }
        // 7 distinct patterns over 20 rounds: compiled at most once each.
        #expect(RuleRegexCache.compileCount - before <= patterns.count)
    }

    private func payeeReadsForCSVApply(unknownNames: Int) async throws -> (reads: Int, created: Int) {
        let bundle = try await LocalFirstActualStoreTests().makeOpenedWritableStoreBundle(
            additionalFixtureSQL: TransactionCSVImportRevalidationTests.fixtureSQL
        )
        // Repeats differ only by case, so each reuses its batch-created payee.
        let rows = (0..<unknownNames).map { index in
            "2026-07-\(String(format: "%02d", 10 + index)),\(index % 2 == 0 ? "New" : "new") Payee \(index / 2),,-\(index + 1).00"
        }
        let csv = Data((["Date,Payee,Notes,Amount"] + rows).joined(separator: "\n").appending("\n").utf8)
        let review = try await bundle.store.prepareTransactionCSVImport(
            TransactionCSVImportPreparationRequest(
                budgetID: "group-1", accountID: "checking", data: csv, options: TransactionCSVImportOptions()
            )
        )
        let database = try #require(bundle.store.database)
        let log = StatementLog()
        try await database.startStatementTraceForTesting(log)
        let result = try await bundle.store.applyTransactionCSVImport(TransactionCSVImportApplyRequest(
            budgetID: "group-1", accountID: "checking", sessionGeneration: review.sessionGeneration,
            rows: review.rows.filter { if case .insert = $0.disposition { true } else { false } }
        ))
        try await database.stopStatementTraceForTesting()
        #expect(result.insertedCount == unknownNames)
        let queue = await database.queue
        let created = try await queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM payees WHERE name LIKE 'New%'") ?? 0
        }
        return (log.count(containing: "AS transfer_acct"), created)
    }

    @Test func csvApplyPayeeReadsDoNotGrowWithTheNumberOfUnknownNames() async throws {
        let one = try await payeeReadsForCSVApply(unknownNames: 1)
        let many = try await payeeReadsForCSVApply(unknownNames: 8)
        // Was one more whole-table read per distinct unknown name.
        #expect(many.reads == one.reads, "one \(one.reads), many \(many.reads)")
        // Eight rows, four distinct names after case-folding: no duplicates created.
        #expect(one.created == 1)
        #expect(many.created == 4)
    }
}
