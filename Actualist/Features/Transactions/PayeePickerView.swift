import SwiftUI

struct PayeePickerItem: Identifiable, Hashable {
    static let transferSectionTitle = "Transfer To/From"

    let id: String
    let title: String
    let isTransfer: Bool
    let searchAliases: [String]

    init(id: String, title: String, isTransfer: Bool = false, searchAliases: [String] = []) {
        self.id = id
        self.title = title
        self.isTransfer = isTransfer
        self.searchAliases = searchAliases
    }

    func matches(searchText: String) -> Bool {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearchText.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(trimmedSearchText)
            || searchAliases.contains { $0.localizedCaseInsensitiveContains(trimmedSearchText) }
            || (isTransfer
                && Self.transferSectionTitle.localizedCaseInsensitiveContains(trimmedSearchText))
    }
}

struct PayeePickerSection: Identifiable, Equatable {
    let id: String
    let title: String?
    let items: [PayeePickerItem]
}

struct PayeePickerProjection {
    let items: [PayeePickerItem]
    let searchText: String

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var shouldOfferCustomPayee: Bool {
        guard !trimmedSearchText.isEmpty else { return false }
        return !items.contains { item in
            ([item.title] + item.searchAliases).contains {
                $0.caseInsensitiveCompare(trimmedSearchText) == .orderedSame
            }
        }
    }

    var sections: [PayeePickerSection] {
        let filteredItems = items.filter { $0.matches(searchText: trimmedSearchText) }
        let regularItems = filteredItems.filter { !$0.isTransfer }
        let transferItems = filteredItems.filter(\.isTransfer)
        let regular = PayeePickerSection(id: "payees", title: nil, items: regularItems)
        let transfers = PayeePickerSection(
            id: "transfers",
            title: PayeePickerItem.transferSectionTitle,
            items: transferItems
        )
        return (trimmedSearchText.isEmpty ? [regular, transfers] : [transfers, regular])
            .filter { !$0.items.isEmpty }
    }
}

struct PayeePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    let title: String
    let items: [PayeePickerItem]
    let selectedIDs: Set<String>
    let allowsMultipleSelection: Bool
    let isLoading: Bool
    let searchPrompt: String
    let onSelect: (String) -> Void
    let onCustomSelect: ((String) -> Void)?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    init(
        title: String,
        items: [PayeePickerItem],
        selectedIDs: Set<String>,
        allowsMultipleSelection: Bool,
        isLoading: Bool,
        searchPrompt: String,
        onSelect: @escaping (String) -> Void,
        onCustomSelect: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.items = items
        self.selectedIDs = selectedIDs
        self.allowsMultipleSelection = allowsMultipleSelection
        self.isLoading = isLoading
        self.searchPrompt = searchPrompt
        self.onSelect = onSelect
        self.onCustomSelect = onCustomSelect
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        searchField
                        customPayeeButton
                        pickerContent
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        if allowsMultipleSelection {
                            Text("Done")
                        } else {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            Task {
                await Task.yield()
                isSearchFocused = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ActualistTheme.secondaryText)
            TextField(searchPrompt, text: $searchText)
                .textInputAutocapitalization(.words)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ActualistTheme.control, in: Capsule())
    }

    @ViewBuilder
    private var customPayeeButton: some View {
        if let onCustomSelect, shouldOfferCustomPayee {
            Button {
                onCustomSelect(trimmedSearchText)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(ActualistTheme.accent)
                    Text("Use \"\(trimmedSearchText)\"")
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(16)
                .background(
                    ActualistTheme.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var pickerContent: some View {
        if isLoading {
            ProgressView("Loading payees")
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
        } else if sections.isEmpty {
            Text("No matching payees")
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(sections) { section in
                    if let title = section.title {
                        sectionHeader(title)
                    }
                    ForEach(section.items) { item in
                        payeeRow(item)
                        if item.id != section.items.last?.id {
                            Divider()
                                .overlay(ActualistTheme.separator)
                                .padding(.leading, item.isTransfer ? 50 : 16)
                        }
                    }
                }
            }
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(ActualistTypography.rowTitle(for: density).weight(.semibold))
            .foregroundStyle(ActualistTheme.accent)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func payeeRow(_ item: PayeePickerItem) -> some View {
        Button {
            onSelect(item.id)
            if !allowsMultipleSelection {
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                if item.isTransfer {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                        .foregroundStyle(ActualistTheme.accent)
                        .font(.body)
                }
                Text(item.title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                Spacer()
                if selectedIDs.contains(item.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, density.transactionRowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldOfferCustomPayee: Bool {
        onCustomSelect != nil && projection.shouldOfferCustomPayee
    }

    private var projection: PayeePickerProjection {
        PayeePickerProjection(items: items, searchText: trimmedSearchText)
    }

    private var sections: [PayeePickerSection] {
        projection.sections
    }
}
