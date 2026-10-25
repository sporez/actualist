import AppIntents
import Foundation

enum ShortcutTemplateMode: String, AppEnum {
    case fillEmpty
    case overwrite

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Template Mode")
    static let caseDisplayRepresentations: [ShortcutTemplateMode: DisplayRepresentation] = [
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
    static let title: LocalizedStringResource = "Set Category Budget"
    static let description = IntentDescription(
        "Sets the budgeted amount for a category.",
        categoryName: "Budget"
    )
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
        Summary("Budget \(\.$amount) for \(\.$category)") {
            \.$month
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<CategoryEntity> & ProvidesDialog {
        let updated = try await ShortcutBudgetCommand.assign(
            categoryID: category.id,
            amountMinorUnits: try await session.minorUnits(from: $amount.valueAskingIfMissing(zeroIsMissing: false)),
            month: month?.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(updated.budgeted)
        return .result(value: updated, dialog: IntentDialog("Budgeted \(spoken) for \(updated.name)."))
    }
}

struct AddToCategoryBudgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Category Budget"
    static let description = IntentDescription(
        "Adds to the amount budgeted for a category.",
        categoryName: "Budget"
    )
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
            amountMinorUnits: try await session.minorUnits(from: $amount.valueAskingIfMissing(zeroIsMissing: false)),
            month: month?.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(updated.budgeted)
        return .result(value: updated, dialog: IntentDialog("\(updated.name) is now budgeted \(spoken)."))
    }
}

struct MoveMoneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Money"
    static let description = IntentDescription(
        "Moves money between categories or To Budget.",
        categoryName: "Budget"
    )
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
            amountMinorUnits: try await session.minorUnits(from: $amount.valueAskingIfMissing(zeroIsMissing: false)),
            month: month?.id,
            session: session
        )
        let spoken = ShortcutMoney.spoken(amount)
        return .result(value: updated, dialog: IntentDialog("Moved \(spoken)."))
    }
}

struct ApplyBudgetTemplateIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Budget Template"
    static let description = IntentDescription(
        "Applies your budget templates to a month or one category.",
        categoryName: "Budget"
    )
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
    static let title: LocalizedStringResource = "Set Category Rollover"
    static let description = IntentDescription(
        "Turns rollover on or off for a category, starting from a month.",
        categoryName: "Budget"
    )
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
        Summary("Set rollover on \(\.$category)") {
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
        return .result(value: updated, dialog: IntentDialog("Rollover for \(updated.name) is \(state)."))
    }
}

struct CreatePayeeIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Payee"
    static let description = IntentDescription(
        "Creates a payee in the selected budget.",
        categoryName: "Transactions"
    )
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
    static let title: LocalizedStringResource = "Create Account"
    static let description = IntentDescription(
        "Creates an account in the selected budget.",
        categoryName: "Accounts"
    )
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
