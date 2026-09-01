import SwiftUI

struct TransactionCategorySelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    let viewModel: TransactionEditorViewModel?
    let providedCategoryGroups: [TransactionEditorCategoryGroup]
    let providedSelectedCategoryID: String?
    let isLoadingProvidedCategories: Bool
    let showsUncategorizedOption: Bool
    let onSelectCategory: ((TransactionEditorCategoryOption) -> Void)?
    let onClearCategory: (() -> Void)?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    init(viewModel: TransactionEditorViewModel) {
        self.viewModel = viewModel
        providedCategoryGroups = []
        providedSelectedCategoryID = nil
        isLoadingProvidedCategories = false
        showsUncategorizedOption = true
        onSelectCategory = nil
        onClearCategory = nil
    }

    init(
        categoryGroups: [TransactionEditorCategoryGroup],
        selectedCategoryID: String? = nil,
        isLoading: Bool = false,
        showsUncategorizedOption: Bool = false,
        onSelectCategory: @escaping (TransactionEditorCategoryOption) -> Void,
        onClearCategory: (() -> Void)? = nil
    ) {
        viewModel = nil
        providedCategoryGroups = categoryGroups
        providedSelectedCategoryID = selectedCategoryID
        isLoadingProvidedCategories = isLoading
        self.showsUncategorizedOption = showsUncategorizedOption
        self.onSelectCategory = onSelectCategory
        self.onClearCategory = onClearCategory
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var categoryGroups: [TransactionEditorCategoryGroup] {
        if let viewModel {
            return viewModel.categorySelectionGroups(matching: searchText)
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else {
            return providedCategoryGroups
        }

        return providedCategoryGroups.compactMap { group in
            let options = group.options.filter { option in
                option.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || group.name.localizedCaseInsensitiveContains(trimmedSearch)
            }

            guard !options.isEmpty else {
                return nil
            }

            return TransactionEditorCategoryGroup(
                id: group.id,
                name: group.name,
                options: options
            )
        }
    }

    private var selectedCategoryID: String? {
        viewModel?.selectedCategoryID ?? providedSelectedCategoryID
    }

    private var isLoadingCategories: Bool {
        viewModel?.isLoadingCategoryBalances ?? isLoadingProvidedCategories
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        searchField

                        if trimmedSearchText.isEmpty && showsUncategorizedOption {
                            uncategorizedButton
                        }

                        if isLoadingCategories, categoryGroups.isEmpty {
                            ProgressView("Loading categories")
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else if categoryGroups.isEmpty {
                            Text("No matching categories")
                                .font(ActualistTypography.rowTitle(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 18)
                        } else {
                            destinationGroups
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .actualistToolbarGlassButton()
                }

            }
        }
        .presentationDetents([.medium, .large])
        .appSwitcherPrivacyAwareDragIndicator()
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

            TextField("Search Categories", text: $searchText)
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

    private var uncategorizedButton: some View {
        Button {
            viewModel?.clearCategory()
            onClearCategory?()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text("Uncategorized")
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer()

                if selectedCategoryID == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var destinationGroups: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(categoryGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.name)
                        .font(ActualistTypography.rowLabel(for: density).weight(.bold))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .padding(.horizontal, 22)

                    VStack(spacing: 0) {
                        ForEach(group.options) { option in
                            categoryButton(option)

                            if option.id != group.options.last?.id {
                                Divider()
                                    .overlay(ActualistTheme.separator)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
    }

    private func categoryButton(_ option: TransactionEditorCategoryOption) -> some View {
        Button {
            viewModel?.selectCategory(option)
            onSelectCategory?(option)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(option.title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                if let valueText = option.valueText {
                    Text(valueText)
                        .font(ActualistTypography.rowBadge(for: density))
                        .foregroundStyle(categoryValueForeground(option))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(categoryValueBackground(option), in: Capsule())
                }

                if option.id == selectedCategoryID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func categoryValueBackground(_ option: TransactionEditorCategoryOption) -> Color {
        guard let amount = option.amount else {
            return Color.clear
        }

        if amount < 0 {
            return ActualistTheme.danger
        } else if amount == 0 {
            return ActualistTheme.neutral
        } else {
            return ActualistTheme.positive
        }
    }

    private func categoryValueForeground(_ option: TransactionEditorCategoryOption) -> Color {
        guard let amount = option.amount else {
            return ActualistTheme.secondaryText
        }

        if amount < 0 {
            return ActualistTheme.dangerForeground
        } else if amount == 0 {
            return ActualistTheme.neutralForeground
        } else {
            return ActualistTheme.positiveForeground
        }
    }
}
