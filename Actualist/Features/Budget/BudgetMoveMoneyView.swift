import SwiftUI

struct BudgetMoveMoneyView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var viewModel: BudgetViewModel
    let onSaved: () -> Void

    @State private var isDestinationPickerPresented = false
    @State private var didAutoPresentDestinationPicker = false
    @State private var isNumberPadVisible = false

    var body: some View {
        ZStack {
            ActualistTheme.background.ignoresSafeArea()

            if let draft = viewModel.moveMoneyDraft {
                VStack(spacing: 0) {
                    moveHeader(draft)

                    GeometryReader { proxy in
                        VStack(spacing: 12) {
                            ScrollView {
                                VStack(spacing: 18) {
                                    destinationCard(draft)

                                    if let errorMessage = viewModel.activeMoveMoneyErrorMessage {
                                        Text(errorMessage)
                                            .font(ActualistTypography.rowTitle(for: density))
                                            .foregroundStyle(ActualistTheme.danger)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(16)
                                            .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                            .scrollIndicators(.hidden)
                            .frame(maxHeight: max(148, proxy.size.height - reservedBottomHeight))

                            if isNumberPadVisible {
                                BudgetMoveMoneyNumberPad(
                                    canSubmit: viewModel.canSubmitMoveMoney,
                                    isSubmitting: viewModel.isSubmittingMoveMoney,
                                    appendDigit: { viewModel.appendMoveMoneyDigit($0) },
                                    deleteDigit: { viewModel.deleteMoveMoneyDigit() },
                                    clear: { viewModel.clearMoveMoneyAmount() },
                                    submit: submitMoveMoney
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                compactSubmitButton
                            }
                        }
                        .animation(.snappy(duration: 0.24), value: isNumberPadVisible)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, -28)
                    .padding(.bottom, 10)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $isDestinationPickerPresented) {
            BudgetMoveMoneyDestinationPicker(viewModel: viewModel)
                .environment(appState)
                .appSwitcherPrivacyProtected()
        }
        .task(id: viewModel.moveMoneyDraft?.focusedCategoryID) {
            guard !didAutoPresentDestinationPicker else {
                return
            }

            didAutoPresentDestinationPicker = true
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard viewModel.isMoveMoneyPresented,
                  viewModel.moveMoneyDraft?.destination == nil else {
                return
            }

            isDestinationPickerPresented = true
        }
        .onChange(of: isDestinationPickerPresented) { _, presented in
            guard !presented else {
                return
            }

            Task {
                await viewModel.playMoveMoneyCoverIntro()
            }
        }
    }

    private var reservedBottomHeight: CGFloat {
        isNumberPadVisible ? BudgetMoveMoneyLayout.numberPadReservedHeight : BudgetMoveMoneyLayout.compactSubmitReservedHeight
    }

    private var compactSubmitButton: some View {
        Button(action: submitMoveMoney) {
            Text(viewModel.isSubmittingMoveMoney ? "saving" : "done")
                .font(ActualistTypography.control(for: density))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(ActualistTheme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSubmitMoveMoney)
        .opacity(viewModel.canSubmitMoveMoney ? 1 : 0.45)
        .padding(.horizontal, 12)
        .accessibilityLabel("Move money")
    }

    private func submitMoveMoney() {
        Task {
            if await viewModel.submitMoveMoney(using: appState) {
                onSaved()
                dismiss()
            }
        }
    }

    private func moveHeader(_ draft: BudgetMoveMoneyDraft) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 14) {
                Text(draft.direction.headerTitle)
                    .font(ActualistTypography.sectionTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)

                VStack(spacing: 10) {
                    Text(moveFocusedCategoryName(draft))
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(moveHeaderAmountText(draft))
                        .font(ActualistTypography.workScreenAmount(for: density))
                        .foregroundStyle(moveHeaderAmountForeground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.26), in: Capsule())
                }

                VStack(spacing: 7) {
                    Button {
                        viewModel.toggleMoveMoneyDirection()
                        isNumberPadVisible = false
                        if viewModel.moveMoneyDraft?.destination == nil {
                            isDestinationPickerPresented = true
                        }
                    } label: {
                        Image(systemName: draft.direction.arrowSystemImage)
                            .font(.title.weight(.bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.black.opacity(0.72), Color.white.opacity(0.92))
                            .padding(10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.isSubmitting)
                    .accessibilityLabel("Switch move money direction")

                    Text(draft.direction.counterpartyPrompt)
                        .font(ActualistTypography.rowLabel(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .padding(.top, 4)

                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, BudgetMoveMoneyLayout.headerTopInset)
            .padding(.horizontal, BudgetMoveMoneyLayout.headerHorizontalPadding)

            VStack {
                Button {
                    viewModel.cancelMoveMoney()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .frame(width: 54, height: 54)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draft.isSubmitting)
            }
            .padding(.top, BudgetMoveMoneyLayout.closeButtonTopInset)
            .padding(.leading, BudgetMoveMoneyLayout.closeButtonLeadingInset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 332)
        .background(
            UnevenRoundedRectangle(
                cornerRadii: RectangleCornerRadii(bottomLeading: 32, bottomTrailing: 32),
                style: .continuous
            )
            .fill(Color(red: 0.14, green: 0.37, blue: 0.04))
        )
    }

    private func destinationCard(_ draft: BudgetMoveMoneyDraft) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Text(moveDestinationTitle(for: draft))
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(draft.destination == nil && draft.allocations.isEmpty ? ActualistTheme.accent : ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(moveDisplayAmountText(draft))
                    .font(ActualistTypography.rowValue(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isNumberPadVisible = true
                    }

                Text(moveCounterpartyAvailableText(draft))
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(moveCounterpartyAvailableForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(moveCounterpartyAvailableBackground, in: Capsule())
            }

            if draft.allocations.isEmpty {
                BudgetMoveMoneyAmountSlider(
                    spec: viewModel.moveMoneySliderSpec(),
                    isDisabled: draft.isSubmitting,
                    onEditingChanged: { isEditing in
                        viewModel.setMoveMoneySliderEditing(isEditing)
                        if isEditing {
                            isNumberPadVisible = false
                        }
                    },
                    onAmountDollarsChanged: { value in
                        viewModel.setMoveMoneySliderAmountDollars(value)
                    }
                )
            } else {
                VStack(spacing: 14) {
                    ForEach(draft.allocations) { allocation in
                        moveAllocationRow(allocation, draft: draft)
                    }
                }
            }

            Divider().overlay(ActualistTheme.separator)

            Button {
                isNumberPadVisible = false
                isDestinationPickerPresented = true
            } label: {
                Label(draft.destination == nil ? "Select Category" : "Select Another", systemImage: "plus.circle.fill")
                    .font(ActualistTypography.control(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(draft.isSubmitting)
        }
        .padding(22)
        .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .modifier(BudgetMoveMoneyDetentHaptic(trigger: viewModel.moveMoneySliderDetentFeedback))
    }

    private func moveDestinationTitle(for draft: BudgetMoveMoneyDraft) -> String {
        if !draft.allocations.isEmpty {
            return draft.allocations.count == 1 ? moveAllocationTitle(draft.allocations[0]) : "Selected Categories"
        }

        guard let destination = draft.destination else {
            return "Select Category"
        }

        return moveDestinationTitle(destination)
    }

    private func moveFocusedCategoryName(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return draft.focusedCategoryName.actualistCategoryNameParts.name
        }

        return PrivacyDisplay.name(for: .category, seed: draft.focusedCategoryID)
    }

    private func moveHeaderAmountText(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.moveMoneyAvailableDisplayAmount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            viewModel.moveMoneyAvailableDisplayAmount,
            seed: "move-header-\(draft.focusedCategoryID)",
            maximumDollars: 900
        )
    }

    private func moveDisplayAmountText(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.moveMoneyDisplayAmount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            viewModel.moveMoneyDisplayAmount,
            seed: "move-display-\(draft.focusedCategoryID)-\(viewModel.moveMoneyDisplayAmount)",
            maximumDollars: 900
        )
    }

    private func moveCounterpartyAvailableText(_ draft: BudgetMoveMoneyDraft) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return viewModel.moveMoneyCounterpartyAvailableDisplayAmount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            viewModel.moveMoneyCounterpartyAvailableDisplayAmount,
            seed: "move-counterparty-\(draft.focusedCategoryID)",
            maximumDollars: 900
        )
    }

    private func moveAllocationTitle(_ allocation: BudgetMoveMoneyAllocation) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return allocation.destination.title
        }

        return moveDestinationTitle(allocation.destination)
    }

    private func moveAllocationAmountText(_ allocation: BudgetMoveMoneyAllocation) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return allocation.amount.actualMoney.formatted()
        }

        return PrivacyDisplay.money(
            allocation.amount,
            seed: "move-allocation-\(allocation.id)-\(allocation.amount)",
            maximumDollars: 900
        )
    }

    private func moveDestinationTitle(_ destination: BudgetMoveMoneyDestination) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return destination.title
        }

        switch destination {
        case .toBudget:
            return "To Budget"
        case .category(let id, _):
            return PrivacyDisplay.name(for: .category, seed: id)
        }
    }

    private func moveAllocationRow(
        _ allocation: BudgetMoveMoneyAllocation,
        draft: BudgetMoveMoneyDraft
    ) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(moveAllocationTitle(allocation))
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Text(moveAllocationAmountText(allocation))
                    .font(ActualistTypography.rowValue(for: density))
                    .foregroundStyle(ActualistTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.setFocusedMoveMoneyAllocation(allocation.id)
                        isNumberPadVisible = true
                    }
            }

            BudgetMoveMoneyAmountSlider(
                spec: viewModel.moveMoneySliderSpec(for: allocation.id),
                isDisabled: draft.isSubmitting,
                onEditingChanged: { isEditing in
                    if isEditing {
                        viewModel.setFocusedMoveMoneyAllocation(allocation.id)
                        isNumberPadVisible = false
                    }
                    viewModel.setMoveMoneySliderEditing(isEditing, allocationID: allocation.id)
                },
                onAmountDollarsChanged: { value in
                    viewModel.setMoveMoneySliderAmountDollars(value, allocationID: allocation.id)
                }
            )
        }
    }

    private var moveCounterpartyAvailableBackground: Color {
        let amount = viewModel.moveMoneyCounterpartyAvailableDisplayAmount
        if amount < 0 {
            return ActualistTheme.danger
        }
        if amount == 0 {
            return ActualistTheme.neutral
        }
        return ActualistTheme.positive
    }

    private var moveCounterpartyAvailableForeground: Color {
        let amount = viewModel.moveMoneyCounterpartyAvailableDisplayAmount
        if amount < 0 {
            return ActualistTheme.dangerForeground
        }
        if amount == 0 {
            return ActualistTheme.neutralForeground
        }
        return ActualistTheme.positiveForeground
    }

    private var moveHeaderAmountForeground: Color {
        let amount = viewModel.moveMoneyAvailableDisplayAmount
        if amount < 0 {
            return ActualistTheme.danger
        }
        if amount == 0 {
            return ActualistTheme.secondaryText
        }
        return ActualistTheme.primaryText
    }
}

