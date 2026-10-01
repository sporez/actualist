import SwiftUI

struct TransactionFilterOptionsView: View {
    @Environment(\.actualistDensity) private var density
    @Bindable var workflow: TransactionFilterWorkflow
    let field: TransactionFilterField

    var body: some View {
        let options = workflow.visibleOptions(in: field)
        ReviewSheetContent {
            TextField("Search \(field.title)", text: $workflow.optionSearchText)
                .font(ActualistTypography.body(for: density))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("transaction-filter-options-search")

            if field == .payee || field == .category {
                nullOption
            }

            if options.isEmpty {
                Text(workflow.optionSearchText.isEmpty ? "No options available" : "No matching options")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .actualistReviewCard(padding: 12)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(options) { option in
                        optionButton(option)
                            .actualistReviewCard(padding: 12)
                    }
                }
            }
        }
        .navigationTitle(field.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { workflow.beginOptionSelection() }
    }

    private var nullOption: some View {
        let title = field == .category ? "No category" : "No payee"
        return Button {
            workflow.setNullSelection(field, isSelected: !workflow.isNullSelected(in: field))
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(ActualistTheme.primaryText)
                Spacer()
                if workflow.isNullSelected(in: field) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transaction-filter-null-option-\(field.rawValue)")
        .accessibilityAddTraits(workflow.isNullSelected(in: field) ? .isSelected : [])
        .actualistReviewCard(padding: 12)
    }

    private func optionButton(_ option: TransactionFilterOption) -> some View {
        Button {
            workflow.toggleSelection(option.id, in: field)
        } label: {
            HStack(spacing: 12) {
                Text(option.title)
                    .font(.body)
                    .foregroundStyle(option.isUnavailable
                        ? ActualistTheme.secondaryText : ActualistTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if workflow.isSelected(option.id, in: field) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ActualistTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transaction-filter-option-\(field.rawValue)-\(option.id)")
        .accessibilityAddTraits(workflow.isSelected(option.id, in: field) ? .isSelected : [])
    }
}
