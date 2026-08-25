import Foundation
import Testing
@testable import Actualist

struct AccountListLayoutTests {
    @Test func sectionsStayFlatWhenNobodyIsGrouped() {
        let checking = display("checking", name: "Checking")
        let savings = display("savings", name: "Savings")
        let sections = AccountListLayout.sections(
            displays: [checking, savings],
            groups: [
                ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384)
            ],
            preferredIDs: []
        )

        #expect(sections.map(\.kind) == [.budget])
        #expect(sections[0].showsGroupHeaders)
        #expect(sections[0].buckets.map(\.id) == ["cash", "ungrouped"])
        #expect(sections[0].buckets[0].accounts.isEmpty)
        #expect(sections[0].accounts.map(\.id) == ["checking", "savings"])
    }

    @Test func mixedGroupsNestInsideTopLevelSectionsAndOmitEmptyGroups() {
        let checking = display("checking", name: "Checking", groupID: "cash")
        let visa = display("visa", name: "Visa", groupID: "credit")
        let wallet = display("wallet", name: "Wallet")
        let brokerage = display("brokerage", name: "Brokerage", offbudget: true, groupID: "cash")
        let oldVisa = display("old-visa", name: "Old Visa", closed: true, groupID: "credit")
        let cash = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 32_768)
        let credit = ActualAccountGroup(id: "credit", name: "Credit", sortOrder: 16_384)
        let empty = ActualAccountGroup(id: "empty", name: "Empty", sortOrder: 1)

        let sections = AccountListLayout.sections(
            displays: [checking, visa, wallet, brokerage, oldVisa],
            groups: [cash, credit, empty],
            preferredIDs: []
        )

        #expect(sections.map(\.kind) == [.budget, .offBudget, .closed])
        #expect(sections[0].showsGroupHeaders)
        #expect(sections[0].buckets.map(\.id) == ["empty", "credit", "cash", "ungrouped"])
        #expect(sections[0].buckets[0].accounts.isEmpty)
        #expect(sections[0].buckets[1].accounts.map(\.id) == ["visa"])
        #expect(sections[0].buckets[2].accounts.map(\.id) == ["checking"])
        #expect(sections[0].buckets[3].accounts.map(\.id) == ["wallet"])
        #expect(sections[1].buckets.map(\.id) == ["cash"])
        #expect(sections[1].accounts.map(\.id) == ["brokerage"])
        #expect(sections[2].buckets.map(\.id) == ["credit"])
        #expect(sections[2].accounts.map(\.id) == ["old-visa"])
    }

    @Test func danglingGroupIdsAreUngroupedAndDoNotCreateHeaders() {
        let checking = display("checking", name: "Checking", groupID: "missing")
        let savings = display("savings", name: "Savings", groupID: "cash")
        let cash = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384)
        let sections = AccountListLayout.sections(
            displays: [checking, savings],
            groups: [cash],
            preferredIDs: []
        )

        #expect(sections[0].showsGroupHeaders)
        #expect(sections[0].buckets.map(\.id) == ["cash", "ungrouped"])
        #expect(sections[0].buckets[0].accounts.map(\.id) == ["savings"])
        #expect(sections[0].buckets[1].accounts.map(\.id) == ["checking"])
    }

    @Test func customOrderAppliesInsideAGroupAndLeavesGroupOrderAlone() {
        let alpha = display("alpha", name: "Alpha", groupID: "cash")
        let beta = display("beta", name: "Beta", groupID: "cash")
        let gamma = display("gamma", name: "Gamma", groupID: "credit")
        let cash = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384)
        let credit = ActualAccountGroup(id: "credit", name: "Credit", sortOrder: 32_768)
        let sections = AccountListLayout.sections(
            displays: [alpha, beta, gamma],
            groups: [cash, credit],
            preferredIDs: ["gamma", "beta", "alpha"]
        )

        #expect(sections[0].buckets.map(\.id) == ["cash", "credit"])
        #expect(sections[0].buckets[0].accounts.map(\.id) == ["beta", "alpha"])
        #expect(sections[0].buckets[1].accounts.map(\.id) == ["gamma"])
    }

    @Test func emptyGroupsAppearUnderBudgetEvenWhenMembersAreElsewhere() {
        let brokerage = display("brokerage", name: "Brokerage", offbudget: true)
        let cash = ActualAccountGroup(id: "cash", name: "Cash", sortOrder: 16_384)
        let sections = AccountListLayout.sections(
            displays: [brokerage],
            groups: [cash],
            preferredIDs: []
        )

        #expect(sections.map(\.kind) == [.budget, .offBudget])
        #expect(sections[0].buckets.map(\.id) == ["cash"])
        #expect(sections[0].accounts.isEmpty)
        #expect(sections[1].showsGroupHeaders == false)
        #expect(sections[1].accounts.map(\.id) == ["brokerage"])
    }

    @Test func customOrderStillAppliesToAFlatSection() {
        let checking = display("checking", name: "Checking")
        let savings = display("savings", name: "Savings")
        let sections = AccountListLayout.sections(
            displays: [checking, savings],
            groups: [],
            preferredIDs: ["savings", "checking"]
        )

        #expect(sections[0].showsGroupHeaders == false)
        #expect(sections[0].accounts.map(\.id) == ["savings", "checking"])
    }

    private func display(
        _ id: String,
        name: String,
        offbudget: Bool = false,
        closed: Bool = false,
        groupID: String? = nil
    ) -> AccountDisplay {
        AccountDisplay(
            account: ActualAccount(
                id: id,
                name: name,
                offbudget: offbudget,
                closed: closed,
                accountGroupId: groupID
            ),
            balance: 0
        )
    }
}
