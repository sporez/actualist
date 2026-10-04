import Foundation
import Testing
@testable import Actualist

/// Phase 5.6: a render asks for the account sections many times; the view
/// model builds one layout per distinct inputs. `AccountListLayout.sections`
/// is the oracle.
@MainActor
struct AccountsViewModelLayoutMemoTests {
    private func display(
        _ id: String, offbudget: Bool = false, closed: Bool = false, groupID: String? = nil, balance: Int = 0
    ) -> AccountDisplay {
        AccountDisplay(
            account: ActualAccount(
                id: id, name: id.capitalized, offbudget: offbudget, closed: closed, accountGroupId: groupID),
            balance: balance
        )
    }

    @Test func memoizedSectionsMatchTheLayoutAndBuildOncePerDistinctInputs() {
        let model = AccountsViewModel()
        let groups = [
            ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 2),
            ActualAccountGroup(id: "credit", name: "Credit", sortOrder: 1),
        ]
        var displays = [
            display("a", groupID: "cash", balance: 100), display("b", groupID: "credit", balance: -50),
            display("c", offbudget: true, balance: 7), display("d", closed: true), display("e"),
        ]
        for _ in 0..<12 {
            #expect(
                model.sections(displays: displays, groups: groups, preferredIDs: ["e"])
                    == AccountListLayout.sections(displays: displays, groups: groups, preferredIDs: ["e"])
            )
        }
        #expect(model.layoutBuildCount == 1)

        // A balance change, a group change and an order change each rebuild.
        displays[0] = display("a", groupID: "cash", balance: 999)
        let changed = model.sections(displays: displays, groups: groups, preferredIDs: ["e"])
        #expect(changed == AccountListLayout.sections(displays: displays, groups: groups, preferredIDs: ["e"]))
        #expect(changed.first?.totalMinorUnits != 0)
        #expect(model.layoutBuildCount == 2)
        let reordered = model.sections(displays: displays, groups: groups, preferredIDs: ["a", "e"])
        #expect(reordered == AccountListLayout.sections(displays: displays, groups: groups, preferredIDs: ["a", "e"]))
        #expect(model.layoutBuildCount == 3)
        _ = model.sections(displays: displays, groups: [], preferredIDs: ["a", "e"])
        #expect(model.layoutBuildCount == 4)
    }
}
