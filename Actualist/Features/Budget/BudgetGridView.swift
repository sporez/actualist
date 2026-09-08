import SwiftUI

struct BudgetGridView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    private var sizing: BudgetGridDensityMetrics { .init(density: density) }
    @Bindable var viewport: BudgetViewportModel
    let actions: BudgetWorkspaceActions
    let presentation: BudgetGridPresentation
    let metrics: BudgetLayoutMetrics
    @Binding var scrollPosition: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(presentation.groups) { group in
                    groupRow(group)
                        .id(group.id)
                    if viewport.expandedGroupIDs.contains(group.id) {
                        ForEach(group.categories) { category in
                            categoryRow(category, group: group)
                                .id(category.id)
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, BudgetLayoutMetrics.defaultHorizontalMargins / 2)
            .padding(.bottom, 24)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            BudgetGridMonthHeaders(
                presentation: presentation,
                metrics: metrics,
                actions: actions
            )
            .padding(.horizontal, BudgetLayoutMetrics.defaultHorizontalMargins / 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition(id: $scrollPosition, anchor: .top)
        .background(ActualistTheme.background)
        .accessibilityIdentifier("budget-grid")
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
                .frame(maxWidth: .infinity, minHeight: sizing.groupHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(group.title)
            .accessibilityValue(viewport.expandedGroupIDs.contains(group.id) ? "Expanded" : "Collapsed")
            .frame(width: metrics.categoryColumnWidth, alignment: .leading)
            .contextMenu {
                Button("Notes", systemImage: "note.text") { actions.openGroupNote(group.source) }
                if !group.source.isIncome {
                    Button(group.source.hidden == true ? "Show" : "Hide", systemImage: "eye") {
                        Task { await actions.toggleGroupHidden(group.source, using: appState) }
                    }
                }
            }

            ForEach(presentation.months) { month in
                let values = presentation.group(group.id, month: month)
                HStack(spacing: 8) {
                    total(values.map { month.currency.formatted($0.budgeted) }, label: month.semantics.budgetedLabel, group: group, month: month)
                    if month.semantics.showsActivity {
                        total(values.map { month.currency.formatted(BudgetModePresentation(isIncome: group.source.isIncome).activityAmount($0.spent)) }, label: group.source.isIncome ? "Received" : "Spent", group: group, month: month)
                    }
                    if !month.semantics.isTracking || !group.source.isIncome {
                        total(values.map { month.currency.formatted($0.balance) }, label: month.semantics.balanceLabel, group: group, month: month)
                    } else {
                        Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, sizing.cellPadding)
                .frame(width: metrics.monthColumnWidth)
            }
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .padding(.top, sizing.headerSpacing)
    }

    private func total(_ value: String?, label: String, group: BudgetGridPresentation.Group, month: BudgetGridPresentation.Month) -> some View {
        Text(value ?? "—")
            .font(ActualistTypography.rowValue(for: density))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("\(group.title), \(month.title), \(label), \(value ?? "Unavailable")")
    }

    private func categoryRow(_ category: BudgetGridPresentation.Category, group: BudgetGridPresentation.Group) -> some View {
        HStack(spacing: 0) {
            Button {
                if let month = viewport.anchorMonth {
                    viewport.selectCategory(categoryID: category.id, month: month)
                }
            } label: {
                HStack(spacing: 8) {
                    if let emoji = category.emoji {
                        Text(emoji).accessibilityHidden(true)
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
            .hoverEffect(.highlight)
            .accessibilityLabel("\(category.title), category details")
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
            }

            ForEach(presentation.months) { month in
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
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .background(ActualistTheme.surface)
        .opacity(BudgetCategoryVisibility.isEffectivelyHidden(category: category.source, group: group.source) ? 0.5 : 1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ActualistTheme.separator).frame(height: 0.5)
        }
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
            .hoverEffect(.highlight)
            .accessibilityLabel("\(category.title), \(month.title), \(semantics.budgetedLabel), \(month.currency.formatted(value.budgeted))")
            .accessibilityIdentifier("assigned-\(month.id)-\(category.id)")
            .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 && isEditing { viewport.cancelAssignmentEditing() } })) {
                BudgetAssignmentPopover(viewport: viewport, actions: actions, categoryName: category.title)
                    .presentationCompactAdaptation(.popover)
                    .appSwitcherPrivacyProtected(using: appState)
            }

            if semantics.showsActivity {
                Button {
                    viewport.selectCategory(categoryID: category.id, month: month.id)
                } label: {
                    Text(month.currency.formatted(semantics.activityAmount(value.spent)))
                        .frame(maxWidth: .infinity, minHeight: sizing.rowHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(category.title), \(month.title), \(semantics.activityLabel), \(month.currency.formatted(semantics.activityAmount(value.spent)))")
                .accessibilityIdentifier("activity-\(month.id)-\(category.id)")
            }
            if semantics.showsBalance {
                Button {
                    viewport.selectCategory(categoryID: category.id, month: month.id)
                } label: {
                    Text(month.currency.formatted(value.balance))
                        .foregroundStyle(availableForeground)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(availableBackground, in: Capsule())
                        .overlay(alignment: .topTrailing) {
                            if value.carryover && !appState.settings.hideCarryoverArrows {
                                BudgetCarryoverBadge(fill: availableBackground, foreground: availableForeground)
                                    .offset(x: 3, y: -3)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: sizing.rowHeight, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("\(category.title), \(month.title), \(semantics.balanceLabel), \(month.currency.formatted(value.balance))")
                .accessibilityIdentifier("available-\(month.id)-\(category.id)")
            } else {
                Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
            }
        }
        .font(ActualistTypography.rowValue(for: density))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, sizing.cellPadding)
        .frame(width: width)
        .background(isEditing ? ActualistTheme.control : Color.clear)
    }

    private var availableBackground: Color {
        value.balance < 0 ? ActualistTheme.danger : value.balance == 0 ? ActualistTheme.neutral : ActualistTheme.positive
    }

    private var availableForeground: Color {
        value.balance < 0 ? ActualistTheme.dangerForeground : value.balance == 0 ? ActualistTheme.neutralForeground : ActualistTheme.positiveForeground
    }
}
