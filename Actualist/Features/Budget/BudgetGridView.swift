import SwiftUI

struct BudgetGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var sizing: BudgetGridDensityMetrics { .init(density: density) }
    @Bindable var viewport: BudgetViewportModel
    let actions: BudgetWorkspaceActions
    let presentation: BudgetGridPresentation
    let metrics: BudgetLayoutMetrics
    @State private var isScrolled = false

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(presentation.groups) { group in
                    groupRow(group)
                        .id(group.id)
                    if viewport.expandedGroupIDs.contains(group.id) {
                        ForEach(Array(group.categories.enumerated()), id: \.element.id) { index, category in
                            categoryRow(
                                category,
                                group: group,
                                position: .init(index: index, count: group.categories.count)
                            )
                            .id(category.id)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BudgetLayoutMetrics.defaultHorizontalMargins / 2)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("budget-grid")
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 1 } action: { _, scrolled in
            isScrolled = scrolled
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            BudgetGridMonthHeaders(
                presentation: presentation,
                metrics: metrics,
                actions: actions,
                showsMonthWhileScrolled: isScrolled
            )
            .padding(.horizontal, BudgetLayoutMetrics.defaultHorizontalMargins / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ActualistTheme.background)
        .animation(reduceMotion ? nil : BudgetLayout.monthResizeAnimation, value: presentation.months.count)
    }

    private func groupRow(_ group: BudgetGridPresentation.Group) -> some View {
        HStack(spacing: 0) {
            Button {
                viewport.toggleGroup(id: group.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(viewport.expandedGroupIDs.contains(group.id) ? 90 : 0))
                        .font(.caption.weight(.bold))
                    Text(group.title)
                        .font(ActualistTypography.sectionTitle(for: density))
                        .lineLimit(2)
                    if group.source.hasUserNote {
                        Image(systemName: "note.text").font(.caption)
                    }
                }
                .padding(.leading, BudgetLayout.rowHorizontalPadding)
                .frame(maxWidth: .infinity, minHeight: sizing.groupHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .accessibilityLabel(group.title)
            .accessibilityValue(viewport.expandedGroupIDs.contains(group.id) ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("budget-grid-group-\(group.id)")
            .frame(width: metrics.categoryColumnWidth, alignment: .leading)
            .contextMenu {
                Button("Notes", systemImage: "note.text") { actions.openGroupNote(group.source) }
                if !group.source.isIncome {
                    Button(group.source.hidden == true ? "Show" : "Hide", systemImage: "eye") {
                        Task { await actions.toggleGroupHidden(group.source, using: appState) }
                    }
                }
                if !appState.settings.randomizedDisplayValuesEnabled
                    && (viewport.isTrackingBudget || !group.source.isIncome) {
                    Divider()
                    Button("Rename", systemImage: "pencil") {
                        actions.openRenameGroup(group.source)
                    }
                    .accessibilityIdentifier("budget-grid-group-rename-\(group.id)")
                    Button("Reorder", systemImage: "arrow.up.arrow.down") {
                        actions.openCategoryReorder()
                    }
                    .accessibilityIdentifier("budget-grid-group-reorder-\(group.id)")
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await actions.requestDeleteGroup(group.source) }
                    }
                    .accessibilityIdentifier("budget-grid-group-delete-\(group.id)")
                }
            }

            ForEach(presentation.months) { month in
                let values = presentation.group(group.id, month: month)
                let semantics = BudgetModePresentation(isTracking: month.semantics.isTracking, isIncome: group.source.isIncome)
                let showsLabels = semantics.needsOwnLabels(under: month.semantics)
                HStack(spacing: 8) {
                    total(values.map { month.currency.formatted($0.budgeted) }, label: semantics.budgetedLabel, showsLabel: showsLabels, group: group, month: month)
                    total(values.map { semantics.secondValue(balance: $0.balance, activity: $0.spent, currency: month.currency).text }, label: semantics.secondValueLabel, showsLabel: showsLabels, group: group, month: month)
                }
                .padding(.horizontal, sizing.cellPadding)
                .frame(width: metrics.monthColumnWidth)
                .transition(.opacity)
            }
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .padding(.top, sizing.headerSpacing)
    }

    private func total(_ value: String?, label: String, showsLabel: Bool, group: BudgetGridPresentation.Group, month: BudgetGridPresentation.Month) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if showsLabel {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            Text(value ?? "—")
        }
            .font(ActualistTypography.rowValue(for: density))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(group.title), \(month.title), \(label), \(value ?? "Unavailable")")
    }

    private func categoryRow(
        _ category: BudgetGridPresentation.Category,
        group: BudgetGridPresentation.Group,
        position: BudgetGridPresentation.RowPosition
    ) -> some View {
        HStack(spacing: 0) {
            Button {
                if let month = viewport.anchorMonth {
                    viewport.selectCategory(categoryID: category.id, month: month)
                }
            } label: {
                HStack(spacing: 8) {
                    if let emoji = category.emoji {
                        Text(emoji).fixedSize().accessibilityHidden(true)
                    }
                    Text(category.title)
                        .font(ActualistTypography.rowTitle(for: density))
                        .lineLimit(2)
                    if category.source.hasUserNote {
                        Image(systemName: "note.text").font(.caption2)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: sizing.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .accessibilityLabel("\(category.title), category details")
            .accessibilityIdentifier("budget-grid-category-\(category.id)")
            .frame(width: metrics.categoryColumnWidth, alignment: .leading)
            .contextMenu {
                Button("Notes", systemImage: "note.text") { actions.openCategoryNote(category.source) }
                if let month = viewport.anchorMonth {
                    Button("Templates", systemImage: "sparkles") { actions.openTemplates(category.source, month: month) }
                }
                Button(category.source.hidden == true ? "Show" : "Hide", systemImage: "eye") {
                    Task { await actions.toggleCategoryHidden(category.source, in: group.source, using: appState) }
                }
                .disabled(group.source.hidden == true)
                if !appState.settings.randomizedDisplayValuesEnabled
                    && (viewport.isTrackingBudget || !category.source.isIncome) {
                    Divider()
                    Button("Rename", systemImage: "pencil") {
                        actions.openRenameCategory(category.source)
                    }
                    .accessibilityIdentifier("budget-grid-category-rename-\(category.id)")
                    Button("Reorder", systemImage: "arrow.up.arrow.down") {
                        actions.openCategoryReorder()
                    }
                    .accessibilityIdentifier("budget-grid-category-reorder-\(category.id)")
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await actions.requestDeleteCategory(category.source) }
                    }
                    .accessibilityIdentifier("budget-grid-category-delete-\(category.id)")
                }
            }

            ForEach(presentation.months) { month in
                ZStack {
                    if let value = presentation.category(category.id, month: month) {
                        BudgetGridMonthCells(
                            category: category,
                            value: value,
                            month: month,
                            width: metrics.monthColumnWidth,
                            viewport: viewport,
                            actions: actions
                        )
                    } else {
                        Text("—").foregroundStyle(ActualistTheme.secondaryText)
                            .frame(width: metrics.monthColumnWidth, height: sizing.rowHeight)
                    }
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .opacity(BudgetCategoryVisibility.isEffectivelyHidden(category: category.source, group: group.source) ? 0.5 : 1)
        .background(ActualistTheme.surface, in: rowShape(position))
        .overlay(alignment: .bottom) {
            if position.showsSeparator {
                Rectangle()
                    .fill(ActualistTheme.separator)
                    .frame(height: 0.5)
                    .padding(.leading, BudgetLayout.rowHorizontalPadding)
            }
        }
    }

    private func rowShape(_ position: BudgetGridPresentation.RowPosition) -> UnevenRoundedRectangle {
        let top = position.isFirst ? BudgetLayout.groupCornerRadius : 0
        let bottom = position.isLast ? BudgetLayout.groupCornerRadius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
    }
}

private struct BudgetGridMonthCells: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    private var sizing: BudgetGridDensityMetrics { .init(density: density) }
    let category: BudgetGridPresentation.Category
    let value: BudgetMonthCategory
    let month: BudgetGridPresentation.Month
    let width: CGFloat
    @Bindable var viewport: BudgetViewportModel
    let actions: BudgetWorkspaceActions

    private var isEditing: Bool {
        viewport.selectedCell == .init(categoryID: category.id, month: month.id)
            && viewport.assignmentWorkflow.isPresented
    }

    private var presentsAssignment: Bool {
        viewport.assignmentPresentationCell == .init(categoryID: category.id, month: month.id)
            && viewport.assignmentWorkflow.isPresented
    }

    private var semantics: BudgetModePresentation {
        .init(isTracking: month.semantics.isTracking, isIncome: value.isIncome)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewport.beginAssignmentEditing(categoryID: category.id, month: month.id)
            } label: {
                Text(month.currency.formatted(value.budgeted))
                    .foregroundStyle(isEditing ? ActualistTheme.accent : ActualistTheme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: sizing.rowHeight, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .accessibilityLabel("\(category.title), \(month.title), \(semantics.budgetedLabel), \(month.currency.formatted(value.budgeted))")
            .accessibilityIdentifier("assigned-\(month.id)-\(category.id)")
            .popover(isPresented: Binding(get: { presentsAssignment }, set: { if !$0 { viewport.assignmentPopoverDismissed(categoryID: category.id, month: month.id) } })) {
                BudgetAssignmentPopover(viewport: viewport, actions: actions, categoryName: category.title)
                    .presentationCompactAdaptation(.popover)
                    .appSwitcherPrivacyProtected(using: appState)
            }

            Button {
                viewport.selectCategory(categoryID: category.id, month: month.id)
            } label: {
                BudgetAmountPill(value: secondValue, hidesCarryoverArrow: appState.settings.hideCarryoverArrows)
                    .frame(maxWidth: .infinity, minHeight: sizing.rowHeight, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffectDisabled()
            .accessibilityLabel("\(category.title), \(month.title), \(secondValue.accessibilityText)")
            .accessibilityIdentifier("available-\(month.id)-\(category.id)")
        }
        .font(ActualistTypography.rowValue(for: density))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, sizing.cellPadding)
        .frame(width: width)
    }

    private var secondValue: BudgetSecondValuePresentation {
        semantics.secondValue(balance: value.balance, activity: value.spent,
            carryover: value.carryover, currency: month.currency)
    }
}
