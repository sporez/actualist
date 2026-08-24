import Foundation
import Observation

@MainActor
@Observable
final class BudgetMoveMoneyWorkflow {
    private static let maximumUserAmountMinorUnits = 9_000_000_000_000_000

    private(set) var draft: BudgetMoveMoneyDraft?
    private var sliderDetent = BudgetMoveMoneySliderDetent()
    private var coverIntroTarget: Int?
    private var coverIntroGeneration = 0

    var isPresented: Bool {
        draft != nil
    }

    var canSubmit: Bool {
        guard let draft else {
            return false
        }

        if !draft.allocations.isEmpty {
            return draft.validatedTotalAllocatedAmount.map { $0 > 0 } == true
                && !draft.isSubmitting
        }

        return draft.amount > 0 && draft.destination != nil && !draft.isSubmitting
    }

    var isSubmitting: Bool {
        draft?.isSubmitting == true
    }

    var errorMessage: String? {
        guard let draft,
              case .failed(let message) = draft.submissionState else {
            return nil
        }

        return message
    }

    var amountDollars: Double {
        guard let draft else {
            return 0
        }

        if let allocation = focusedAllocation(in: draft) {
            return Double(allocation.amount) / 100
        }

        return Double(draft.amount) / 100
    }

    var displayAmount: Int {
        guard let draft else {
            return 0
        }

        return draft.allocations.isEmpty ? draft.amount : draft.totalAllocatedAmount
    }

    var sliderDetentFeedback: Int {
        sliderDetent.bumpCount
    }

    var hasPendingCoverIntro: Bool {
        coverIntroTarget != nil
    }

    func begin(for category: BudgetMonthCategory) {
        guard draft?.isSubmitting != true else {
            return
        }

        var newDraft = BudgetMoveMoneyDraft(
            focusedCategoryID: category.id,
            focusedCategoryName: category.name,
            focusedAvailable: category.balance
        )
        cancelCoverIntro()
        if category.balance < 0 {
            newDraft.direction = .intoFocusedCategory
            coverIntroTarget = Int(clamping: category.balance.magnitude)
        }

        sliderDetent = BudgetMoveMoneySliderDetent()
        draft = newDraft
    }

    func cancel() {
        guard draft?.isSubmitting != true else {
            return
        }

        cancelCoverIntro()
        sliderDetent = BudgetMoveMoneySliderDetent()
        draft = nil
    }

    func playCoverIntro(
        sleep: (@Sendable (UInt64) async -> Void)? = nil
    ) async {
        guard let target = coverIntroTarget, target > 0 else {
            return
        }

        coverIntroTarget = nil
        let generation = coverIntroGeneration
        let sleep = sleep ?? { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }

        await sleep(BudgetMoveMoneyCoverIntro.startDelayNanoseconds)
        guard generation == coverIntroGeneration, draft != nil else {
            return
        }

        for step in 1...BudgetMoveMoneyCoverIntro.stepCount {
            await sleep(
                BudgetMoveMoneyCoverIntro.animationNanoseconds
                    / UInt64(BudgetMoveMoneyCoverIntro.stepCount)
            )
            guard generation == coverIntroGeneration,
                  var draft = editableDraft else {
                return
            }
            setFocusedAmount(
                BudgetMoveMoneyCoverIntro.amount(
                    progress: Double(step) / Double(BudgetMoveMoneyCoverIntro.stepCount),
                    target: target
                ),
                draft: &draft
            )
            self.draft = draft
        }

        guard generation == coverIntroGeneration else {
            return
        }
        sliderDetent.registerLandingBump()
    }

    private func cancelCoverIntro() {
        coverIntroGeneration += 1
        coverIntroTarget = nil
    }

    func setAmountDollars(_ value: Double) {
        cancelCoverIntro()
        guard var draft = editableDraft else {
            return
        }

        let cents = (max(0, value) * 100).rounded()
        guard cents.isFinite,
              cents <= Double(Self.maximumUserAmountMinorUnits),
              let amount = Int(exactly: cents) else {
            return
        }
        setFocusedAmount(amount, draft: &draft)
        self.draft = draft
    }

    func setSliderEditing(
        _ isEditing: Bool,
        allocationID: String? = nil,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) {
        guard draft != nil else {
            return
        }

        let detent = detentAmount(
            for: allocationID,
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups
        )
        let amount = sliderAmount(for: allocationID)
        if isEditing {
            cancelCoverIntro()
            sliderDetent.beginEditing(
                sliderID: sliderID(for: allocationID),
                amount: amount,
                detentAmount: detent
            )
        } else {
            sliderDetent.endEditing(amount: amount, detentAmount: detent)
        }
    }

