import Foundation
import Testing
@testable import Actualist

@Suite("Budget template doors")
struct BudgetTemplateDoorPresentationTests {
    @Test func kindUsesLockWhenLoaded() {
        #expect(BudgetTemplateDoorKind.kind(hasDefinition: false, lock: .editable) == .add)
        #expect(BudgetTemplateDoorKind.kind(hasDefinition: true, lock: .editable) == .edit)
        #expect(
            BudgetTemplateDoorKind.kind(
                hasDefinition: true,
                lock: .readOnly(.noteManaged)
            ) == .view
        )
        #expect(
            BudgetTemplateDoorKind.kind(
                hasDefinition: false,
                lock: .readOnly(.missingColumns)
            ) == .view
        )
    }

    @Test func kindWithoutLockUsesDefinitionPresence() {
        #expect(BudgetTemplateDoorKind.kind(hasDefinition: false) == .add)
        #expect(BudgetTemplateDoorKind.kind(hasDefinition: true) == .edit)
    }

    @Test func titlesMatchDoors() {
        #expect(BudgetTemplateDoorKind.add.menuTitle == "Add Templates")
        #expect(BudgetTemplateDoorKind.edit.menuTitle == "Edit Templates")
        #expect(BudgetTemplateDoorKind.view.menuTitle == "View Templates")
        #expect(BudgetTemplateDoorKind.add.detailsTitle == "Add Template")
        #expect(BudgetTemplateDoorKind.edit.detailsTitle == "Edit Templates")
        #expect(BudgetTemplateDoorKind.view.detailsTitle == "View Templates")
    }

    @Test func rowSummaryUsesSnapshotAndPrivacy() {
        let now = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 9, day: 15, hour: 12)
        )!
        let snapshot = BudgetTemplateEditorSnapshot(
            categoryID: "groceries",
            categoryName: "Groceries",
            drafts: [.monthlyFixed(amount: 400, now: now)],
            lock: .editable,
            schedules: [],
            currency: .usd,
            hasDefinition: true
        )
        let visible = BudgetTemplateDoorRow.make(
            snapshot: snapshot,
            currency: .usd,
            randomized: false
        )
        #expect(visible.kind == .edit)
        #expect(visible.summary == "\(BudgetCurrency.usd.formatted(40_000))/mo")
        #expect(visible.lockReason == nil)

        let privateRow = BudgetTemplateDoorRow.make(
            snapshot: snapshot,
            currency: .usd,
            randomized: true
        )
        let expected = PrivacyDisplay.money(40_000, seed: "groceries-0", currency: .usd)
        #expect(privateRow.summary == "\(expected)/mo")
        if BudgetCurrency.usd.formatted(40_000) != expected {
            #expect(!privateRow.summary.contains(BudgetCurrency.usd.formatted(40_000)))
        }
    }

    @Test func cutAKindsMakeCompleteDefaults() {
        let now = Date()
        for kind in BudgetTemplateKind.allCases
        where kind.isAvailableForAuthoring && kind != .schedule {
            #expect(kind.makeDraft(now: now).isComplete)
            #expect(kind.makeDraft(now: now).kind == kind)
        }
        #expect(!BudgetTemplateKind.schedule.makeDraft(now: now).isComplete)
        #expect(BudgetTemplateKind.remainder.isSingleton)
        #expect(BudgetTemplateKind.goal.isSingleton)
        #expect(!BudgetTemplateKind.monthlyFixed.isSingleton)
    }
}
