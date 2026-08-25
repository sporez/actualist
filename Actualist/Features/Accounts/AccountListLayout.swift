import Foundation

enum AccountListLayout {
    struct Section: Equatable, Sendable, Identifiable {
        var kind: Kind
        var buckets: [Bucket]

        var id: Kind { kind }

        var accounts: [AccountDisplay] {
            buckets.flatMap(\.accounts)
        }

        var showsGroupHeaders: Bool {
            buckets.contains { $0.group != nil }
        }
    }

    enum Kind: String, Equatable, Sendable, Hashable {
        case budget
        case offBudget
        case closed

        var title: String {
            switch self {
            case .budget: "Budget Accounts"
            case .offBudget: "Off Budget"
            case .closed: "Closed"
            }
        }
    }

    struct Bucket: Equatable, Sendable, Identifiable {
        var group: ActualAccountGroup?
        var accounts: [AccountDisplay]

        var id: String { group?.id ?? "ungrouped" }
    }

    static func sections(
        displays: [AccountDisplay],
        groups: [ActualAccountGroup],
        preferredIDs: [String]
    ) -> [Section] {
        let liveGroups = groups.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.id < rhs.id
        }
        let liveGroupIDs = Set(liveGroups.map(\.id))

        let groupedAccountIDs = Set(
            displays.compactMap { display -> String? in
                guard let groupID = display.account.accountGroupId,
                      liveGroupIDs.contains(groupID) else {
                    return nil
                }
                return display.account.id
            }
        )
        let emptyGroups = liveGroups.filter { group in
            !displays.contains { $0.account.accountGroupId == group.id }
        }

        return Kind.allCases.compactMap { kind in
            let members = displays.filter { display in
                belongs(display.account, to: kind)
            }
            let includeEmptyGroups = kind == .budget && !emptyGroups.isEmpty
            guard !members.isEmpty || includeEmptyGroups else {
                return nil
            }

            let hasGroupedMember = members.contains { groupedAccountIDs.contains($0.account.id) }
            if !hasGroupedMember && !includeEmptyGroups {
                return Section(
                    kind: kind,
                    buckets: [
                        Bucket(
                            group: nil,
                            accounts: AccountOrderPreference.ordered(
                                members,
                                preferredIDs: preferredIDs
                            )
                        )
                    ]
                )
            }

            var buckets: [Bucket] = []
            for group in liveGroups {
                let groupMembers = members.filter { $0.account.accountGroupId == group.id }
                if groupMembers.isEmpty {
                    if includeEmptyGroups, emptyGroups.contains(where: { $0.id == group.id }) {
                        buckets.append(Bucket(group: group, accounts: []))
                    }
                    continue
                }
                buckets.append(
                    Bucket(
                        group: group,
                        accounts: AccountOrderPreference.ordered(
                            groupMembers,
                            preferredIDs: preferredIDs
                        )
                    )
                )
            }

            let ungrouped = members.filter { display in
                !groupedAccountIDs.contains(display.account.id)
            }
            if !ungrouped.isEmpty {
                buckets.append(
                    Bucket(
                        group: nil,
                        accounts: AccountOrderPreference.ordered(
                            ungrouped,
                            preferredIDs: preferredIDs
                        )
                    )
                )
            }

            return Section(kind: kind, buckets: buckets)
        }
    }

    private static func belongs(_ account: ActualAccount, to kind: Kind) -> Bool {
        switch kind {
        case .budget:
            return !account.closed && !account.offbudget
        case .offBudget:
            return !account.closed && account.offbudget
        case .closed:
            return account.closed
        }
    }
}

extension AccountListLayout.Kind: CaseIterable {}
