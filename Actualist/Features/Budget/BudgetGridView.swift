import SwiftUI

struct BudgetGridView: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewport: BudgetViewportModel
    let actions: BudgetWorkspaceActions
    let presentation: BudgetGridPresentation
    let metrics: BudgetLayoutMetrics
    @Binding var scrollPosition: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    LazyVStack(spacing: 0) {
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
                } header: {
                    BudgetGridMonthHeaders(
                        presentation: presentation,
                        metrics: metrics,
                        actions: actions
                    )
                }
            }
            .padding(.horizontal, BudgetLayoutMetrics.defaultHorizontalMargins / 2)
            .padding(.bottom, 24)
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
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    if group.source.hasUserNote {
                        Image(systemName: "note.text").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
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
                    total(values.map { month.currency.formatted($0.budgeted) }, label: "Assigned", group: group, month: month)
                    total(values.map { month.currency.formatted($0.balance) }, label: "Available", group: group, month: month)
                }
                .padding(.horizontal, 8)
                .frame(width: metrics.monthColumnWidth)
            }
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .padding(.top, 8)
    }

    private func total(_ value: String?, label: String, group: BudgetGridPresentation.Group, month: BudgetGridPresentation.Month) -> some View {
        Text(value ?? "—")
            .font(.subheadline.weight(.semibold))
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
                        .font(.subheadline)
                        .lineLimit(2)
                    if category.source.hasUserNote {
                        Image(systemName: "note.text").font(.caption2)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
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
                        .frame(width: metrics.monthColumnWidth, height: 48)
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

    var body: some View {
        HStack(spacing: 8) {
            Button {
                viewport.beginAssignmentEditing(categoryID: category.id, month: month.id)
            } label: {
                Text(month.currency.formatted(value.budgeted))
                    .foregroundStyle(isEditing ? ActualistTheme.accent : ActualistTheme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("\(category.title), \(month.title), Assigned, \(month.currency.formatted(value.budgeted))")
            .accessibilityIdentifier("assigned-\(month.id)-\(category.id)")
            .popover(isPresented: Binding(get: { isEditing }, set: { if !$0 && isEditing { viewport.cancelAssignmentEditing() } })) {
                BudgetAssignmentPopover(viewport: viewport, actions: actions, categoryName: category.title)
                    .presentationCompactAdaptation(.popover)
                    .appSwitcherPrivacyProtected(using: appState)
            }

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
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("\(category.title), \(month.title), Available, \(month.currency.formatted(value.balance))")
            .accessibilityIdentifier("available-\(month.id)-\(category.id)")
        }
        .font(.subheadline.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.horizontal, 8)
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