    func setSliderAmountDollars(
        _ value: Double,
        allocationID: String? = nil,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) {
        // Ignore the trailing set SwiftUI Slider sends after finger-up. That
        // value is the raw touch location, not the committed detent amount.
        guard editableDraft != nil, sliderDetent.isEditing else {
            return
        }

        guard var draft = editableDraft else {
            return
        }

        if let allocationID {
            guard draft.allocations.contains(where: { $0.id == allocationID }) else {
                return
            }
            draft.focusedAllocationID = allocationID
            self.draft = draft
        }

        let cents = (max(0, value) * 100).rounded()
        guard cents.isFinite,
              cents <= Double(Self.maximumUserAmountMinorUnits),
              let proposed = Int(exactly: cents) else {
            return
        }

        let detent = detentAmount(
            for: allocationID,
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups
        )
        let amount = sliderDetent.apply(proposedAmount: proposed, detentAmount: detent)
        guard var updated = editableDraft else {
            return
        }
        setFocusedAmount(amount, draft: &updated)
        self.draft = updated
    }

    func appendDigit(_ digit: Int) {
        cancelCoverIntro()
        guard var draft = editableDraft,
              (0...9).contains(digit) else {
            return
        }

        let multiplied = focusedAmount(in: draft).multipliedReportingOverflow(by: 10)
        guard !multiplied.overflow else {
            return
        }
        let added = multiplied.partialValue.addingReportingOverflow(digit)
        guard !added.overflow, added.partialValue <= Self.maximumUserAmountMinorUnits else {
            return
        }
        setFocusedAmount(added.partialValue, draft: &draft)
        self.draft = draft
    }

    func deleteDigit() {
        cancelCoverIntro()
        guard var draft = editableDraft else {
            return
        }

        setFocusedAmount(focusedAmount(in: draft) / 10, draft: &draft)
        self.draft = draft
    }

    func clearAmount() {
        cancelCoverIntro()
        guard var draft = editableDraft else {
            return
        }

        setFocusedAmount(0, draft: &draft)
        self.draft = draft
    }

    func selectDestination(_ destination: BudgetMoveMoneyDestination) {
        cancelCoverIntro()
        guard var draft = editableDraft else {
            return
        }

        draft.destination = destination
        draft.allocations = []
        draft.focusedAllocationID = nil
        setAmount(draft.amount, draft: &draft)
        sliderDetent.reset()
        self.draft = draft
    }

    func toggleDestination(_ destination: BudgetMoveMoneyDestination) {
        cancelCoverIntro()
        guard var draft = editableDraft else {
            return
        }

        draft.destination = nil
        if let index = draft.allocations.firstIndex(where: { $0.id == destination.id }) {
            draft.allocations.remove(at: index)
            if draft.focusedAllocationID == destination.id {
                draft.focusedAllocationID = draft.allocations.last?.id
            }
        } else {
            draft.allocations.append(
                BudgetMoveMoneyAllocation(
                    id: destination.id,
                    destination: destination,
                    amount: 0
                )
            )
            draft.focusedAllocationID = destination.id
        }

        sliderDetent.reset()
        self.draft = draft
    }

    func isDestinationSelected(_ destination: BudgetMoveMoneyDestination) -> Bool {
        draft?.allocations.contains { $0.id == destination.id } == true
    }

    func finalizeDestinationSelection() {
        guard var draft = editableDraft else {
            return
        }

        if draft.allocations.count == 1, let allocation = draft.allocations.first {
            draft.destination = allocation.destination
            draft.amount = allocation.amount
            draft.allocations = []
            draft.focusedAllocationID = nil
        }

        self.draft = draft
    }

    func setFocusedAllocation(_ id: String) {
        guard var draft = editableDraft,
              draft.allocations.contains(where: { $0.id == id }) else {
            return
        }

        draft.focusedAllocationID = id
        self.draft = draft
    }

    func toggleDirection() {
        cancelCoverIntro()
        guard var draft = editableDraft else {
            return
        }

        draft.direction = draft.direction.toggled
        setAmount(draft.amount, draft: &draft)
        draft.allocations = draft.allocations.map { allocation in
            var updated = allocation
            updated.amount = max(0, updated.amount)
            return updated
        }
        sliderDetent.reset()
        self.draft = draft
    }

