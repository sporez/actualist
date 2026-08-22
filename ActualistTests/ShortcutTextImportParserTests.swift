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

    @Test func datesAreNotTreatedAsAmounts() throws {
        let parsed = try ShortcutTextImportParser.parse("2026-04-01 coffee 12.50")
        #expect(parsed.amountMinorUnits == 1_250)
        #expect(parsed.payeeText == "coffee")
    }

    @Test func multiWordPayeeAfterAtIsPreserved() throws {
        let parsed = try ShortcutTextImportParser.parse("12.50 at Starbucks Reserve")
        #expect(parsed.amountMinorUnits == 1_250)
        #expect(parsed.payeeText == "Starbucks Reserve")
        #expect(parsed.categoryText == nil)
    }

    @Test func emptyTextAndInflowKeywordsAreCovered() throws {
        #expect(throws: ShortcutsError.textImportAmountMissing) {
            _ = try ShortcutTextImportParser.parse("   ")
        }
        let received = try ShortcutTextImportParser.parse("got 15 paycheck")
        #expect(received.direction == .inflow)
        #expect(received.amountMinorUnits == 1_500)
        let inflow = try ShortcutTextImportParser.parse("inflow 20 bonus")
        #expect(inflow.direction == .inflow)
        let spend = try ShortcutTextImportParser.parse("spend 8 snacks")
        #expect(spend.direction == .spend)
        let comma = try ShortcutTextImportParser.parse("$1,250.50 coffee")
        #expect(comma.amountMinorUnits == 125_050)
        let leftoverAccount = try ShortcutTextImportParser.parse("spent 9 on coffee in Checking Extra")
        #expect(leftoverAccount.payeeText == "coffee")
        #expect(leftoverAccount.accountText == "Checking Extra")
        #expect(throws: ShortcutsError.textImportAmountMissing) {
            _ = try ShortcutTextImportParser.parse("transfer nope from Checking to Savings")
        }
    }
}
