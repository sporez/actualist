import SwiftUI

/// Presentation only: all amounts, statuses and explanatory copy are prepared by the preview display.
struct BudgetTemplateReviewContent: View {
    let display: BudgetTemplateApplyPreviewDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 7) {
                summaryRow("Funding required", display.fundingRequiredText, symbol: "dollarsign.circle")
                summaryRow("Will assign", display.assignedText, symbol: "plus")
                if let releasedText = display.releasedText {
                    summaryRow(display.releasedTitle, releasedText, symbol: "arrow.uturn.backward")
                }
                summaryRow("Still needed", display.stillNeededText, symbol: "minus",
                           color: display.hasOutstandingFunding ? ActualistTheme.warning : nil)
                summaryRow(display.leftoverTitle,
                           "\(display.leftoverBeforeText) → \(display.leftoverAfterText)",
                           symbol: "arrow.right")
                summaryRow("Categories", display.changeCountText, symbol: "square.grid.2x2")
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ActualistTheme.separator, lineWidth: 1))
            .accessibilityElement(children: .contain)

            if let warningText = display.warningText {
                message(warningText, color: ActualistTheme.danger, symbol: "exclamationmark.circle")
            }
            if display.hasNonMoneyUpdates {
                Text("Goal targets will also be updated.")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            if let noOpExplanation = display.noOpExplanation {
                if display.hasNoFundsWarning {
                    message(noOpExplanation, color: ActualistTheme.warning, symbol: "info.circle")
                } else {
                    Text(noOpExplanation)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }

            if !display.categories.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text("Categories")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Spacer(minLength: 8)
                    Text(display.changeCountText)
                        .font(.subheadline)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }

                LazyVStack(spacing: 10) {
                    ForEach(display.categories) { category in
                        BudgetTemplateReviewCategoryCard(category: category)
                    }
                }
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String, symbol: String, color: Color? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: 24, height: 24)
                .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(ActualistTheme.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(color ?? ActualistTheme.primaryText)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
    }

    private func message(_ text: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(color.opacity(0.30), lineWidth: 1))
    }
}

private struct BudgetTemplateReviewCategoryCard: View {
    let category: BudgetTemplateApplyPreviewDisplay.Category

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 4)
                    assignment
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    assignment
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    metric(category.metricTitle,
                           "\(category.metricBeforeText) → \(category.metricAfterText)")
                    if let shortfallText = category.shortfallText {
                        metricDivider
                        metric("Shortfall", shortfallText, color: ActualistTheme.warning)
                    }
                    if let targetAmountText = category.targetAmountText {
                        metricDivider
                        metric("Template target", targetAmountText)
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 10) {
                    metric(category.metricTitle,
                           "\(category.metricBeforeText) → \(category.metricAfterText)")
                    if let shortfallText = category.shortfallText {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 12) {
                                metric("Shortfall", shortfallText, color: ActualistTheme.warning)
                                if let targetAmountText = category.targetAmountText {
                                    metricDivider
                                    metric("Template target", targetAmountText)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: 8) {
                                metric("Shortfall", shortfallText, color: ActualistTheme.warning)
                                if let targetAmountText = category.targetAmountText {
                                    metric("Template target", targetAmountText)
                                }
                            }
                        }
                    }
                }
            }

            if let targetDetailText = category.targetDetailText {
                detail(targetDetailText)
            }
            if !category.contributions.isEmpty {
                VStack(spacing: 6) {
                    ForEach(category.contributions) { contribution in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(contribution.title)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(contribution.amountText)
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
                .padding(.top, 8)
                .overlay(alignment: .top) { ActualistTheme.separator.frame(height: 1) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(ActualistTheme.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("template-preview-category-\(category.id)")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(category.statusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(category.shortfallText == nil ? ActualistTheme.positive : ActualistTheme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((category.shortfallText == nil ? ActualistTheme.positive : ActualistTheme.warning)
                        .opacity(0.13), in: Capsule())
                    .fixedSize()
            }
            if let priorityText = category.priorityText {
                Text(priorityText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var assignment: some View {
        Text("\(category.currentText) → \(category.proposedText)")
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(ActualistTheme.primaryText)
            .fixedSize()
            .accessibilityLabel("Assignment \(category.currentText) to \(category.proposedText)")
    }

    private var metricDivider: some View {
        ActualistTheme.separator.frame(width: 1, height: 34)
    }

    private func metric(_ title: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(value)
                .foregroundStyle(color ?? ActualistTheme.primaryText)
                .monospacedDigit()
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(ActualistTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .overlay(alignment: .top) { ActualistTheme.separator.frame(height: 1) }
    }
}