private enum BudgetMoveMoneyLayout {
    static let headerTopInset: CGFloat = 56
    static let closeButtonTopInset: CGFloat = 54
    static let closeButtonLeadingInset: CGFloat = 34
    static let headerHorizontalPadding: CGFloat = 34
    static let numberPadReservedHeight: CGFloat = 302
    static let compactSubmitReservedHeight: CGFloat = 78
}

private struct BudgetMoveMoneyNumberPad: View {
    @Environment(\.actualistDensity) private var density

    let canSubmit: Bool
    let isSubmitting: Bool
    let appendDigit: (Int) -> Void
    let deleteDigit: () -> Void
    let clear: () -> Void
    let submit: () -> Void

    @State private var keyPressCount = 0

    var body: some View {
        Grid(horizontalSpacing: 22, verticalSpacing: 14) {
            GridRow {
                digitButton(7)
                digitButton(8)
                digitButton(9)
            }

            GridRow {
                digitButton(4)
                digitButton(5)
                digitButton(6)
            }

            GridRow {
                digitButton(1)
                digitButton(2)
                digitButton(3)
            }

            GridRow {
                Button {
                    clear()
                    keyPressCount += 1
                } label: {
                    Image(systemName: "xmark.rectangle")
                        .font(ActualistTypography.keypadSymbol(for: density))
                        .foregroundStyle(ActualistTheme.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(BudgetKeypadPressStyle())
                .accessibilityLabel("Clear amount")

                digitButton(0)

                Button {
                    submit()
                    keyPressCount += 1
                } label: {
                    Text(isSubmitting ? "saving" : "done")
                        .font(ActualistTypography.control(for: density))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(ActualistTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.45)
                .accessibilityLabel("Move money")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 22)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1.0), trigger: keyPressCount)
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            appendDigit(digit)
            keyPressCount += 1
        } label: {
            Text(String(digit))
                .font(ActualistTypography.keypadDigit(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .contentShape(Rectangle())
        }
        .buttonStyle(BudgetKeypadPressStyle())
        .accessibilityLabel(String(digit))
    }
}

private struct BudgetMoveMoneyDestinationPicker: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Bindable var viewModel: BudgetViewModel

    @State private var searchText = ""
    @State private var isSplitMode = false

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        searchField
                        toBudgetButton
                        destinationGroups
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(viewModel.moveMoneyDraft?.direction == .intoFocusedCategory ? "Move from" : "Move to")
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

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if isSplitMode {
                            viewModel.finalizeMoveMoneyDestinationSelection()
                            dismiss()
                        } else {
                            isSplitMode = true
                        }
                    } label: {
                        Text(isSplitMode ? "Done" : "Split")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .appSwitcherPrivacyAwareDragIndicator()
        .onAppear {
            isSplitMode = viewModel.moveMoneyDraft?.allocations.isEmpty == false
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
    private var toBudgetButton: some View {
        let option = viewModel.toBudgetDestinationOption()
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || option.title.localizedCaseInsensitiveContains(searchText) {
            destinationButton(option)
                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var destinationGroups: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(viewModel.moveMoneyDestinationGroups(matching: searchText)) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(groupName(group))
                        .font(ActualistTypography.rowLabel(for: density).weight(.bold))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .padding(.horizontal, 22)

                    VStack(spacing: 0) {
                        ForEach(group.options) { option in
                            destinationButton(option)

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

    private func destinationButton(_ option: BudgetMoveMoneyDestinationOption) -> some View {
        Button {
            if isSplitMode {
                viewModel.toggleMoveMoneyDestination(option.destination)
            } else {
                viewModel.selectMoveMoneyDestination(option.destination)
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                Text(optionTitle(option))
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer()

                Text(optionValueText(option))
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(destinationValueForeground(option))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(destinationValueBackground(option), in: Capsule())

                if viewModel.moveMoneyDraft?.destination == option.destination
                    || viewModel.isMoveMoneyDestinationSelected(option.destination) {
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

    private func destinationValueBackground(_ option: BudgetMoveMoneyDestinationOption) -> Color {
        switch option.destination {
        case .toBudget:
            ActualistTheme.positive
        case .category:
            if option.amount < 0 {
                ActualistTheme.danger
            } else if option.amount == 0 {
                ActualistTheme.neutral
            } else {
                ActualistTheme.positive
            }
        }
    }

    private func destinationValueForeground(_ option: BudgetMoveMoneyDestinationOption) -> Color {
        switch option.destination {
        case .toBudget:
            ActualistTheme.positiveForeground
        case .category:
            if option.amount < 0 {
                ActualistTheme.dangerForeground
            } else if option.amount == 0 {
                ActualistTheme.neutralForeground
            } else {
                ActualistTheme.positiveForeground
            }
        }
    }

    private func groupName(_ group: BudgetMoveMoneyDestinationGroup) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return group.name
        }

        return PrivacyDisplay.name(for: .categoryGroup, seed: group.id)
    }

    private func optionTitle(_ option: BudgetMoveMoneyDestinationOption) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return option.title
        }

        switch option.destination {
        case .toBudget:
            return "To Budget"
        case .category(let id, _):
            return PrivacyDisplay.name(for: .category, seed: id)
        }
    }

    private func optionValueText(_ option: BudgetMoveMoneyDestinationOption) -> String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return option.valueText
        }

        return PrivacyDisplay.money(
            option.amount,
            seed: "move-option-\(option.id)",
            maximumDollars: 900
        )
    }
}
