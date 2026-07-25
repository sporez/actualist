import SwiftUI

struct BudgetOverspentCategoriesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    let categories: [BudgetOverspentCategoryOption]
    let isReadOnly: Bool
    let isPrivacyModeEnabled: Bool
    let onSelect: (BudgetOverspentCategoryOption) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if categories.isEmpty {
                            GlassPanel {
                                VStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.title)
                                        .foregroundStyle(ActualistTheme.positive)
                                    Text("No overspent categories")
                                        .font(ActualistTypography.rowTitle(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 0) {
                                ForEach(categories) { category in
                                    Button {
                                        guard !isReadOnly else {
                                            return
                                        }
                                        onSelect(category)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(categoryName(category))
                                                    .font(ActualistTypography.rowTitle(for: density))
                                                    .foregroundStyle(ActualistTheme.primaryText)
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.84)

                                                Text(groupName(category))
                                                    .font(ActualistTypography.rowBadge(for: density))
                                                    .foregroundStyle(ActualistTheme.secondaryText)
                                            }

                                            Spacer()

                                            Text(amountText(category))
                                                .font(ActualistTypography.rowValue(for: density))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.78)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(ActualistTheme.danger.opacity(0.84), in: Capsule())

                                            Image(systemName: "chevron.right")
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(ActualistTheme.secondaryText)
                                        }
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if category.id != categories.last?.id {
                                        Divider()
                                            .overlay(ActualistTheme.separator)
                                            .padding(.leading, 18)
                                    }
                                }
                            }
                            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Cover Overspending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func categoryName(_ category: BudgetOverspentCategoryOption) -> String {
        guard isPrivacyModeEnabled else {
            return category.categoryName
        }

        return PrivacyDisplay.name(for: .category, seed: category.id)
    }

    private func groupName(_ category: BudgetOverspentCategoryOption) -> String {
        guard isPrivacyModeEnabled else {
            return category.groupName
        }

        return PrivacyDisplay.name(for: .categoryGroup, seed: category.groupName)
    }

    private func amountText(_ category: BudgetOverspentCategoryOption) -> String {
        guard isPrivacyModeEnabled else {
            return category.amountText
        }

        return PrivacyDisplay.money(
            category.category.balance,
            seed: "overspent-category-\(category.id)",
            maximumDollars: 900
        )
    }
}

struct BudgetMonthPicker: View {
    @Environment(\.actualistDensity) private var density

    let availableMonths: [String]
    let selectedMonth: String?
    let allowsUnlistedMonths: Bool
    let onSelect: (String) -> Void

    @State private var displayedYear: Int

    init(
        availableMonths: [String],
        selectedMonth: String?,
        allowsUnlistedMonths: Bool,
        onSelect: @escaping (String) -> Void
    ) {
        self.availableMonths = availableMonths
        self.selectedMonth = selectedMonth
        self.allowsUnlistedMonths = allowsUnlistedMonths
        self.onSelect = onSelect
        _displayedYear = State(initialValue: Self.initialYear(
            selectedMonth: selectedMonth,
            availableMonths: availableMonths
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    displayedYear -= 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.bold))
                }
                .disabled(!hasPreviousYear)

                Spacer()

                Text(String(displayedYear))
                    .font(ActualistTypography.sectionTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                Spacer()

                Button {
                    displayedYear += 1
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.bold))
                }
                .disabled(!hasNextYear)
            }
            .foregroundStyle(ActualistTheme.accent)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().overlay(ActualistTheme.separator)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 18) {
                ForEach(1...12, id: \.self) { monthNumber in
                    let monthID = Self.monthID(year: displayedYear, month: monthNumber)
                    Button {
                        onSelect(monthID)
                    } label: {
                        Text(Self.monthName(for: monthNumber))
                            .font(monthID == selectedMonth ? ActualistTypography.control(for: density) : ActualistTypography.body(for: density))
                            .foregroundStyle(monthTextColor(monthID))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(monthBackground(monthID), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelect(monthID))
                }
            }
            .padding(20)
        }
        .frame(width: 320)
        .background(ActualistTheme.surface)
    }

    private var availableMonthSet: Set<String> {
        Set(availableMonths)
    }

    private var availableYears: [Int] {
        Array(Set(availableMonths.compactMap(Self.year))).sorted()
    }

    private var hasPreviousYear: Bool {
        allowsUnlistedMonths || availableYears.contains(where: { $0 < displayedYear })
    }

    private var hasNextYear: Bool {
        allowsUnlistedMonths || availableYears.contains(where: { $0 > displayedYear })
    }

    private func canSelect(_ monthID: String) -> Bool {
        allowsUnlistedMonths || availableMonthSet.contains(monthID)
    }

    private func monthTextColor(_ monthID: String) -> Color {
        if monthID == selectedMonth {
            return ActualistTheme.primaryText
        }

        return canSelect(monthID) ? ActualistTheme.primaryText : ActualistTheme.secondaryText.opacity(0.36)
    }

    private func monthBackground(_ monthID: String) -> Color {
        monthID == selectedMonth ? ActualistTheme.accent : Color.clear
    }

    private static func initialYear(selectedMonth: String?, availableMonths: [String]) -> Int {
        if let selectedYear = selectedMonth.flatMap(year) {
            return selectedYear
        }

        if let latestYear = availableMonths.compactMap(year).max() {
            return latestYear
        }

        return Calendar(identifier: .gregorian).component(.year, from: Date())
    }

    private static func monthID(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    private static func year(from monthID: String) -> Int? {
        guard monthID.count >= 4 else {
            return nil
        }

        return Int(monthID.prefix(4))
    }

    private static func monthName(for monthNumber: Int) -> String {
        Calendar.current.shortMonthSymbols[monthNumber - 1]
    }
}

