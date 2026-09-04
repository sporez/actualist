import Foundation

/// Owns one normalized draft list and its unfinished text. Transitions never erase unrelated input.
struct BudgetTemplateDraftEditor {
    struct Item: Identifiable, Equatable, Sendable {
        var id: UUID
        var draft: BudgetTemplateDraft
    }

    let now: Date
    var currency: BudgetCurrency = .none
    private(set) var items: [Item] = []
    private(set) var schedules: [BudgetTemplateScheduleOption] = []
    private(set) var incomeCategories: [BudgetTemplateIncomeOption] = []
    private var fieldInputs: [BudgetTemplateEditorInputKey: BudgetTemplateEditorInputState] = [:]
    private var noteInputs: [UUID: String] = [:]

    init(now: Date) { self.now = now }

    init(snapshot: BudgetTemplateEditorSnapshot, now: Date) {
        self.now = now
        currency = snapshot.currency
        schedules = snapshot.schedules
        incomeCategories = snapshot.incomeCategories
        items = snapshot.drafts.map { Item(id: UUID(), draft: $0) }
        noteInputs = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.draft.description ?? "") })
    }

    var hasValidInputs: Bool { fieldInputs.values.allSatisfy(\.isValid) }
    var addableKinds: [BudgetTemplateKind] {
        let present = Set(items.map(\.draft.kind))
        return BudgetTemplateKind.allCases.filter { kind in
            kind.isAvailableForAuthoring
                && (!kind.isSingleton || !present.contains(kind))
        }
    }

    var hasBalanceLimit: Bool {
        items.contains { if case .balanceLimit = $0.draft { true } else { false } }
    }

    func typeChangeKinds(for id: UUID) -> [BudgetTemplateKind] {
        let otherKinds = Set(items.filter { $0.id != id }.map(\.draft.kind))
        return BudgetTemplateKind.allCases.filter { kind in
            kind.isAvailableForAuthoring
                && (!kind.isSingleton || !otherKinds.contains(kind))
        }
    }

    func scheduleSelection(for id: UUID) -> String? {
        guard case .schedule(let value) = items.first(where: { $0.id == id })?.draft else { return nil }
        if let scheduleID = value.scheduleId { return scheduleID }
        if let option = schedules.first(where: { $0.name == value.name }) { return option.id }
        return value.name.isEmpty ? nil : "unavailable-name:\(value.name)"
    }

    func scheduleOptions(for id: UUID) -> [BudgetTemplateScheduleOption] {
        guard case .schedule(let value) = items.first(where: { $0.id == id })?.draft,
              let selection = scheduleSelection(for: id),
              !schedules.contains(where: { $0.id == selection }) else { return schedules }
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return [.init(id: selection, name: name.isEmpty ? "Unavailable schedule" : name, isAvailable: false)] + schedules
    }

    func percentageSourceOptions(for id: UUID) -> [BudgetTemplatePercentageSourceOption] {
        guard case .percentage(let value) = items.first(where: { $0.id == id })?.draft else {
            return []
        }

        var options = [
            BudgetTemplatePercentageSourceOption(
                id: BudgetTemplatePercentageSource.allIncomeID,
                name: BudgetTemplatePercentageSource.allIncomeName
            )
        ]
        if !value.previous {
            options.append(
                BudgetTemplatePercentageSourceOption(
                    id: BudgetTemplatePercentageSource.availableFundsID,
                    name: BudgetTemplatePercentageSource.availableFundsName
                )
            )
        }
        options.append(contentsOf: incomeCategories.filter(\.isAvailable).map {
            BudgetTemplatePercentageSourceOption(id: $0.id, name: $0.name)
        })

        let source = value.sourceCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              !options.contains(where: { $0.id == source }) else {
            return options
        }
        if let income = incomeCategories.first(where: {
            $0.id == source ||
            $0.name.localizedLowercase == source.localizedLowercase
        }) {
            if options.contains(where: { $0.id == income.id }) {
                return options
            }
            let unavailable = BudgetTemplatePercentageSourceOption(
                id: income.id,
                name: "\(income.name) (unavailable)",
                isAvailable: false
            )
            return [unavailable] + options
        }
        let unavailable = BudgetTemplatePercentageSourceOption(
            id: source,
            name: "\(source) (unavailable)",
            isAvailable: false
        )
        return [unavailable] + options
    }

    func percentageSourceSelection(for id: UUID) -> String {
        guard case .percentage(let value) = items.first(where: { $0.id == id })?.draft else {
            return ""
        }
        let source = value.sourceCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        if percentageSourceOptions(for: id).contains(where: { $0.id == source }) {
            return source
        }
        return incomeCategories.first {
            $0.name.localizedLowercase == source.localizedLowercase
        }?.id ?? source
    }

    mutating func add(_ kind: BudgetTemplateKind) {
        guard addableKinds.contains(kind) else {
            return
        }
        let item = Item(id: UUID(), draft: kind.makeDraft(now: now))
        items.append(item)
        noteInputs[item.id] = item.draft.description ?? ""
    }

    mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
        noteInputs.removeValue(forKey: id)
        fieldInputs = fieldInputs.filter { $0.key.itemID != id }
    }

    mutating func setKind(_ kind: BudgetTemplateKind, id: UUID) {
        guard typeChangeKinds(for: id).contains(kind),
              let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard items[index].draft.kind != kind else { return }
        let note = noteInputs[id]
        items[index].draft = items[index].draft.retyped(to: kind, now: now)
        if let note {
            items[index].draft = items[index].draft.updatingDescription(note)
        }
        fieldInputs = fieldInputs.filter { $0.key.itemID != id }
    }

    func dateTargetRepeats(for id: UUID) -> Bool {
        guard case .dateTarget(let value) = items.first(where: { $0.id == id })?.draft else {
            return false
        }
        return value.repeatInterval != nil
    }

    func dateTargetIsAnnual(for id: UUID) -> Bool {
        guard case .dateTarget(let value) = items.first(where: { $0.id == id })?.draft else {
            return false
        }
        return value.annual
    }

    func dateTargetAllowsEarlySpending(for id: UUID) -> Bool {
        guard case .dateTarget(let value) = items.first(where: { $0.id == id })?.draft else {
            return false
        }
        return value.isSpend
    }

    mutating func setDateTargetRepeats(_ repeats: Bool, id: UUID) {
        if !repeats { clearInputs(id: id, fields: [.repeatInterval], includingInvalid: true) }
        mutate(id: id) { draft in
            guard case .dateTarget(var value) = draft else { return }
            if repeats {
                value.repeatInterval = value.repeatInterval ?? 1
            } else {
                value.repeatInterval = nil
                value.annual = false
            }
            draft = .dateTarget(value)
        }
    }

    mutating func setDateTargetAnnual(_ annual: Bool, id: UUID) {
        mutate(id: id) { draft in
            guard case .dateTarget(var value) = draft,
                  value.repeatInterval != nil else { return }
            value.annual = annual
            draft = .dateTarget(value)
        }
    }

    mutating func setDateTargetEarlySpending(_ enabled: Bool, id: UUID) {
        if !enabled { clearInputs(id: id, fields: [.spendStartMonth], includingInvalid: true) }
        mutate(id: id) { draft in
            guard case .dateTarget(var value) = draft else { return }
            value.isSpend = enabled
            if enabled {
                value.fromMonth = value.fromMonth ?? value.month
            } else {
                value.fromMonth = nil
            }
            draft = .dateTarget(value)
        }
    }

    var defaultWeeklyStart: String {
        BudgetTemplateEditorCalendar.defaultWeeklyStart(for: items.map(\.draft), now: now)
    }

    func fixedStartNeedsRepair(for id: UUID) -> Bool {
        guard case .monthlyFixed(let value) = items.first(where: { $0.id == id })?.draft else { return false }
        return BudgetTemplateCalendar.validatedDate(value.starting) == nil || !inputIsValid(for: .fixedStart, id: id)
    }

    func limitStartNeedsRepair(for id: UUID) -> Bool {
        guard case .balanceLimit(let value) = items.first(where: { $0.id == id })?.draft else { return false }
        return value.start.map { BudgetTemplateCalendar.validatedDate($0) == nil } ?? (value.period == .weekly)
    }

    func fixedStartingDate(for id: UUID) -> Date {
        guard case .monthlyFixed(let value) = items.first(where: { $0.id == id })?.draft,
              let date = BudgetTemplateCalendar.validatedDate(value.starting) else {
            return BudgetTemplateCalendar.validatedDate(
                BudgetTemplateDefinition.firstDayOfCurrentMonth(now: now)
            ) ?? now
        }
        return date
    }

    mutating func setFixedCadence(_ cadence: BudgetTemplateCadence, id: UUID) {
        mutate(id: id) { draft in
            guard case .monthlyFixed(var value) = draft else {
                return
            }
            value.cadence = cadence
            draft = .monthlyFixed(value)
        }
    }

    mutating func setFixedStartingDate(_ date: Date, id: UUID) {
        clearInputs(id: id, fields: [.fixedStart], includingInvalid: true)
        mutate(id: id) { draft in
            guard case .monthlyFixed(var value) = draft else { return }
            value.starting = BudgetTemplateCalendar.dayID(from: date)
            draft = .monthlyFixed(value)
        }
    }

    mutating func setLimitPeriod(_ period: BudgetTemplateLimitPeriod, id: UUID) {
        let weeklyStart = defaultWeeklyStart
        mutate(id: id) { draft in
            guard case .balanceLimit(var value) = draft else { return }
            value.period = period
            if period == .weekly, value.start == nil {
                value.start = weeklyStart
            }
            draft = .balanceLimit(value)
        }
    }

    mutating func setLimitHold(_ hold: Bool, id: UUID) {
        mutate(id: id) { draft in
            guard case .balanceLimit(var value) = draft else { return }
            value.hold = hold
            draft = .balanceLimit(value)
        }
    }

    func limitWeekday(for id: UUID) -> Int {
        guard case .balanceLimit(let value) = items.first(where: { $0.id == id })?.draft else {
            return BudgetTemplateEditorCalendar.weekday(for: defaultWeeklyStart) ?? 1
        }
        return BudgetTemplateEditorCalendar.weekday(for: value.start ?? defaultWeeklyStart) ?? 1
    }

    mutating func setLimitWeekday(_ weekday: Int, id: UUID) {
        clearInputs(id: id, fields: [.limitStart], includingInvalid: true)
        let fallbackStart = defaultWeeklyStart
        mutate(id: id) { draft in
            guard case .balanceLimit(var value) = draft else {
                return
            }
            let start = value.start.flatMap { BudgetTemplateCalendar.validatedDate($0) == nil ? nil : $0 } ?? fallbackStart
            guard let updated = BudgetTemplateEditorCalendar.dayID(
                start,
                movingToWeekday: weekday
            ) else { return }
            value.start = updated
            draft = .balanceLimit(value)
        }
    }

    mutating func setPercentageSource(_ sourceID: String, id: UUID) {
        guard let option = percentageSourceOptions(for: id).first(where: { $0.id == sourceID }),
              option.isAvailable else {
            return
        }
        mutate(id: id) { draft in
            guard case .percentage(var value) = draft else { return }
            value.sourceCategory = sourceID
            draft = .percentage(value)
        }
    }

    mutating func setPercentagePrevious(_ previous: Bool, id: UUID) {
        mutate(id: id) { draft in
            guard case .percentage(var value) = draft else { return }
            value.previous = previous
            if previous,
               value.sourceCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedLowercase == BudgetTemplatePercentageSource.availableFundsID {
                value.sourceCategory = ""
            }
            draft = .percentage(value)
        }
    }

    mutating func setSchedule(_ selectedID: String?, id: UUID) {
        guard let option = schedules.first(where: { $0.id == selectedID && $0.isAvailable }) else {
            return
        }
        mutate(id: id) { draft in
            guard case .schedule(var value) = draft else {
                return
            }
            value.scheduleId = option.id
            value.name = option.name
            draft = .schedule(value)
        }
    }

    mutating func setScheduleFull(_ full: Bool, id: UUID) {
        mutate(id: id) { draft in
            guard case .schedule(var value) = draft else { return }
            value.full = full
            draft = .schedule(value)
        }
    }

    func adjustmentMode(for id: UUID) -> BudgetTemplateAdjustmentMode {
        guard let adjustment = adjustment(for: id) else {
            return .none
        }
        switch adjustment {
        case .fixed: return .fixed
        case .percent: return .percent
        }
    }

    func adjustmentDirection(for id: UUID) -> BudgetTemplateAdjustmentDirection {
        guard case .percent(let value) = adjustment(for: id) else {
            return .increase
        }
        return value.sign == .minus ? .decrease : .increase
    }

    mutating func setAdjustmentMode(_ mode: BudgetTemplateAdjustmentMode, id: UUID) {
        guard adjustmentMode(for: id) != mode else { return }
        clearInputs(id: id, fields: [.adjustment], includingInvalid: mode == .none)
        let current = adjustment(for: id)
        let updated = Self.adjustment(for: mode, current: current)
        mutate(id: id) { draft in
            draft = draft.updatingModifierAdjustment(updated)
        }
    }

    mutating func setAdjustmentDirection(_ direction: BudgetTemplateAdjustmentDirection, id: UUID) {
        clearInputs(id: id, fields: [.adjustment], includingInvalid: false)
        guard case .percent(let current) = adjustment(for: id) else {
            return
        }
        let updated = BudgetTemplateAdjustment.percent(
            direction == .decrease ? -abs(current) : abs(current)
        )
        mutate(id: id) { draft in
            draft = draft.updatingModifierAdjustment(updated)
        }
    }

    func inputText(for field: BudgetTemplateEditorInputField, id: UUID) -> String {
        if let state = fieldInputs[BudgetTemplateEditorInputKey(itemID: id, field: field)] {
            return state.text
        }
        guard let draft = items.first(where: { $0.id == id })?.draft else {
            return ""
        }
        return BudgetTemplateEditorInputInterpreter.text(
            for: field,
            draft: draft,
            currency: currency
        ) ?? ""
    }

    func inputIsValid(for field: BudgetTemplateEditorInputField, id: UUID) -> Bool {
        fieldInputs[BudgetTemplateEditorInputKey(itemID: id, field: field)]?.isValid ?? true
    }

    mutating func setInput(_ text: String, field: BudgetTemplateEditorInputField, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        let key = BudgetTemplateEditorInputKey(itemID: id, field: field)
        guard let updatedDraft = BudgetTemplateEditorInputInterpreter.applying(
            text,
            for: field,
            to: items[index].draft,
            currency: currency
        ) else {
            fieldInputs[key] = BudgetTemplateEditorInputState(text: text, isValid: false)
            return
        }
        items[index].draft = updatedDraft
        fieldInputs[key] = BudgetTemplateEditorInputState(text: text, isValid: true)
    }

    func noteText(id: UUID) -> String {
        noteInputs[id] ?? items.first(where: { $0.id == id })?.draft.description ?? ""
    }

    func hasNote(id: UUID) -> Bool {
        !noteText(id: id).isEmpty
    }

    mutating func setNoteText(_ text: String, id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        noteInputs[id] = text
        items[index].draft = items[index].draft.updatingDescription(text)
    }

    mutating func clearNote(id: UUID) {
        setNoteText("", id: id)
    }

    private func adjustment(for id: UUID) -> BudgetTemplateAdjustment? {
        items.first(where: { $0.id == id })?.draft.modifierAdjustment
    }

    private static func adjustment(
        for mode: BudgetTemplateAdjustmentMode,
        current: BudgetTemplateAdjustment?
    ) -> BudgetTemplateAdjustment? {
        switch mode {
        case .none:
            return nil
        case .fixed:
            return .fixed(current?.value ?? 10)
        case .percent:
            return .percent(current?.value ?? 10)
        }
    }

    private mutating func mutate(id: UUID, _ body: (inout BudgetTemplateDraft) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        body(&items[index].draft)
    }

    private mutating func clearInputs(id: UUID, fields: Set<BudgetTemplateEditorInputField>, includingInvalid: Bool) {
        fieldInputs = fieldInputs.filter { key, state in
            key.itemID != id || !fields.contains(key.field) || (!includingInvalid && !state.isValid)
        }
    }
}
