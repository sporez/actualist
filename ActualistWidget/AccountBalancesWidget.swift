import AppIntents
import SwiftUI
import WidgetKit

struct AccountBalancesConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Account Balances"
    static let description = IntentDescription("Choose accounts in display order. Larger widgets show more balances.")

    @Parameter(title: "Accounts", size: .init(min: 1, max: 16))
    var accounts: [WidgetAccountEntity]?
}

struct WidgetAccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"
    static let defaultQuery = WidgetAccountEntityQuery()
    let id: String
    let name: String
    let group: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(group)")
    }
    init(_ account: WidgetAccountSnapshot) {
        id = account.id
        name = account.name
        group = account.group
    }
}

struct WidgetAccountEntityQuery: EntityStringQuery {
    private var accounts: [WidgetAccountSnapshot] { WidgetSnapshotStore.live.load()?.accounts ?? [] }
    func entities(for identifiers: [String]) async throws -> [WidgetAccountEntity] {
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }.map(WidgetAccountEntity.init)
    }
    func suggestedEntities() async throws -> [WidgetAccountEntity] {
        accounts.filter { !$0.isClosed }.map(WidgetAccountEntity.init)
    }
    func entities(matching string: String) async throws -> [WidgetAccountEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return accounts.filter {
            !$0.isClosed && (query.isEmpty || $0.name.localizedStandardContains(query) || $0.group.localizedStandardContains(query))
        }.map(WidgetAccountEntity.init)
    }
}

struct AccountBalancesEntry: TimelineEntry {
    let date: Date
    let accounts: [WidgetAccountSnapshot]
    let needsSelection: Bool
    let unavailable: Bool
    var theme: ActualistThemeOption = .actualPurple
}

struct AccountBalancesProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> AccountBalancesEntry {
        AccountBalancesEntry(date: .now, accounts: WidgetPreviewData.snapshot.accounts ?? [], needsSelection: false, unavailable: false, theme: WidgetThemeStore.live.load())
    }
    func snapshot(for configuration: AccountBalancesConfigurationIntent, in context: Context) async -> AccountBalancesEntry {
        context.isPreview ? placeholder(in: context) : entry(configuration, family: context.family)
    }
    func timeline(for configuration: AccountBalancesConfigurationIntent, in context: Context) async -> Timeline<AccountBalancesEntry> {
        let value = entry(configuration, family: context.family)
        return Timeline(entries: [value], policy: .after(WidgetMonthID.nextBoundary(after: .now)))
    }
    private func entry(_ configuration: AccountBalancesConfigurationIntent, family: WidgetFamily) -> AccountBalancesEntry {
        let snapshot = WidgetFinancialProjection.currentSnapshot(WidgetSnapshotStore.live.load())
        let ids = configuration.accounts?.map(\.id) ?? []
        return AccountBalancesEntry(
            date: snapshot?.updatedAt ?? .now,
            accounts: WidgetFinancialProjection.accounts(selectedIDs: ids, snapshot: snapshot,
                limit: WidgetCategoryBalanceCapacity.maximum(for: WidgetSizeSupport.size(family))),
            needsSelection: ids.isEmpty, unavailable: snapshot?.accounts == nil,
            theme: WidgetThemeStore.live.load()
        )
    }
}

struct AccountBalancesWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.accountBalances, intent: AccountBalancesConfigurationIntent.self, provider: AccountBalancesProvider()) {
            AccountBalancesWidgetView(entry: $0).widgetTheme($0.theme)
        }
        .configurationDisplayName("Account Balances")
        .description("Your chosen accounts, in your preferred order.")
        .supportedFamilies(WidgetSizeSupport.home + [.accessoryInline, .accessoryRectangular])
    }
}

struct AccountBalancesWidgetView: View {
    let entry: AccountBalancesEntry
    var body: some View {
        Group {
            if entry.needsSelection {
                WidgetEmptyView(title: "Choose accounts", detail: "Edit this widget to select your accounts.", symbol: "building.columns")
            } else if entry.unavailable {
                WidgetEmptyView(title: "Open Actualist")
            } else if entry.accounts.isEmpty {
                WidgetEmptyView(title: "Update accounts", detail: "Choose accounts from your current budget.")
            } else {
                WidgetBalanceListView(title: "Account Balances", items: entry.accounts.map {
                    WidgetBalanceItem(id: $0.id, name: $0.name, amount: $0.balance, destination: WidgetDeepLink.url(.account(id: $0.id)))
                })
            }
        }
    }
}
