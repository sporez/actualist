import Foundation
import Testing
@testable import Actualist

/// Actual's `storeNoteTemplates` decides every case: a note matches the definition
/// Actual stores for it, and a note changed since then reads as stale only when
/// Actual would store something that behaves differently.
@Suite("Template note oracle replay")
struct TemplateNoteOracleReplayTests {
    private struct Case: Decodable {
        let id: String
        let note: String
        let goalDef: String?
        let stale: Bool
    }

    private struct Contract: Decodable {
        let cases: [Case]
    }

    @Test func staleVerdictMatchesActualForEveryNote() throws {
        let url = try ParityOraclePin.fixtureURL("TemplateNotes").appending(path: "template-note-contract.json")
        let cases = try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url)).cases
        #expect(!cases.isEmpty)
        for testCase in cases {
            let entries = try JSONDecoder().decode(
                [BudgetTemplateEntry].self,
                from: Data((testCase.goalDef ?? "[]").utf8)
            )
            let reason = BudgetTemplateNoteParser.stalenessReason(
                noteDirectives: BudgetTemplateNoteParser.directives(in: testCase.note),
                goalDefEntries: entries
            )
            #expect(
                (reason != nil) == testCase.stale,
                "\(testCase.id): Actual says stale=\(testCase.stale), the guard says \(reason ?? "not stale")"
            )
        }
    }
}
