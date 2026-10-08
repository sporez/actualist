import SwiftUI

struct BudgetTemplateEditorMonthField: View {
    @Environment(\.locale) private var locale
    @State private var isPresented = false
    let title: String
    let field: BudgetTemplateEditorInputField
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel
    let focus: FocusState<BudgetTemplateEditorFocus?>.Binding

    var body: some View {
        Button {
            focus.wrappedValue = nil
            isPresented = true
        } label: {
            LabeledContent(title, value: viewModel.monthTitle(for: field, id: itemID, locale: locale))
        }
        .disabled(!viewModel.isEditable)
        .accessibilityIdentifier("template-\(field)-month")
        .sheet(isPresented: $isPresented) {
            BudgetTemplateEditorMonthSheet(title: title, field: field, itemID: itemID, viewModel: viewModel)
        }
    }
}

private struct BudgetTemplateEditorMonthSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let title: String
    let field: BudgetTemplateEditorInputField
    let itemID: UUID
    let viewModel: BudgetTemplateEditorViewModel

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: title)
            VStack(spacing: 0) {
                Picker("Month", selection: Binding(
                    get: { viewModel.monthSelection(for: field, id: itemID).month },
                    set: { viewModel.setMonthNumber($0, field: field, id: itemID) }
                )) {
                    ForEach(Array(BudgetTemplateEditorMonth.monthNames(locale: locale).enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index + 1)
                    }
                }
                .pickerStyle(.wheel)
                .accessibilityIdentifier("template-month-wheel")
                Picker("Year", selection: Binding(
                    get: { viewModel.monthSelection(for: field, id: itemID).year },
                    set: { viewModel.setMonthYear($0, field: field, id: itemID) }
                )) {
                    ForEach(viewModel.monthYears(for: field, id: itemID), id: \.self) { year in
                        Text(year, format: .number.grouping(.never)).tag(year)
                    }
                }
                .pickerStyle(.wheel)
                .accessibilityIdentifier("template-year-wheel")
            }
            .actualistReviewCard(padding: 6)
        }
        .reviewSheetBottomBar {
            ReviewSheetPrimaryButton {
                viewModel.completeMonthSelection(field: field, id: itemID)
                dismiss()
            } label: {
                Text("Done")
            }
        }
        .reviewSheetPresentation(detents: [.fraction(0.8), .large], appState: appState)
    }
}
