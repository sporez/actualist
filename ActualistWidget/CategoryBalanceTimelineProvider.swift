import WidgetKit

struct CategoryBalanceTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CategoryBalanceEntry {
        var value = CategoryBalanceEntry.placeholder
        value.theme = WidgetThemeStore.live.load()
        return value
    }

    func snapshot(
        for configuration: CategoryBalanceConfigurationIntent,
        in context: Context
    ) async -> CategoryBalanceEntry {
        if context.isPreview, configuration.categories?.isEmpty != false {
            return placeholder(in: context)
        }
        return entry(for: configuration, family: context.family)
    }

    func timeline(
        for configuration: CategoryBalanceConfigurationIntent,
        in context: Context
    ) async -> Timeline<CategoryBalanceEntry> {
        let entry = entry(for: configuration, family: context.family)
        return Timeline(entries: [entry], policy: .after(WidgetMonthID.nextBoundary(after: entry.date)))
    }

    private func entry(
        for configuration: CategoryBalanceConfigurationIntent,
        family: WidgetFamily
    ) -> CategoryBalanceEntry {
        let now = Date()
        let snapshot = WidgetSnapshotStore.live.load()
        let selectedIDs = configuration.categories?.map(\.id) ?? []
        let rows = WidgetCategoryBalanceProjection.rows(
            selectedIDs: selectedIDs,
            snapshot: snapshot,
            now: now,
            limit: visibleCount(for: family)
        )
        return CategoryBalanceEntry(
            date: now,
            state: WidgetCategoryBalanceState.resolve(
                selectedIDs: selectedIDs,
                snapshot: snapshot,
                rows: rows,
                now: now
            ),
            rows: rows,
            budgetName: snapshot?.budgetName ?? "",
            theme: WidgetThemeStore.live.load()
        )
    }

    private func visibleCount(for family: WidgetFamily) -> Int {
        WidgetCategoryBalanceCapacity.maximum(for: WidgetSizeSupport.size(family))
    }

}
