import Foundation
import Testing
@testable import Actualist

@Suite("Template editor Actual 26.8.1 oracle")
struct BudgetTemplateEditorOracleTests {
    private struct Fixtures: Decodable {
        struct Normalization: Decodable { let id: String; let input: String; let expected: String }
        struct Transition: Decodable { let id: String; let input: String; let expected: String; let kind: String }
        struct Validation: Decodable { let id: String; let input: String; let valid: Bool }
        let today: String
        let normalizations: [Normalization]
        let transitions: [Transition]
        let validations: [Validation]
    }

    @Test func normalizationMatchesPinnedMigrationIncludingNotesAndZeroCaps() throws {
        let fixture = try fixtures()
        let now = try #require(BudgetTemplateCalendar.validatedDate(fixture.today))
        for sample in fixture.normalizations {
            let actual = try BudgetTemplateDefinition.normalizedDrafts(fromJSON: sample.input, now: now)
            let expected = try BudgetTemplateDefinition.normalizedDrafts(fromJSON: sample.expected, now: now)
            #expect(actual == expected, "\(sample.id)")
            let encoded = try BudgetTemplateDefinition.encode(actual)
            #expect(try BudgetTemplateDefinition.normalizedDrafts(fromJSON: encoded, now: now) == expected, "\(sample.id) reopen")
        }
    }

    @Test func typeTransitionsMatchPinnedReducerAndRetainNotes() throws {
        let fixture = try fixtures()
        let now = try #require(BudgetTemplateCalendar.validatedDate(fixture.today))
        for sample in fixture.transitions {
            let input = try #require(BudgetTemplateDefinition.normalizedDrafts(fromJSON: sample.input, now: now).first)
            let kind = try #require(BudgetTemplateKind(rawValue: sample.kind))
            let expected = try #require(BudgetTemplateDefinition.normalizedDrafts(fromJSON: sample.expected, now: now).first)
            #expect(input.retyped(to: kind, now: now) == expected, "\(sample.id)")
        }
    }

    @Test func authoringRulesMatchPinnedWebValidator() throws {
        let fixture = try fixtures()
        let now = try #require(BudgetTemplateCalendar.validatedDate(fixture.today))
        let context = BudgetTemplateAuthoringContext(today: now,
            schedules: [.init(id: "rent", name: "Rent")],
            incomeCategories: [.init(id: "income-1", name: "Salary")])
        for sample in fixture.validations {
            let drafts = try BudgetTemplateDefinition.normalizedDrafts(fromJSON: sample.input, now: now)
            #expect(BudgetTemplateAuthoringValidation.isValid(drafts, context: context) == sample.valid, "\(sample.id)")
        }
    }

    @Test(arguments: [BudgetCurrency.usd, .jpy, .none])
    func legacyNormalizationPreservesAggregateDemand(currency: BudgetCurrency) throws {
        let fixture = try fixtures()
        let now = try #require(BudgetTemplateCalendar.validatedDate(fixture.today))
        let ids: Set<String> = ["simple-missing-monthly-cap", "simple-zero-cap-plus-fixed", "simple-monthly-cap-order", "periodic-nested-cap", "remainder-nested-cap", "copy-inert-cap"]
        let engine = BudgetTemplateEngine(currency: currency)
        for sample in fixture.normalizations where ids.contains(sample.id) {
            let drafts = try BudgetTemplateDefinition.normalizedDrafts(fromJSON: sample.input, now: now)
            let normalized = try BudgetTemplateDefinition.encode(drafts)
            var amounts: [[Int]] = []
            for json in [sample.input, normalized] {
                let entries = try #require(try engine.decodeSupportedEntries(json: json))
                let plan = try engine.computePlan(
                    categories: ["category": .init(entries: entries, fromLastMonth: 25, copiedBudgetedByLookBack: [1: 400])],
                    orderedCategoryIDs: ["category"], monthValue: 202609, availableBudget: 50_000, skipAvailableClamp: true
                )
                amounts.append(plan.writes.map(\.amount))
            }
            #expect(amounts[0] == amounts[1], "\(sample.id) / \(currency.code)")
        }
    }

    private func fixtures() throws -> Fixtures {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/ActualCore26_8_1/Templates/editor-cases.json")
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: path))
    }
}
