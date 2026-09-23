import SwiftUI
import UniformTypeIdentifiers

struct BudgetCategoryReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lastDropEvent: DropEvent?
    @Bindable var controller: BudgetCategoryLifecycleController
    let selectedMonth: String?
    let budgetID: String?
    let repository: any BudgetRepositoryProtocol
    let onSaved: @MainActor () async -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if let draft = controller.reorder.draft {
                        ForEach(draft.groups) { group in
                            groupCard(group)
                        }
                    }

                    if let errorMessage = controller.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(ActualistTheme.danger)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                ActualistTheme.surface,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .accessibilityIdentifier("budget-category-reorder-error")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .accessibilityIdentifier("budget-category-reorder-sheet")
            .onDrop(
                of: [UTType.text],
                delegate: ReorderContainerDropDelegate(lastDropEvent: $lastDropEvent)
            )
            .navigationTitle("Reorder Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .disabled(controller.isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(controller.isSubmitting)
                        .accessibilityIdentifier("budget-category-reorder-save")
                }
            }
        }
        .interactiveDismissDisabled(controller.isSubmitting)
    }

    private func groupCard(_ group: BudgetCategoryOutlineDraft.Group) -> some View {
        VStack(spacing: 0) {
            groupLabel(group)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("budget-category-reorder-group-\(group.id)")
                .overlay {
                    VStack(spacing: 0) {
                        groupInsertionZone(group.id, edge: .before)
                        groupInsertionZone(group.id, edge: .after)
                    }
                }
                .onDrag {
                    beginDrag(.group(group.id))
                } preview: {
                    dragPreview(name: group.name, hidden: group.hidden, isGroup: true)
                }

            ForEach(group.categories) { category in
                Divider()
                    .overlay(ActualistTheme.separator)
                    .padding(.leading, 46)

                categoryRow(category, groupID: group.id)
            }

            categoryEndDropArea(groupID: group.id)
        }
        .background(
            ActualistTheme.surface,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onDrop(
            of: [UTType.text],
            delegate: GroupCardDropDelegate(
                lastDropEvent: $lastDropEvent,
                groupID: group.id,
                controller: controller
            )
        )
    }

    private func groupLabel(_ group: BudgetCategoryOutlineDraft.Group) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(group.name)
                .font(.headline)
            if group.hidden {
                Image(systemName: "eye.slash")
                    .accessibilityLabel("Hidden")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .opacity(group.hidden ? BudgetLayout.hiddenCategoryOpacity : 1)
    }

    private func categoryRow(
        _ category: BudgetCategoryOutlineDraft.Category,
        groupID: String
    ) -> some View {
        categoryLabel(category)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("budget-category-reorder-category-\(category.id)")
            .onDrag {
                beginDrag(.category(category.id))
            } preview: {
                dragPreview(
                    name: category.name.actualistCategoryNameParts.name,
                    hidden: category.hidden,
                    isGroup: false
                )
            }
            .onDrop(
                of: [UTType.text],
                delegate: dropDelegate(for: .category(category.id, groupID: groupID))
            )
    }

    private func categoryLabel(_ category: BudgetCategoryOutlineDraft.Category) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(category.name.actualistCategoryNameParts.name)
            if category.hidden {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .accessibilityLabel("Hidden")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(ActualistTheme.primaryText)
        .opacity(category.hidden ? BudgetLayout.hiddenCategoryOpacity : 1)
    }

    private func dragPreview(name: String, hidden: Bool, isGroup: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(name)
                .font(isGroup ? .headline : .body)
                .lineLimit(1)
            if hidden {
                Image(systemName: "eye.slash")
                    .font(.caption)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(ActualistTheme.primaryText)
        .opacity(hidden ? BudgetLayout.hiddenCategoryOpacity : 1)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            ActualistTheme.surface,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func categoryEndDropArea(groupID: String) -> some View {
        Color.clear
            .frame(height: 10)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .onDrop(
                of: [UTType.text],
                delegate: dropDelegate(for: .categoryEnd(groupID))
            )
    }

    private func groupInsertionZone(
        _ groupID: String,
        edge: BudgetCategoryReorderPlacementPolicy.GroupEdge
    ) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .onDrop(
                of: [UTType.text],
                delegate: dropDelegate(for: .group(groupID, edge: edge))
            )
    }

    private func beginDrag(_ item: DragItem) -> NSItemProvider {
        let payload = DragPayload(id: UUID(), item: item)
        let provider = NSItemProvider(object: item.token as NSString)
        provider.suggestedName = payload.providerName
        return provider
    }

    private func dropDelegate(for target: DropTarget) -> OutlineDropDelegate {
        OutlineDropDelegate(
            lastDropEvent: $lastDropEvent,
            target: target,
            controller: controller
        )
    }

    private func save() {
        Task {
            guard await controller.saveReorder(
                selectedMonth: selectedMonth,
                budgetID: budgetID,
                repository: repository
            ) else { return }
            await onSaved()
            dismiss()
        }
    }

    private enum DragItem: Equatable {
        case group(String)
        case category(String)

        var token: String {
            switch self {
            case .group(let id): "group:\(id)"
            case .category(let id): "category:\(id)"
            }
        }

        init?(token: String) {
            if token.hasPrefix("group:") {
                self = .group(String(token.dropFirst("group:".count)))
            } else if token.hasPrefix("category:") {
                self = .category(String(token.dropFirst("category:".count)))
            } else {
                return nil
            }
        }

        func canEnter(
            groupID: String,
            groups: [BudgetCategoryOutlineDraft.Group]
        ) -> Bool {
            guard let destination = groups.first(where: { $0.id == groupID }) else { return false }
            switch self {
            case .group(let id):
                return groups.first(where: { $0.id == id })?.isIncome == destination.isIncome
            case .category(let id):
                return groups.lazy.flatMap(\.categories).first(where: { $0.id == id })?.isIncome
                    == destination.isIncome
            }
        }
    }

    private enum DropTarget: Equatable {
        case group(String, edge: BudgetCategoryReorderPlacementPolicy.GroupEdge)
        case categoryStart(String)
        case category(String, groupID: String)
        case categoryEnd(String)

        var groupID: String {
            switch self {
            case .group(let id, _), .categoryStart(let id), .categoryEnd(let id): id
            case .category(_, let groupID): groupID
            }
        }
    }

    private struct DragPayload {
        private static let separator: Character = "|"

        let id: UUID
        let item: DragItem

        var providerName: String {
            "\(id.uuidString)\(Self.separator)\(item.token)"
        }

        init(id: UUID, item: DragItem) {
            self.id = id
            self.item = item
        }

        init?(info: DropInfo) {
            guard let providerName = info.itemProviders(for: [UTType.text]).first?.suggestedName,
                  let separatorIndex = providerName.firstIndex(of: Self.separator),
                  let id = UUID(uuidString: String(providerName[..<separatorIndex])),
                  let item = DragItem(token: String(providerName[providerName.index(after: separatorIndex)...]))
            else { return nil }
            self.init(id: id, item: item)
        }
    }

    private struct DropEvent: Equatable {
        let dragID: UUID
        let target: DropTarget
    }

    private struct OutlineDropDelegate: DropDelegate {
        @Binding var lastDropEvent: DropEvent?
        let target: DropTarget
        let controller: BudgetCategoryLifecycleController

        func validateDrop(info: DropInfo) -> Bool {
            guard info.hasItemsConforming(to: [UTType.text]),
                  let groups = controller.reorder.draft?.groups else { return false }
            guard let payload = DragPayload(info: info) else { return true }
            return canAccept(payload.item, target: target, groups: groups)
        }

        func dropEntered(info: DropInfo) {
            guard let payload = DragPayload(info: info),
                  let groups = controller.reorder.draft?.groups,
                  canAccept(payload.item, target: target, groups: groups) else { return }
            switch (payload.item, target) {
            case (.group(let movingID), .group(let destinationID, _)):
                guard movingID != destinationID else { return }
            case (.group, _):
                return
            case (.category(let movingID), .category(let destinationID, _)):
                guard movingID != destinationID else { return }
            default:
                break
            }
            let event = DropEvent(
                dragID: payload.id,
                target: effectiveTarget(for: payload.item)
            )
            guard lastDropEvent != event else { return }
            lastDropEvent = event
            withAnimation(.snappy(duration: 0.2)) {
                relocate(payload.item, to: target)
            }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            validateDrop(info: info) ? DropProposal(operation: .move) : nil
        }

        func performDrop(info: DropInfo) -> Bool {
            guard validateDrop(info: info) else { return false }
            lastDropEvent = nil
            return true
        }

        private func canAccept(
            _ item: DragItem,
            target: DropTarget,
            groups: [BudgetCategoryOutlineDraft.Group]
        ) -> Bool {
            switch (item, target) {
            case (.group, _):
                return item.canEnter(groupID: target.groupID, groups: groups)
            case (.category, .group(let groupID, _)),
                 (.category, .categoryStart(let groupID)),
                 (.category, .categoryEnd(let groupID)):
                return item.canEnter(groupID: groupID, groups: groups)
            case (.category(let movingID), .category(let destinationID, let groupID)):
                if movingID == destinationID {
                    return item.canEnter(groupID: groupID, groups: groups)
                }
                return BudgetCategoryReorderPlacementPolicy.categoryPlacement(
                    movingCategoryID: movingID,
                    overCategoryID: destinationID,
                    destinationGroupID: groupID,
                    groups: groups
                ) != nil
            }
        }

        private func effectiveTarget(for item: DragItem) -> DropTarget {
            switch item {
            case .group:
                target
            case .category:
                switch target {
                case .group(let groupID, _):
                    .categoryStart(groupID)
                default:
                    target
                }
            }
        }

        private func relocate(_ item: DragItem, to target: DropTarget) {
            guard let groups = controller.reorder.draft?.groups else { return }
            switch (item, target) {
            case (.group(let movingID), .group(let destinationID, let edge)):
                guard let placement = BudgetCategoryReorderPlacementPolicy.groupPlacement(
                    movingGroupID: movingID,
                    overGroupID: destinationID,
                    edge: edge,
                    groups: groups
                ) else { return }
                controller.reorder.moveGroup(
                    id: movingID,
                    beforeGroupID: placement.beforeGroupID
                )
            case (.category(let movingID), .group(let groupID, _)),
                 (.category(let movingID), .categoryStart(let groupID)):
                guard let group = groups.first(where: { $0.id == groupID }) else { return }
                let beforeCategoryID = group.categories.first(where: { $0.id != movingID })?.id
                controller.reorder.moveCategory(
                    id: movingID,
                    toGroupID: groupID,
                    beforeCategoryID: beforeCategoryID
                )
            case (.category(let movingID), .category(let destinationID, let groupID)):
                guard let placement = BudgetCategoryReorderPlacementPolicy.categoryPlacement(
                    movingCategoryID: movingID,
                    overCategoryID: destinationID,
                    destinationGroupID: groupID,
                    groups: groups
                ) else { return }
                controller.reorder.moveCategory(
                    id: movingID,
                    toGroupID: placement.groupID,
                    beforeCategoryID: placement.beforeCategoryID
                )
            case (.category(let movingID), .categoryEnd(let groupID)):
                controller.reorder.moveCategory(
                    id: movingID,
                    toGroupID: groupID,
                    beforeCategoryID: nil
                )
            default:
                break
            }
        }
    }

    private struct GroupCardDropDelegate: DropDelegate {
        @Binding var lastDropEvent: DropEvent?
        let groupID: String
        let controller: BudgetCategoryLifecycleController

        func validateDrop(info: DropInfo) -> Bool {
            guard info.hasItemsConforming(to: [UTType.text]) else { return false }
            guard let payload = DragPayload(info: info),
                  let groups = controller.reorder.draft?.groups else { return true }
            return payload.item.canEnter(groupID: groupID, groups: groups)
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            validateDrop(info: info) ? DropProposal(operation: .move) : nil
        }

        func performDrop(info: DropInfo) -> Bool {
            guard validateDrop(info: info) else { return false }
            lastDropEvent = nil
            return true
        }
    }

    private struct ReorderContainerDropDelegate: DropDelegate {
        @Binding var lastDropEvent: DropEvent?

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [UTType.text])
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            validateDrop(info: info) ? DropProposal(operation: .move) : nil
        }

        func performDrop(info: DropInfo) -> Bool {
            guard validateDrop(info: info) else { return false }
            lastDropEvent = nil
            return true
        }
    }
}