    func sliderSpec(
        for allocationID: String? = nil,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> BudgetMoveMoneySliderSpec {
        BudgetMoveMoneySliderSpec(
            amount: sliderAmount(for: allocationID),
            detentAmount: detentAmount(
                for: allocationID,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            ),
            maximumAmount: maximumAmount(
                for: allocationID,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            )
        )
    }

    func maximumAmount(
        for allocationID: String? = nil,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        guard draft != nil else {
            return 0
        }

        return BudgetMoveMoneySliderMetrics.maximumAmount(
            baselineAmount: scaleBaseline(
                for: allocationID,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            ),
            currentAmount: sliderAmount(for: allocationID)
        )
    }

    func detentAmount(
        for allocationID: String? = nil,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        guard let draft else {
            return 0
        }

        return max(
            0,
            payingAvailable(
                for: allocationID,
                draft: draft,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            )
        )
    }

    func availableDisplayAmount() -> Int {
        guard let draft else {
            return 0
        }

        switch draft.direction {
        case .outOfFocusedCategory:
            return subtractClamped(draft.focusedAvailable, displayAmount)
        case .intoFocusedCategory:
            return addClamped(draft.focusedAvailable, displayAmount)
        }
    }

    func counterpartyAvailableDisplayAmount(
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        guard let draft,
              let destination = draft.destination else {
            return 0
        }

        let destinationAvailable = availableAmount(
            for: destination,
            budgetMonth: budgetMonth,
            visibleGroups: visibleGroups
        )
        switch draft.direction {
        case .outOfFocusedCategory:
            return addClamped(destinationAvailable, draft.amount)
        case .intoFocusedCategory:
            return subtractClamped(destinationAvailable, draft.amount)
        }
    }

    func destinationGroups(
        matching searchText: String,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> [BudgetMoveMoneyDestinationGroup] {
        guard let focusedID = draft?.focusedCategoryID else {
            return []
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return visibleGroups.compactMap { group in
            let options = group.visibleCategories.compactMap { category -> BudgetMoveMoneyDestinationOption? in
                guard category.id != focusedID else {
                    return nil
                }

                let title = category.name.actualistCategoryNameParts.name
                if !trimmedSearch.isEmpty,
                   !title.localizedCaseInsensitiveContains(trimmedSearch),
                   !group.name.localizedCaseInsensitiveContains(trimmedSearch) {
                    return nil
                }

                return BudgetMoveMoneyDestinationOption(
                    id: category.id,
                    title: title,
                    amount: category.balance,
                    valueText: category.balance.actualMoney.formatted(),
                    destination: .category(id: category.id, name: category.name)
                )
            }

            guard !options.isEmpty else {
                return nil
            }

            return BudgetMoveMoneyDestinationGroup(
                id: group.id,
                name: group.name,
                options: options
            )
        }
    }

    func submit(
        selectedMonth: String,
        budgetID: String,
        repository: any BudgetRepositoryProtocol
    ) async -> LoadedBudgetMonth? {
        guard var draft,
              !draft.isSubmitting else {
            return nil
        }

        let commands = commands(for: draft)
        guard !commands.isEmpty else {
            return nil
        }

        draft.submissionState = .submitting
        self.draft = draft

        do {
            let loadedMonth = try await repository.moveMoneyAndRefresh(
                commands: commands,
                budgetID: budgetID,
                month: selectedMonth
            ) { [weak self] in
                await MainActor.run {
                    guard var currentDraft = self?.draft,
                          currentDraft.focusedCategoryID == draft.focusedCategoryID else {
                        return
                    }

                    currentDraft.submissionState = .refetching
                    self?.draft = currentDraft
                }
            }
            self.draft = nil
            return loadedMonth
        } catch {
            draft.submissionState = .failed(error.localizedDescription)
            self.draft = draft
            return nil
        }
    }

    private var editableDraft: BudgetMoveMoneyDraft? {
        guard let draft,
              !draft.isSubmitting else {
            return nil
        }

        return draft
    }

    private func setAmount(_ amount: Int, draft: inout BudgetMoveMoneyDraft) {
        draft.amount = max(0, amount)
    }

    private func setFocusedAmount(_ amount: Int, draft: inout BudgetMoveMoneyDraft) {
        let amount = max(0, amount)
        guard !draft.allocations.isEmpty else {
            setAmount(amount, draft: &draft)
            return
        }

        let focusedID = draft.focusedAllocationID ?? draft.allocations.last?.id
        guard let focusedID,
              let index = draft.allocations.firstIndex(where: { $0.id == focusedID }) else {
            return
        }

        draft.focusedAllocationID = focusedID
        draft.allocations[index].amount = amount
    }

    private func focusedAmount(in draft: BudgetMoveMoneyDraft) -> Int {
        focusedAllocation(in: draft)?.amount ?? draft.amount
    }

    private func focusedAllocation(in draft: BudgetMoveMoneyDraft) -> BudgetMoveMoneyAllocation? {
        let focusedID = draft.focusedAllocationID ?? draft.allocations.last?.id
        guard let focusedID else {
            return nil
        }

        return draft.allocations.first { $0.id == focusedID }
    }

    private func sliderID(for allocationID: String?) -> String {
        allocationID ?? draft?.destination?.id ?? "single"
    }

    private func sliderAmount(for allocationID: String?) -> Int {
        guard let draft else {
            return 0
        }

        if let allocationID,
           let allocation = draft.allocations.first(where: { $0.id == allocationID }) {
            return allocation.amount
        }

        return focusedAmount(in: draft)
    }

    private func scaleBaseline(
        for allocationID: String?,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        guard let draft else {
            return 0
        }

        switch draft.direction {
        case .outOfFocusedCategory:
            return max(
                0,
                payingAvailable(
                    for: allocationID,
                    draft: draft,
                    budgetMonth: budgetMonth,
                    visibleGroups: visibleGroups
                )
            )
        case .intoFocusedCategory:
            let paying = payingAvailable(
                for: allocationID,
                draft: draft,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            )
            if paying == 0,
               draft.destination == nil,
               draft.allocations.isEmpty {
                return Int(clamping: min(0, draft.focusedAvailable).magnitude)
            }
            return max(0, paying)
        }
    }

    private func payingAvailable(
        for allocationID: String?,
        draft: BudgetMoveMoneyDraft,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        switch draft.direction {
        case .outOfFocusedCategory:
            let others: Int
            if let allocationID, !draft.allocations.isEmpty {
                others = draft.allocations
                    .filter { $0.id != allocationID }
                    .reduce(0) { addClamped($0, $1.amount) }
            } else {
                others = 0
            }
            return subtractClamped(draft.focusedAvailable, others)
        case .intoFocusedCategory:
            let destination: BudgetMoveMoneyDestination?
            if let allocationID {
                destination = draft.allocations.first(where: { $0.id == allocationID })?.destination
            } else {
                destination = draft.destination
            }
            guard let destination else {
                return 0
            }
            return availableAmount(
                for: destination,
                budgetMonth: budgetMonth,
                visibleGroups: visibleGroups
            )
        }
    }

    private func commands(for draft: BudgetMoveMoneyDraft) -> [BudgetMoveMoneyCommand] {
        if !draft.allocations.isEmpty {
            return draft.allocations
                .filter { $0.amount > 0 }
                .map { allocation in
                    command(
                        for: draft,
                        destination: allocation.destination,
                        amount: allocation.amount
                    )
                }
        }

        guard let destination = draft.destination, draft.amount > 0 else {
            return []
        }

        return [command(for: draft, destination: destination, amount: draft.amount)]
    }

    private func command(
        for draft: BudgetMoveMoneyDraft,
        destination: BudgetMoveMoneyDestination,
        amount: Int
    ) -> BudgetMoveMoneyCommand {
        switch draft.direction {
        case .outOfFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: draft.focusedCategoryID,
                toCategoryID: destination.categoryID,
                amount: amount
            )
        case .intoFocusedCategory:
            BudgetMoveMoneyCommand(
                fromCategoryID: destination.categoryID,
                toCategoryID: draft.focusedCategoryID,
                amount: amount
            )
        }
    }

    private func availableAmount(
        for destination: BudgetMoveMoneyDestination?,
        budgetMonth: BudgetMonth?,
        visibleGroups: [BudgetMonthCategoryGroup]
    ) -> Int {
        switch destination {
        case .toBudget:
            budgetMonth?.toBudget ?? 0
        case .category(let id, _):
            visibleGroups
                .flatMap(\.visibleCategories)
                .first { $0.id == id }?
                .balance ?? 0
        case nil:
            0
        }
    }

    private func addClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard result.overflow else { return result.partialValue }
        return rhs >= 0 ? Int.max : Int.min
    }

    private func subtractClamped(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.subtractingReportingOverflow(rhs)
        guard result.overflow else { return result.partialValue }
        return rhs >= 0 ? Int.min : Int.max
    }
}
