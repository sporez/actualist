import Foundation
import Testing
@testable import Actualist

@Suite("Native template form boundaries")
@MainActor
struct BudgetTemplateNativeFormTests {
    private let now = BudgetTemplateCalendar.validatedDate("2026-09-04")!

    @Test(arguments: ["en_US", "de_DE", "fr_FR", "ar_EG"])
    func currencyFormatRoundTripsLocalizedInput(localeID: String) throws {
        let locale = Locale(identifier: localeID)
        let value = Decimal(string: "1234.56")!
        let style = BudgetMoneyInputFormat(currency: .usd, locale: locale)
        let formatted = style.format(value)
        #expect(try style.parseStrategy.parse(formatted) == value)
        #expect(style.format(value) == value.formatted(.currency(code: "USD").locale(locale)))
        let neutral = BudgetMoneyInputFormat(currency: .none, locale: locale)
        #expect(try neutral.parseStrategy.parse(neutral.format(value)) == value)
    }

    @Test(arguments: [BudgetCurrency.usd, .jpy, .none, .catalog(code: "USD", hideFraction: true)])
    func focusedFormatNeverPadsOrRoundsTheNumberWhileTyping(currency: BudgetCurrency) throws {
        let locale = Locale(identifier: "en_US")
        let style = BudgetMoneyInputFormat(currency: .none, locale: locale)
        #expect(style.format(1) == "1")
        #expect(style.format(12) == "12")
        #expect(style.format(Decimal(string: "1234.567")!) == "1,234.567")
        let currencyStyle = BudgetMoneyInputFormat(currency: currency, locale: locale)
        let value = Decimal(string: "1234.567")!
        #expect(try currencyStyle.parseStrategy.parse(currencyStyle.format(value)) == value)
    }

    @Test(arguments: [BudgetCurrency.usd, .none])
    func nativeParsingRejectsPartialNumbersAndSigns(currency: BudgetCurrency) throws {
        let style = BudgetMoneyInputFormat(currency: currency, locale: Locale(identifier: "en_US"))
        for invalid in ["", "-", "+", "12oops", "1.2.3", "NaN", "--12"] {
            #expect(throws: (any Error).self) { try style.parse(invalid) }
        }
        #expect(try style.parse("1,234.56") == Decimal(string: "1234.56"))
        #expect(try style.parse("-12.5") == Decimal(string: "-12.5"))
        #expect(try style.parse(".5") == Decimal(string: "0.5"))
        #expect(try style.parse("1.") == 1)
    }

    @Test(arguments: [BudgetCurrency.usd, .jpy, .none, .catalog(code: "USD", hideFraction: true)])
    func numericBindingSavesThroughExistingCurrencyBoundary(currency: BudgetCurrency) async throws {
        let (vm, repository, id) = try await loaded(currency: currency)
        vm.inputFocusChanged(to: .init(itemID: id, field: .amount))
        vm.setNumericAmount(nil, field: .amount, id: id)
        #expect(!vm.canSave)
        #expect(vm.numericAmount(for: .amount, id: id) == nil)
        #expect(vm.previewState == .editing)
        #expect(await vm.save() == false)
        vm.setNumericAmount(Decimal(string: "1234.56"), field: .amount, id: id)
        #expect(vm.numericAmount(for: .amount, id: id) == Decimal(string: "1234.56"))
        #expect(vm.previewState == .editing)
        #expect(await vm.save())
        guard case .dateTarget(let saved) = await repository.savedDrafts().last?.first else {
            Issue.record("Expected date target"); return
        }
        #expect(saved.amount == (currency == .jpy ? 1235 : 1234.56))
        #expect(saved.description == "Keep note")
        #expect(saved.month == "2027-09")
    }

    @Test func numericBindingRespectsPrivacyAndReadOnly() async throws {
        let (vm, _, id) = try await loaded()
        let original = vm.editor.items
        vm.isPrivacyModeEnabled = true
        vm.setNumericAmount(500, field: .amount, id: id)
        #expect(vm.numericAmount(for: .amount, id: id) == nil)
        #expect(vm.editor.items == original)
        vm.isPrivacyModeEnabled = false
        vm.cancel()
        vm.setNumericAmount(500, field: .amount, id: id)
        vm.setMonthYear(2030, field: .targetMonth, id: id)
        vm.setIntegerValue(2, field: .priority, id: id)
        #expect(vm.editor.items == original)
    }

