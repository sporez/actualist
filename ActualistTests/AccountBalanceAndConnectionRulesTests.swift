import Foundation
import Testing
@testable import Actualist

@MainActor
struct AccountBalanceAndConnectionRulesTests {
    @Test func balanceToneIsGreenPositiveGrayZeroOrUnknownAndRedNegative() {
        #expect(AccountBalanceTone(minorUnits: 1) == .positive)
        #expect(AccountBalanceTone(minorUnits: 0) == .neutral)
        #expect(AccountBalanceTone(minorUnits: nil) == .neutral)
        #expect(AccountBalanceTone(minorUnits: -1) == .negative)
    }

    @Test func sectionTotalIsTheMinorUnitSumOfEveryBucket() {
        let cash = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 1)
        let sections = AccountListLayout.sections(
            displays: [
                Self.display("a", balance: 1_050, groupID: "cash"),
                Self.display("b", balance: -2_000),
                Self.display("c", balance: nil, groupID: "cash"),
            ],
            groups: [cash],
            preferredIDs: []
        )

        #expect(sections.count == 1)
        #expect(sections[0].buckets.count == 2)
        #expect(sections[0].totalMinorUnits == -950)
    }

    @Test func whitespaceOnlyInputKeepsConnectDisabled() {
        let model = OnboardingViewModel()
        model.serverURLString = "   "
        model.actualPassword = "secret"
        #expect(!model.canConnectWithPassword)
        #expect(!model.canLoadLoginMethods)

        model.serverURLString = "https://actual.example.com"
        model.actualPassword = " \n\t"
        #expect(!model.canConnectWithPassword)

        model.actualPassword = "secret"
        #expect(model.canConnectWithPassword)

        let settings = SettingsViewModel()
        settings.serverURLString = "https://actual.example.com"
        settings.actualPassword = "   "
        #expect(!settings.canSaveConnection)
        settings.actualPassword = "secret"
        #expect(settings.canSaveConnection)
    }

    @Test func localDataLossWarningNamesPendingChangesOnlyWhenPresent() {
        #expect(LocalDataLossWarning.message(base: "Base.", pendingChangeCount: 0)
            == "Base. Your server data is not changed.")
        #expect(LocalDataLossWarning.message(base: "Base.", pendingChangeCount: 1)
            == "Base. Warning: 1 local change has not been confirmed by the server and will be permanently lost.")
        #expect(LocalDataLossWarning.message(base: "Base.", pendingChangeCount: 3)
            .contains("3 local changes have not been confirmed"))
    }

    private static func display(_ id: String, balance: Int?, groupID: String? = nil) -> AccountDisplay {
        AccountDisplay(
            account: ActualAccount(id: id, name: id, offbudget: false, closed: false, accountGroupId: groupID),
            balance: balance
        )
    }
}
