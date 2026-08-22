import Foundation
import Testing
@testable import Actualist

@MainActor
struct ShortcutBudgetCommandTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession() async throws -> ShortcutsBudgetSession {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        return ShortcutsBudgetSession(appState: try fixtures.makeAppState(for: bundle))
    }

    @Test func assignSetsBudgetedAmount() async throws {
        let session = try await makeSession()
        let category = try await ShortcutBudgetCommand.assign(
            categoryID: "groceries",
            amountMinorUnits: 62_500,
            month: "2026-07",
            session: session
        )
        #expect(try ShortcutMoney.minorUnits(from: category.budgeted!) == 62_500)
    }

    @Test func addToUsesCurrentPlusDelta() async throws {
        let session = try await makeSession()
        let before = try await session.category(id: "groceries", month: "2026-07")
        let beforeBudgeted = try ShortcutMoney.minorUnits(from: before.budgeted!)
        let after = try await ShortcutBudgetCommand.add(
            categoryID: "groceries",
            amountMinorUnits: 5_000,
            month: "2026-07",
            session: session
        )
        #expect(try ShortcutMoney.minorUnits(from: after.budgeted!) == beforeBudgeted + 5_000)
    }

    @Test func moveMoneyToAndFromReadyToAssign() async throws {
        let session = try await makeSession()
        _ = try await ShortcutBudgetCommand.assign(
            categoryID: "groceries",
            amountMinorUnits: 10_000,
            month: "2026-07",
            session: session
        )
        let moved = try await ShortcutBudgetCommand.move(
            fromCategoryID: "groceries",
            toCategoryID: nil,
            amountMinorUnits: 2_000,
            month: "2026-07",
            session: session
        )
        #expect(try ShortcutMoney.minorUnits(from: moved.budgeted!) == 8_000)

        let returned = try await ShortcutBudgetCommand.move(
            fromCategoryID: nil,
            toCategoryID: "groceries",
            amountMinorUnits: 1_000,
            month: "2026-07",
            session: session
        )
        #expect(try ShortcutMoney.minorUnits(from: returned.budgeted!) == 9_000)
    }

    @Test func applyTemplateAndCarryoverUseExistingStoreMethods() async throws {
        let session = try await makeSession()
        _ = try await ShortcutBudgetCommand.applyTemplate(
            mode: .fillEmpty,
            categoryID: "groceries",
            month: "2026-07",
            session: session
        )
        let category = try await ShortcutBudgetCommand.setCarryover(
            categoryID: "utilities",
            enabled: true,
            startMonth: "2026-07",
            session: session
        )
        #expect(category.carryover)
    }

    @Test func createPayeeAndAccountReturnEntities() async throws {
        let session = try await makeSession()
        let payee = try await ShortcutBudgetCommand.createPayee(name: "New Cafe", session: session)
        #expect(payee.name == "New Cafe")
        #expect(!payee.isTransfer)

        let account = try await ShortcutBudgetCommand.createAccount(
            name: "Cash",
            offBudget: true,
            session: session
        )
        #expect(account.name == "Cash")
        #expect(account.offBudget)
    }
}
