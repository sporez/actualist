import Foundation
import Testing
@testable import Actualist

struct ShortcutTextImportParserTests {
    struct Case: Sendable {
        let text: String
        let amount: Int
        let direction: ShortcutTransactionDirection
        let payee: String?
        let account: String?
        let destination: String?
        let category: String?
    }

    @Test(arguments: [
        Case(text: "$12.50 coffee", amount: 1_250, direction: .spend, payee: "coffee", account: nil, destination: nil, category: nil),
        Case(text: "12.50 at Starbucks", amount: 1_250, direction: .spend, payee: "Starbucks", account: nil, destination: nil, category: nil),
        Case(text: "Coffee 12.50", amount: 1_250, direction: .spend, payee: "Coffee", account: nil, destination: nil, category: nil),
        Case(text: "spent 12.50 on coffee in Checking", amount: 1_250, direction: .spend, payee: "coffee", account: "Checking", destination: nil, category: nil),
        Case(text: "received 200 paycheck", amount: 20_000, direction: .inflow, payee: "paycheck", account: nil, destination: nil, category: nil),
        Case(text: "12.50 coffee Groceries Checking", amount: 1_250, direction: .spend, payee: "coffee", account: "Checking", destination: nil, category: "Groceries"),
        Case(text: "transfer 50 from Checking to Savings", amount: 5_000, direction: .transfer, payee: nil, account: "Checking", destination: "Savings", category: nil)
    ])
    func parsesAcceptedShapes(testCase: Case) throws {
        let parsed = try ShortcutTextImportParser.parse(testCase.text)
        #expect(parsed.amountMinorUnits == testCase.amount)
        #expect(parsed.direction == testCase.direction)
        #expect(parsed.payeeText == testCase.payee)
        #expect(parsed.accountText == testCase.account)
        #expect(parsed.destinationAccountText == testCase.destination)
        #expect(parsed.categoryText == testCase.category)
    }

    @Test func missingAmountThrows() {
        #expect(throws: ShortcutsError.textImportAmountMissing) {
            _ = try ShortcutTextImportParser.parse("coffee at Starbucks")
        }
    }

    @Test func currencySymbolsAndCaseAreOptional() throws {
        let parsed = try ShortcutTextImportParser.parse("SPENT $12.5 ON Coffee")
        #expect(parsed.amountMinorUnits == 1_250)
        #expect(parsed.direction == .spend)
        #expect(parsed.payeeText == "Coffee")
    }
}
