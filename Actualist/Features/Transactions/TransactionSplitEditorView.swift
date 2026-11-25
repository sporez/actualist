import SwiftUI

struct TransactionSplitEditorView: View {
    @Environment(\.actualistDensity) private var density
    @Bindable var viewModel: TransactionEditorViewModel
    var focusedField: FocusState<TransactionEditorField?>.Binding
    var onPickPayee: (String) -> Void
    var onPickCategory: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Splits")
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)

                Spacer()

                Text(viewModel.splitRemainingStatusText)
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(
                        viewModel.splitRemainingCents == 0
                            ? ActualistTheme.secondaryText
                            : ActualistTheme.warning
                    )
            }

            ForEach(viewModel.splitRows) { row in
                childCard(row)
            }

            HStack(spacing: 10) {
                Button {
                    focusedField.wrappedValue = nil
                    viewModel.addSplit()
                } label: {
                    Label("Add Split", systemImage: "plus.circle.fill")
                        .font(ActualistTypography.control(for: density))
                        .foregroundStyle(ActualistTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .background(ActualistTheme.control, in: Capsule())

                if viewModel.splitRemainingCents != 0 {
                    Button {
                        focusedField.wrappedValue = nil
                        viewModel.autoDistributeSplitMismatch()
                    } label: {
                        Text("Fill Remaining")
                            .font(ActualistTypography.control(for: density))
                            .foregroundStyle(ActualistTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(ActualistTheme.control, in: Capsule())
                }
            }
        }
        .padding(18)
        .background(ActualistTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func childCard(_ row: TransactionSplitEditorRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    onPickPayee(row.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Payee")
                            .font(ActualistTypography.body(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)
                        Text(row.displayPayeeName)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(
                                row.hasNoPayee
                                    ? ActualistTheme.secondaryText
                                    : ActualistTheme.primaryText
                            )
                            .italic(row.hasNoPayee)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Button {
                        viewModel.toggleSplitSign(rowID: row.id)
                    } label: {
                        Text(row.amountMinorUnits < 0 ? "−" : "+")
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(
                                row.amountMinorUnits < 0
                                    ? ActualistTheme.danger
                                    : ActualistTheme.positive
                            )
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.amountMinorUnits < 0 ? "Expense" : "Inflow")

                    splitAmountField(row)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(ActualistTheme.control, in: Capsule())
                .overlay {
                    if focusedField.wrappedValue == .splitAmount(row.id) {
                        Capsule().strokeBorder(ActualistTheme.accent, lineWidth: 1.5)
                    }
                }
            }

            Button {
                if !row.isTransfer {
                    onPickCategory(row.id)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Category")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                    Text(row.displayCategoryName)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .italic(row.isTransfer || row.categoryID == nil)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(row.isTransfer)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(ActualistTypography.body(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                    TextField("Optional", text: notesBinding(for: row.id), axis: .vertical)
                        .focused(focusedField, equals: .splitNotes(row.id))
                        .lineLimit(1...3)
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.primaryText)
                }

                if viewModel.canRemoveSplitRow {
                    Button {
                        focusedField.wrappedValue = nil
                        viewModel.removeSplit(rowID: row.id)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(ActualistTheme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete split")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: ActualistTheme.Radius.panel, style: .continuous))
    }

    /// The field holds only the typed digits and the formatted amount is drawn
    /// over it, as in the main amount field. A focused SwiftUI field does not
    /// reliably take text rewritten by its binding, so a field bound to the
    /// formatted amount could keep "0.0" after a clear and append to it.
    private func splitAmountField(_ row: TransactionSplitEditorRow) -> some View {
        let formatted = viewModel.formattedSplitAmount(rowID: row.id)
        return ZStack(alignment: .trailing) {
            Text(formatted.isEmpty ? "0.00" : formatted)
                .font(ActualistTypography.rowValue(for: density))
                .foregroundStyle(formatted.isEmpty ? ActualistTheme.secondaryText : ActualistTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            TextField("", text: splitAmountDigitsBinding(for: row.id))
                .focused(focusedField, equals: .splitAmount(row.id))
                .keyboardType(.numberPad)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityLabel("Split Amount")
                .accessibilityValue(formatted)
                .accessibilityIdentifier("transaction-split-amount-\(row.id)")
        }
        .frame(width: 84, alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture {
            focusedField.wrappedValue = .splitAmount(row.id)
        }
    }

    private func splitAmountDigitsBinding(for rowID: String) -> Binding<String> {
        Binding {
            viewModel.splitAmountDigits(rowID: rowID)
        } set: { value in
            viewModel.setSplitAmount(rowID: rowID, value: value)
        }
    }

    private func notesBinding(for rowID: String) -> Binding<String> {
        Binding {
            viewModel.splitNotes(rowID: rowID)
        } set: { value in
            viewModel.setSplitNotes(rowID: rowID, notes: value)
        }
    }
}