    @Test func monthSelectionIsLocalizedAndKeepsStorageRoundTrip() throws {
        let month = try #require(BudgetTemplateEditorMonth(storage: "2026-12"))
        #expect(month.month == 12 && month.year == 2026)
        #expect(month.storage == "2026-12")
        #expect(month.title(locale: Locale(identifier: "en_US")) == "December 2026")
        #expect(month.title(locale: Locale(identifier: "fr_FR")) == "décembre 2026")
        #expect(BudgetTemplateEditorMonth.monthNames(locale: Locale(identifier: "fr_FR"))[11] == "décembre")
        #expect(BudgetTemplateEditorMonth.monthNames(locale: Locale(identifier: "en_US")).count == 12)
        #expect(BudgetTemplateEditorMonth(storage: "2026-13") == nil)
        #expect(month.supportedYears(now: now) == 1900...2126)
        #expect(try #require(BudgetTemplateEditorMonth(storage: "1850-06")).supportedYears(now: now).contains(1850))
        #expect(try #require(BudgetTemplateEditorMonth(storage: "9999-12")).supportedYears(now: now).contains(9999))
    }

    @Test func monthWheelsSaveWithoutChangingAmountsNotesOrRecurrence() async throws {
        let (vm, repository, id) = try await loaded()
        vm.setMonthNumber(12, field: .targetMonth, id: id)
        vm.setMonthYear(2028, field: .targetMonth, id: id)
        vm.edit(.setDateTargetEarlySpending(true, id: id))
        vm.setMonthNumber(6, field: .spendStartMonth, id: id)
        vm.setMonthYear(2027, field: .spendStartMonth, id: id)
        #expect(await vm.save())
        guard case .dateTarget(let saved) = await repository.savedDrafts().last?.first else { return }
        #expect(saved.month == "2028-12")
        #expect(saved.fromMonth == "2027-06")
        #expect(saved.amount == 100 && saved.description == "Keep note")
        #expect(saved.repeatInterval == 1 && saved.annual)
    }

    @Test func invalidMonthIsRepairedOnlyByExplicitSelection() async throws {
        let (vm, _, id) = try await loaded(month: "bad-month")
        #expect(!vm.canSave)
        #expect(vm.monthTitle(for: .targetMonth, id: id, locale: .current) == "Choose month")
        #expect(vm.monthSelection(for: .targetMonth, id: id).storage == "2026-09")
        #expect(!vm.canSave)
        vm.completeMonthSelection(field: .targetMonth, id: id)
        #expect(vm.canSave)
        #expect(vm.inputText(for: .targetMonth, id: id) == "2026-09")
    }

    @Test func steppersUseExistingBoundsAndPreserveHiddenFieldBehavior() async throws {
        let (vm, _, id) = try await loaded()
        #expect(BudgetTemplateEditorInputField.priority.integerRange == 0...1000)
        #expect(BudgetTemplateEditorInputField.repeatInterval.integerRange == 1...1200)
        #expect(BudgetTemplateEditorInputField.interval.integerRange == BudgetTemplateEngine.Bounds.periodInterval)
        #expect(BudgetTemplateEditorInputField.lookBack.integerRange == BudgetTemplateEngine.Bounds.lookBack)
        #expect(BudgetTemplateEditorInputField.numMonths.integerRange == BudgetTemplateEngine.Bounds.numMonths)
        #expect(BudgetTemplateEditorInputField.amount.integerRange == nil)
        for priority in [0, 1, 1000] {
            vm.setIntegerValue(priority, field: .priority, id: id)
            #expect(vm.integerValue(for: .priority, id: id) == priority)
            #expect(vm.canSave)
        }
        vm.setIntegerValue(1200, field: .repeatInterval, id: id)
        #expect(vm.canSave)
        vm.setIntegerValue(1201, field: .repeatInterval, id: id)
        #expect(!vm.canSave)
        vm.edit(.setDateTargetRepeats(false, id: id))
        #expect(vm.canSave)
        vm.edit(.setDateTargetRepeats(true, id: id))
        #expect(vm.integerValue(for: .repeatInterval, id: id) == 1)
        #expect(!vm.editor.dateTargetIsAnnual(for: id))
    }

    private func loaded(currency: BudgetCurrency = .usd, month: String = "2027-09") async throws
        -> (BudgetTemplateEditorViewModel, EditorTemplateRepository, UUID) {
        let draft = BudgetTemplateDraft.dateTarget(amount: 100, month: month, description: "Keep note", now: now)
        let repository = EditorTemplateRepository(snapshot: .init(
            categoryID: "synthetic", categoryName: "Category", drafts: [draft],
            lock: .editable, schedules: [], currency: currency, hasDefinition: true
        ))
        let vm = BudgetTemplateEditorViewModel(
            target: .init(categoryID: "synthetic", categoryName: "Category", month: "2026-09"),
            now: now
        )
        await vm.load(repository: repository, budgetID: "synthetic")
        return (vm, repository, try #require(vm.editor.items.first?.id))
    }
}