enum BudgetCategoryReorderPlacementPolicy {
    enum GroupEdge: Equatable {
        case before
        case after
    }

    struct GroupPlacement: Equatable {
        let beforeGroupID: String?
    }

    struct CategoryPlacement: Equatable {
        let groupID: String
        let beforeCategoryID: String?
    }

    static func groupPlacement(
        movingGroupID: String,
        overGroupID destinationGroupID: String,
        edge: GroupEdge,
        groups: [BudgetCategoryOutlineDraft.Group]
    ) -> GroupPlacement? {
        guard movingGroupID != destinationGroupID,
              let movingIndex = groups.firstIndex(where: { $0.id == movingGroupID }),
              let destinationIndex = groups.firstIndex(where: { $0.id == destinationGroupID }),
              groups[movingIndex].isIncome == groups[destinationIndex].isIncome else { return nil }

        if edge == .after {
            let nextID = groups.dropFirst(destinationIndex + 1).first(where: {
                $0.id != movingGroupID && $0.isIncome == groups[movingIndex].isIncome
            })?.id
            return GroupPlacement(beforeGroupID: nextID)
        }
        return GroupPlacement(beforeGroupID: destinationGroupID)
    }

    static func categoryPlacement(
        movingCategoryID: String,
        overCategoryID destinationCategoryID: String,
        destinationGroupID: String,
        groups: [BudgetCategoryOutlineDraft.Group]
    ) -> CategoryPlacement? {
        guard movingCategoryID != destinationCategoryID,
              let source = categoryPosition(movingCategoryID, groups: groups),
              let destinationGroupIndex = groups.firstIndex(where: { $0.id == destinationGroupID }),
              let destinationCategoryIndex = groups[destinationGroupIndex].categories.firstIndex(
                where: { $0.id == destinationCategoryID }
              ),
              source.category.isIncome == groups[destinationGroupIndex].isIncome else { return nil }

        let destinationPosition = (destinationGroupIndex, destinationCategoryIndex)
        let sourceIsBefore = source.groupIndex < destinationPosition.0
            || source.groupIndex == destinationPosition.0
                && source.categoryIndex < destinationPosition.1
        let beforeCategoryID = sourceIsBefore
            ? groups[destinationGroupIndex].categories
                .dropFirst(destinationCategoryIndex + 1)
                .first(where: { $0.id != movingCategoryID })?.id
            : destinationCategoryID
        return CategoryPlacement(
            groupID: destinationGroupID,
            beforeCategoryID: beforeCategoryID
        )
    }

    private static func categoryPosition(
        _ categoryID: String,
        groups: [BudgetCategoryOutlineDraft.Group]
    ) -> (
        groupIndex: Int,
        categoryIndex: Int,
        category: BudgetCategoryOutlineDraft.Category
    )? {
        for (groupIndex, group) in groups.enumerated() {
            guard let categoryIndex = group.categories.firstIndex(where: { $0.id == categoryID }) else {
                continue
            }
            return (groupIndex, categoryIndex, group.categories[categoryIndex])
        }
        return nil
    }
}
