import Testing
@testable import Actualist

@MainActor
struct BudgetCategoryDeletionWorkflowTests {
    @Test func categoryPreparationIncludesHiddenSameKindDestinationsAndExcludesVictim() async {
        let victim = category("victim", "Victim", false, "expense", hidden: false)
        let hidden = category("hidden", "Hidden", false, "expense", hidden: true)
        let income = category("income", "Income", true, "income", hidden: false)
        let groups = [
            group("expense", "Expenses", false, false, [victim, hidden]),
            group("income", "Income", true, false, [income])
        ]
        let repository = CategoryLifecycleRecordingRepository(transferRequiredIDs: ["victim"])
        let workflow = BudgetCategoryDeletionWorkflow()

        await workflow.prepareCategory(
            victim, groups: groups, isTrackingBudget: false,
            budgetID: "budget", repository: repository
        )

        #expect(workflow.state == .ready(requiresTransfer: true))
        #expect(workflow.destinations.map(\.id) == ["hidden"])
        #expect(workflow.destinations.first?.hidden == true)
        workflow.selectDestination("income")
        #expect(workflow.selectedDestinationID == nil)
        workflow.selectDestination("hidden")
        #expect(workflow.selectedDestinationID == "hidden")
    }

    @Test func groupPreparationChecksUntilTransferIsRequiredAndSubmitsOneDestination() async {
        let one = category("one", "One", false, "victim", hidden: false)
        let two = category("two", "Two", false, "victim", hidden: false)
        let destination = category("destination", "Destination", false, "other", hidden: false)
        let victim = group("victim", "Victim", false, false, [one, two])
        let groups = [victim, group("other", "Other", false, false, [destination])]
        let repository = CategoryLifecycleRecordingRepository(transferRequiredIDs: ["two"])
        let workflow = BudgetCategoryDeletionWorkflow()

        await workflow.prepareGroup(
            victim, groups: groups, isTrackingBudget: false,
            budgetID: "budget", repository: repository
        )
        #expect(await repository.transferChecks == ["one", "two"])
        #expect(workflow.state == .ready(requiresTransfer: true))
        #expect(workflow.destinations.map(\.id) == ["destination"])
        #expect(await workflow.delete(
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        ) == nil)
        #expect(workflow.errorMessage != nil)

        workflow.selectDestination("destination")
        #expect(await workflow.delete(
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        ) != nil)
        #expect(await repository.deletedGroups.map(\.id) == ["victim"])
        #expect(await repository.deletedGroups.map(\.transferID) == ["destination"])
        #expect(workflow.state == .idle)
    }

    @Test func lifecycleControllerDeletesImmediatelyWhenTransferIsNotRequired() async {
        let victim = category("victim", "Victim", false, "expense", hidden: false)
        let destination = category("destination", "Destination", false, "expense", hidden: false)
        let groups = [group("expense", "Expenses", false, false, [victim, destination])]
        let repository = CategoryLifecycleRecordingRepository()
        let controller = BudgetCategoryLifecycleController()

        let result = await controller.requestDeleteCategory(
            victim,
            groups: groups,
            isTrackingBudget: false,
            selectedMonth: "2026-07",
            budgetID: "budget",
            repository: repository
        )

        #expect(result == .deleted)
        #expect(await repository.deletedCategories.map(\.id) == ["victim"])
        #expect(await repository.deletedCategories.first?.transferID == nil)
        #expect(controller.deletion.state == .idle)

        let emptyGroup = group("empty", "Empty", false, false, [])
        let groupResult = await controller.requestDeleteGroup(
            emptyGroup,
            groups: [emptyGroup, groups[0]],
            isTrackingBudget: false,
            selectedMonth: "2026-07",
            budgetID: "budget",
            repository: repository
        )
        #expect(groupResult == .deleted)
        #expect(await repository.deletedGroups.map(\.id) == ["empty"])
        #expect(await repository.deletedGroups.first?.transferID == nil)
    }

    @Test func lifecycleControllerRequiresReviewAndDestinationBeforeDeleting() async {
        let victim = category("victim", "Victim", false, "expense", hidden: false)
        let destination = category("destination", "Destination", false, "expense", hidden: true)
        let groups = [group("expense", "Expenses", false, false, [victim, destination])]
        let repository = CategoryLifecycleRecordingRepository(transferRequiredIDs: ["victim"])
        let controller = BudgetCategoryLifecycleController()

        let result = await controller.requestDeleteCategory(
            victim,
            groups: groups,
            isTrackingBudget: false,
            selectedMonth: "2026-07",
            budgetID: "budget",
            repository: repository
        )

        #expect(result == .review(.deleteCategory(victim)))
        #expect(await repository.deletedCategories.isEmpty)
        #expect(await !controller.confirmDeletion(
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        ))
        controller.deletion.selectDestination("destination")
        #expect(await controller.confirmDeletion(
            selectedMonth: "2026-07", budgetID: "budget", repository: repository
        ))
        #expect(await repository.deletedCategories.first?.transferID == "destination")
    }

    @Test func reviewCopyUsesActualIncomeWording() {
        let target = BudgetCategoryDeletionWorkflow.Target.category(
            id: "income", name: "Paycheck", isIncome: true
        )

        #expect(target.reviewMessage.contains("positive leftover balance currently"))
        #expect(target.reviewMessage.contains("must select another category"))
    }

    @Test func envelopeIncomeIntentNeverReachesRepository() async {
        let income = category("income", "Income", true, "income", hidden: false)
        let groups = [group("income", "Income", true, false, [income])]
        let repository = CategoryLifecycleRecordingRepository(transferRequiredIDs: ["income"])
        let workflow = BudgetCategoryDeletionWorkflow()

        await workflow.prepareCategory(
            income, groups: groups, isTrackingBudget: false,
            budgetID: "budget", repository: repository
        )

        #expect(workflow.state == .idle)
        #expect(workflow.errorMessage == "Income categories cannot be managed in an envelope budget.")
        #expect(await repository.transferChecks.isEmpty)
    }

    @Test func cancellationDropsStalePreparationAndSubmissionAndIgnoresConcurrentSubmit() async {
        let victim = category("victim", "Victim", false, "expense", hidden: false)
        let destination = category("destination", "Destination", false, "expense", hidden: false)
        let groups = [group("expense", "Expenses", false, false, [victim, destination])]

        let checkingRepository = CategoryLifecycleRecordingRepository(
            suspendTransferChecks: true, transferRequiredIDs: ["victim"]
        )
        let checkingWorkflow = BudgetCategoryDeletionWorkflow()
        let prepare = Task {
            await checkingWorkflow.prepareCategory(
                victim, groups: groups, isTrackingBudget: false,
                budgetID: "budget", repository: checkingRepository
            )
        }
        await checkingRepository.waitUntilTransferCheckStarted()
        checkingWorkflow.cancel()
        await checkingRepository.finishTransferCheck()
        await prepare.value
        #expect(checkingWorkflow.state == .idle)
        #expect(checkingWorkflow.target == nil)

        let deletingRepository = CategoryLifecycleRecordingRepository(
            suspendDeletes: true, transferRequiredIDs: ["victim"]
        )
        let deletingWorkflow = BudgetCategoryDeletionWorkflow()
        await deletingWorkflow.prepareCategory(
            victim, groups: groups, isTrackingBudget: false,
            budgetID: "budget", repository: deletingRepository
        )
        deletingWorkflow.selectDestination("destination")
        let first = Task {
            await deletingWorkflow.delete(
                selectedMonth: "2026-07", budgetID: "budget", repository: deletingRepository
            )
        }
        await deletingRepository.waitUntilDeleteStarted()
        let second = await deletingWorkflow.delete(
            selectedMonth: "2026-07", budgetID: "budget", repository: deletingRepository
        )
        #expect(second == nil)
        deletingWorkflow.cancel()
        await deletingRepository.finishDelete()
        #expect(await first.value == nil)
        #expect(deletingWorkflow.state == .idle)
        #expect(await deletingRepository.deletedCategories.count == 1)
    }
}

private func group(
    _ id: String,
    _ name: String,
    _ isIncome: Bool,
    _ hidden: Bool,
    _ categories: [BudgetMonthCategory]
) -> BudgetMonthCategoryGroup {
    BudgetMonthCategoryGroup(
        id: id, name: name, isIncome: isIncome, hidden: hidden,
        budgeted: 0, spent: 0, balance: 0, categories: categories
    )
}

private func category(
    _ id: String,
    _ name: String,
    _ isIncome: Bool,
    _ groupID: String,
    hidden: Bool
) -> BudgetMonthCategory {
    BudgetMonthCategory(
        id: id, name: name, isIncome: isIncome, hidden: hidden, groupID: groupID,
        budgeted: 0, spent: 0, balance: 0, carryover: false
    )
}
