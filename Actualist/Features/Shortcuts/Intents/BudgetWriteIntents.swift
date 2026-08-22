import AppIntents
import Foundation

enum ShortcutTemplateMode: String, AppEnum {
    case fillEmpty
    case overwrite

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Template Mode")
    static var caseDisplayRepresentations: [ShortcutTemplateMode: DisplayRepresentation] = [
        .fillEmpty: "Fill Empty",
        .overwrite: "Overwrite"
    ]

    var storeMode: BudgetTemplateApplicationMode {
        switch self {
        case .fillEmpty: .fillEmpty
        case .overwrite: .overwrite
        }
    }
}

struct AssignCategoryBudgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Assign Category Budget"
    static var description = IntentDescription("Sets the budgeted amount for a category.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Assign \(\.$amount) to \(\.$category)") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CategoryEntity> & ProvidesDialog {
        let updated = try await ShortcutBudgetCommand.assign(
            categoryID: category.id,
            amountMinorUnits: try ShortcutMoney.minorUnits(from: amount),
            month: month?.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(updated.budgeted)
        return .result(value: updated, dialog: IntentDialog("Assigned \(spoken) to \(updated.name)."))
    }
}

struct AddToCategoryBudgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Category Budget"
    static var description = IntentDescription("Adds an amount to a category's current budgeted value.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) to \(\.$category)") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CategoryEntity> & ProvidesDialog {
        let updated = try await ShortcutBudgetCommand.add(
            categoryID: category.id,
            amountMinorUnits: try ShortcutMoney.minorUnits(from: amount),
            month: month?.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(updated.budgeted)
        return .result(value: updated, dialog: IntentDialog("\(updated.name) is now budgeted \(spoken)."))
    }
}

struct MoveMoneyIntent: AppIntent {
    static var title: LocalizedStringResource = "Move Money"
    static var description = IntentDescription("Moves money between categories or Ready to Assign.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "From Category")
    var fromCategory: CategoryEntity?

    @Parameter(title: "To Category")
    var toCategory: CategoryEntity?

    @Parameter(title: "Amount")
    var amount: IntentCurrencyAmount

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$amount)") {
            \.$fromCategory
            \.$toCategory
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CategoryEntity> & ProvidesDialog {
        let updated = try await ShortcutBudgetCommand.move(
            fromCategoryID: fromCategory?.id,
            toCategoryID: toCategory?.id,
            amountMinorUnits: try ShortcutMoney.minorUnits(from: amount),
            month: month?.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(amount)
        return .result(value: updated, dialog: IntentDialog("Moved \(spoken)."))
    }
}

struct ApplyBudgetTemplateIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Budget Template"
    static var description = IntentDescription("Applies a budget template to a month or one category.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Mode", default: ShortcutTemplateMode.fillEmpty)
    var mode: ShortcutTemplateMode

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Month")
    var month: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Apply \(\.$mode) template") {
            \.$category
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<BudgetSummaryEntity> & ProvidesDialog {
        let summary = try await ShortcutBudgetCommand.applyTemplate(
            mode: mode.storeMode,
            categoryID: category?.id,
            month: month?.id,
            session: session
        )
        return .result(value: summary, dialog: "Applied the budget template.")
    }
}

struct SetCategoryCarryoverIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Category Carryover"
    static var description = IntentDescription("Enables or disables category carryover from a start month.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Category")
    var category: CategoryEntity

    @Parameter(title: "Enabled")
    var enabled: Bool

    @Parameter(title: "Start Month")
    var startMonth: BudgetMonthEntity?

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Set carryover on \(\.$category)") {
            \.$enabled
            \.$startMonth
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CategoryEntity> & ProvidesDialog {
        let updated = try await ShortcutBudgetCommand.setCarryover(
            categoryID: category.id,
            enabled: enabled,
            startMonth: startMonth?.id,
            session: session
        )
        let state = enabled ? "on" : "off"
        return .result(value: updated, dialog: IntentDialog("Carryover for \(updated.name) is \(state)."))
    }
}

struct CreatePayeeIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Payee"
    static var description = IntentDescription("Creates a payee in the selected budget.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Name")
    var name: String

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Create payee \(\.$name)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<PayeeEntity> & ProvidesDialog {
        let payee = try await ShortcutBudgetCommand.createPayee(name: name, session: session)
        return .result(value: payee, dialog: IntentDialog("Created \(payee.name)."))
    }
}

struct CreateAccountIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Account"
    static var description = IntentDescription("Creates an account in the selected budget.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Off-Budget", default: false)
    var offBudget: Bool

    @Dependency
    var session: ShortcutsBudgetSession

    static var parameterSummary: some ParameterSummary {
        Summary("Create account \(\.$name)") {
            \.$offBudget
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<AccountEntity> & ProvidesDialog {
        let account = try await ShortcutBudgetCommand.createAccount(
            name: name,
            offBudget: offBudget,
            session: session
        )
        return .result(value: account, dialog: IntentDialog("Created \(account.name)."))
    }
}
