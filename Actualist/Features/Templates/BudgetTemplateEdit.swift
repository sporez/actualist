import Foundation

enum BudgetTemplateEdit {
    case add(BudgetTemplateKind)
    case remove(id: UUID)
    case setKind(BudgetTemplateKind, id: UUID)
    case setInput(String, field: BudgetTemplateEditorInputField, id: UUID)
    case setNoteText(String, id: UUID)
    case clearNote(id: UUID)
    case setDateTargetRepeats(Bool, id: UUID)
    case setDateTargetAnnual(Bool, id: UUID)
    case setDateTargetEarlySpending(Bool, id: UUID)
    case setFixedCadence(BudgetTemplateCadence, id: UUID)
    case setFixedStartingDate(Date, id: UUID)
    case setLimitPeriod(BudgetTemplateLimitPeriod, id: UUID)
    case setLimitHold(Bool, id: UUID)
    case setLimitWeekday(Int, id: UUID)
    case setPercentageSource(String, id: UUID)
    case setPercentagePrevious(Bool, id: UUID)
    case setSchedule(String?, id: UUID)
    case setScheduleFull(Bool, id: UUID)
    case setAdjustmentMode(BudgetTemplateAdjustmentMode, id: UUID)
    case setAdjustmentDirection(BudgetTemplateAdjustmentDirection, id: UUID)
}
