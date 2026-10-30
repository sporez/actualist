// Pure note-directive parser for the note-managed template staleness guard.
// See BudgetDatabase+TemplateNoteSync.swift for the guard and DB reads.
// Follows Actual's goal-template.pegjs and template-notes.ts line for line;
// scripts/template-note-parity pins the result against Actual's own parser.
import Foundation

// MARK: - Pure note-directive parser (comparison only)

enum BudgetTemplateNoteParser {
    /// One `#template` / `#goal` line scanned from a category note, parsed into
    /// the behaviorally-relevant fields Actual stores in `goal_def`.
    ///
    /// `type` is `nil` when Actual's grammar rejects the line. Actual stores such
    /// a line as an error entry, so a `nil` type is reconciled against those.
    struct Directive: Equatable {
        var keyword: String        // "template" | "goal"
        var type: String?          // detected template type, nil if untypeable
        var priority: Int? = nil
        var monthly: Double? = nil
        var amount: Double? = nil
        var percent: Double? = nil
        var previous = false
        var sourceCategory: String? = nil
        var numMonths: Int? = nil
        var lookBack: Int? = nil
        var weight: Double? = nil
        var periodAmount: Int? = nil
        var periodPeriod: String? = nil
        var starting: String? = nil
        var month: String? = nil
        var fromMonth: String? = nil
        var annual = false
        var repeatInterval: Int? = nil
        var scheduleName: String? = nil
        var full = false
        var adjustment: Double? = nil
        var adjustmentType: String? = nil
        var limit: BudgetTemplateLimit? = nil
    }

    /// Scans every `#template` / `#goal` directive line in `note`, in order.
    /// Actual reads a line from its first `#`, so text may come before a directive.
    static func directives(in note: String) -> [Directive] {
        note.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> Directive? in
                let directive = line[(line.firstIndex(of: "#") ?? line.startIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard directive.hasPrefix("#template") || directive.hasPrefix("#goal") else { return nil }
                return parse(directive)
            }
    }

    /// Returns a human-readable staleness reason when the scanned note
    /// directives do not reconcile with the stored `goal_def` entries, or
    /// `nil` when the stored definition is consistent with the note.
    static func stalenessReason(
        noteDirectives: [Directive],
        goalDefEntries: [BudgetTemplateEntry]
    ) -> String? {
        // Nothing stored → nothing stale (the apply path simply skips it).
        guard !goalDefEntries.isEmpty else { return nil }

        if noteDirectives.isEmpty {
            return "the category note no longer contains a #template/#goal directive but a stored template definition still exists"
        }

        // Each #template / #goal line produces exactly one goal_def entry
        // (real or error). A count mismatch means a directive was added or
        // removed since Actual generated goal_def.
        guard noteDirectives.count == goalDefEntries.count else {
            let entryWord = goalDefEntries.count == 1 ? "entry" : "entries"
            return "the category note has \(noteDirectives.count) #template/#goal directive(s) but the stored definition has \(goalDefEntries.count) \(entryWord)"
        }

        for (noteDirective, goalEntry) in zip(noteDirectives, goalDefEntries) {
            if let reason = mismatchReason(noteDirective, goalEntry) {
                return reason
            }
        }
        return nil
    }

    // MARK: Reconciliation

    private static func mismatchReason(
        _ noteDirective: Directive,
        _ goalEntry: BudgetTemplateEntry
    ) -> String? {
        let goalDirective = goalEntry.directive ?? ""

        if goalDirective == "error" {
            // Actual stored a parse error. The current note line must still be
            // untypeable to be consistent; a now-parseable line means the note
            // was fixed and the stored error is stale.
            if noteDirective.type != nil {
                return "the category note line was previously malformed but is now parseable; the stored error definition is stale"
            }
            return nil
        }

        // Real (template/goal) stored entry.
        if noteDirective.type == nil {
            return "the category note directive is malformed but a valid stored definition exists"
        }
        if noteDirective.keyword != goalDirective {
            return "the category note directive changed between #template and #goal"
        }
        // Actual writes a stored cap into a note as `#template up to` or `#template 0 up to`.
        if goalEntry.type == "limit", noteDirective.type == "simple", (noteDirective.monthly ?? 0) == 0 {
            return limitMismatch(noteDirective.limit, goalEntry.standaloneLimit)
        }
        if noteDirective.type != goalEntry.type {
            return "the category note template type changed"
        }
        if noteDirective.priority != nil, noteDirective.priority != goalEntry.priority ?? 0 {
            return "the category note priority changed"
        }

        switch noteDirective.type {
        case "simple":
            if noteDirective.monthly != goalEntry.monthly {
                return "the category note template amount changed"
            }
            return limitMismatch(noteDirective.limit, goalEntry.limit)
        case "periodic":
            if noteDirective.amount != goalEntry.amount {
                return "the category note periodic amount changed"
            }
            if noteDirective.periodAmount != goalEntry.period?.amount {
                return "the category note periodic interval changed"
            }
            if noteDirective.periodPeriod != goalEntry.period?.period {
                return "the category note periodic period changed"
            }
            if noteDirective.starting != goalEntry.starting {
                return "the category note periodic start date changed"
            }
            return limitMismatch(noteDirective.limit, goalEntry.limit)
        case "copy":
            if noteDirective.lookBack != goalEntry.lookBack {
                return "the category note copy look-back changed"
            }
        case "average":
            if noteDirective.numMonths != goalEntry.numMonths {
                return "the category note average window changed"
            }
            return adjustmentMismatch(noteDirective, goalEntry)
        case "remainder":
            if noteDirective.weight != goalEntry.weight {
                return "the category note remainder weight changed"
            }
            return limitMismatch(noteDirective.limit, goalEntry.limit)
        case "percentage":
            if noteDirective.percent != goalEntry.percentageAmount {
                return "the category note percentage changed"
            }
            if noteDirective.previous != (goalEntry.previous ?? false) {
                return "the category note percentage previous flag changed"
            }
            if noteDirective.sourceCategory != goalEntry.sourceCategory {
                return "the category note percentage source changed"
            }
        case "schedule":
            if noteDirective.scheduleName != goalEntry.name {
                return "the category note schedule reference changed"
            }
            if noteDirective.full != (goalEntry.full ?? false) {
                return "the category note schedule full flag changed"
            }
            return adjustmentMismatch(noteDirective, goalEntry)
        case "by", "spend":
            let name = noteDirective.type ?? ""
            if noteDirective.amount != goalEntry.amount {
                return "the category note \(name) amount changed"
            }
            if noteDirective.month != goalEntry.month {
                return "the category note \(name) target month changed"
            }
            if noteDirective.fromMonth != goalEntry.fromMonth {
                return "the category note \(name) start month changed"
            }
            if noteDirective.annual != (goalEntry.annual ?? false)
                || noteDirective.repeatInterval != goalEntry.repeatInterval {
                return "the category note \(name) repeat changed"
            }
        case "goal":
            if noteDirective.amount != goalEntry.amount {
                return "the category note goal amount changed"
            }
        default:
            // Unknown stored type: cannot verify, treat as stale rather than
            // risk applying an unverifiable definition.
            return "the category note uses a template type that cannot be verified"
        }
        return nil
    }

    private static func limitMismatch(_ note: BudgetTemplateLimit?, _ stored: BudgetTemplateLimit?) -> String? {
        let matches = note?.amount == stored?.amount && note?.period == stored?.period
            && note?.start == stored?.start && (note?.hold ?? false) == (stored?.hold ?? false)
        return matches ? nil : "the category note up-to limit changed"
    }

    private static func adjustmentMismatch(_ noteDirective: Directive, _ goalEntry: BudgetTemplateEntry) -> String? {
        noteDirective.adjustment == goalEntry.adjustment && noteDirective.adjustmentType == goalEntry.adjustmentType
            ? nil
            : "the category note adjustment changed"
    }

    // MARK: Parsing

    /// Actual's grammar: the first alternative that matches wins, and the line
    /// is rejected when anything is left after it.
    private static func parse(_ line: String) -> Directive {
        let keyword = line.hasPrefix("#goal") ? "goal" : "template"
        var cursor = NoteCursor(line.dropFirst(keyword.count + 1))
        guard let directive = keyword == "goal" ? parseGoal(&cursor) : parseTemplate(&cursor),
              cursor.isAtEnd,
              isValidAdjustment(directive) else {
            return Directive(keyword: keyword, type: nil)
        }
        return directive
    }

    /// `storeNoteTemplates` rejects these after parsing, so they store as errors.
    private static func isValidAdjustment(_ directive: Directive) -> Bool {
        guard directive.adjustmentType == "percent", let adjustment = directive.adjustment else { return true }
        return adjustment > -100 && adjustment <= 1000
    }

    private static func parseGoal(_ cursor: inout NoteCursor) -> Directive? {
        cursor.amount().map { Directive(keyword: "goal", type: "goal", amount: $0) }
    }

    private static func parseTemplate(_ cursor: inout NoteCursor) -> Directive? {
        var priority = 0
        if cursor.take("-") {
            guard let value = Int(cursor.digits()) else { return nil }
            priority = value
        }
        let alternatives = [
            parsePercentage, parsePeriodic, parseTarget, parseSimple, parseCapOnly,
            parseSchedule, parseRemainder, parseAverage, parseCopy
        ]
        for alternative in alternatives {
            var attempt = cursor
            attempt.skipSpaces()
            if var directive = alternative(&attempt) {
                cursor = attempt
                // Actual stores a remainder without a priority.
                directive.priority = directive.type == "remainder" ? nil : priority
                return directive
            }
        }
        return nil
    }

    private static func parsePercentage(_ cursor: inout NoteCursor) -> Directive? {
        guard let percent = cursor.percent() else { return nil }
        cursor.skipSpaces()
        guard cursor.take("of") else { return nil }
        cursor.skipSpaces()
        let previous = cursor.take("previous")
        cursor.skipSpaces()
        let source = cursor.takeName()
        guard !source.isEmpty else { return nil }
        return Directive(
            keyword: "template", type: "percentage",
            percent: percent, previous: previous, sourceCategory: source
        )
    }

    private static func parsePeriodic(_ cursor: inout NoteCursor) -> Directive? {
        guard let amount = cursor.amount() else { return nil }
        cursor.skipSpaces()
        guard cursor.takeRepeatEvery(), let period = cursor.periodCount() else { return nil }
        cursor.skipSpaces()
        guard cursor.take("starting") else { return nil }
        cursor.skipSpaces()
        guard let starting = cursor.date() else { return nil }
        return Directive(
            keyword: "template", type: "periodic", amount: amount,
            periodAmount: period.amount, periodPeriod: period.period, starting: starting,
            limit: parseLimit(&cursor)
        )
    }

    /// `<amount> by <month> [spend from <month>] [repeat every ...]`.
    private static func parseTarget(_ cursor: inout NoteCursor) -> Directive? {
        guard let amount = cursor.amount() else { return nil }
        cursor.skipSpaces()
        guard cursor.take("by") else { return nil }
        cursor.skipSpaces()
        guard let month = cursor.month() else { return nil }

        var directive = Directive(keyword: "template", type: "by", amount: amount, month: month)
        var spend = cursor
        spend.skipSpaces()
        if spend.take("spend") {
            spend.skipSpaces()
            if spend.take("from") {
                spend.skipSpaces()
                if let from = spend.month() {
                    directive.type = "spend"
                    directive.fromMonth = from
                    cursor = spend
                }
            }
        }
        var repeating = cursor
        repeating.skipSpaces()
        if repeating.takeRepeatEvery(), let interval = repeating.repeatInterval() {
            directive.annual = interval.annual
            directive.repeatInterval = interval.count
            cursor = repeating
        }
        return directive
    }

    private static func parseSimple(_ cursor: inout NoteCursor) -> Directive? {
        guard let monthly = cursor.amount() else { return nil }
        return Directive(keyword: "template", type: "simple", monthly: monthly, limit: parseLimit(&cursor))
    }

    private static func parseCapOnly(_ cursor: inout NoteCursor) -> Directive? {
        parseLimit(&cursor).map { Directive(keyword: "template", type: "simple", limit: $0) }
    }

    private static func parseSchedule(_ cursor: inout NoteCursor) -> Directive? {
        guard cursor.take("schedule") else { return nil }
        cursor.skipSpaces()
        let full = cursor.take("full")
        cursor.skipSpaces()
        guard let name = cursor.scheduleName() else { return nil }
        var directive = Directive(keyword: "template", type: "schedule", scheduleName: name, full: full)
        applyAdjustment(&cursor, to: &directive)
        return directive
    }

    private static func parseRemainder(_ cursor: inout NoteCursor) -> Directive? {
        guard cursor.take("remainder") else { return nil }
        cursor.skipSpaces()
        let weight = cursor.positive().map(Double.init) ?? 1
        return Directive(keyword: "template", type: "remainder", weight: weight, limit: parseLimit(&cursor))
    }

    private static func parseAverage(_ cursor: inout NoteCursor) -> Directive? {
        guard cursor.take("average") else { return nil }
        cursor.skipSpaces()
        guard let months = cursor.positive() else { return nil }
        cursor.skipSpaces()
        _ = cursor.take("months")
        var directive = Directive(keyword: "template", type: "average", numMonths: months)
        applyAdjustment(&cursor, to: &directive)
        return directive
    }

    private static func parseCopy(_ cursor: inout NoteCursor) -> Directive? {
        guard cursor.take("copy from") else { return nil }
        cursor.skipSpaces()
        guard let lookBack = cursor.positive() else { return nil }
        cursor.skipSpaces()
        guard cursor.take("months ago") else { return nil }
        // Actual stores a limit here and ignores it, so it does not change the result.
        _ = parseLimit(&cursor)
        return Directive(keyword: "template", type: "copy", lookBack: lookBack)
    }

    /// `up to <amount> [per week starting <date> | per day] [hold]`.
    private static func parseLimit(_ cursor: inout NoteCursor) -> BudgetTemplateLimit? {
        var attempt = cursor
        attempt.skipSpaces()
        guard attempt.take("up") else { return nil }
        attempt.skipSpaces()
        guard attempt.take("to") else { return nil }
        attempt.skipSpaces()
        guard let amount = attempt.amount() else { return nil }

        var period = "monthly"
        var start: String?
        var clause = attempt
        clause.skipSpaces()
        if clause.take("per week starting") {
            clause.skipSpaces()
            if let date = clause.date() {
                period = "weekly"
                start = date
                attempt = clause
            }
        } else if clause.take("per day") {
            period = "daily"
            attempt = clause
        }
        attempt.skipSpaces()
        let hold = attempt.take("hold")
        cursor = attempt
        return BudgetTemplateLimit(amount: amount, period: period, hold: hold, start: start)
    }

    private static func applyAdjustment(_ cursor: inout NoteCursor, to directive: inout Directive) {
        var attempt = cursor
        attempt.skipSpaces()
        guard attempt.take("["), let adjustment = attempt.adjustment(), attempt.take("]") else { return }
        directive.adjustment = adjustment.value
        directive.adjustmentType = adjustment.type
        cursor = attempt
    }
}

/// Walks one directive line. Keywords match case-insensitively and need no word
/// boundary, as in Actual's grammar.
private struct NoteCursor {
    private var rest: Substring

    init(_ text: Substring) { rest = text }

    var isAtEnd: Bool { rest.isEmpty }

    mutating func skipSpaces() {
        rest = rest.drop { $0 == " " || $0 == "\t" }
    }

    /// `text` is lowercase.
    mutating func take(_ text: String) -> Bool {
        guard rest.prefix(text.count).lowercased() == text else { return false }
        rest = rest.dropFirst(text.count)
        return true
    }

    mutating func takeRepeatEvery() -> Bool {
        guard take("repeat") else { return false }
        skipSpaces()
        guard take("every") else { return false }
        skipSpaces()
        return true
    }

    mutating func digits() -> Substring {
        let run = rest.prefix { $0.isASCII && $0.isNumber }
        rest = rest.dropFirst(run.count)
        return run
    }

    /// `[1-9][0-9]*`.
    mutating func positive() -> Int? {
        guard let first = rest.first, first != "0", first.isNumber else { return nil }
        return Int(digits())
    }

    /// `[currency symbol] -?digits[.[d[d]]]`.
    mutating func amount() -> Double? {
        var attempt = self
        if attempt.rest.first?.unicodeScalars.first?.properties.generalCategory == .currencySymbol {
            attempt.rest.removeFirst()
        }
        attempt.skipSpaces()
        var text = attempt.take("-") ? "-" : ""
        let whole = attempt.digits()
        guard !whole.isEmpty else { return nil }
        text += whole
        if attempt.take(".") {
            let cents = attempt.rest.prefix(2).prefix { $0.isASCII && $0.isNumber }
            attempt.rest = attempt.rest.dropFirst(cents.count)
            text += "." + cents + "0"
        }
        self = attempt
        return Double(text)
    }

    /// `digits[.digits] %`.
    mutating func percent() -> Double? {
        var attempt = self
        guard let value = attempt.decimal() else { return nil }
        attempt.skipSpaces()
        guard attempt.take("%") else { return nil }
        self = attempt
        return value
    }

    /// `[increase|decrease] <number>[%]`.
    mutating func adjustment() -> (value: Double, type: String)? {
        var attempt = self
        let sign: Double
        if attempt.take("increase") {
            sign = 1
        } else if attempt.take("decrease") {
            sign = -1
        } else {
            return nil
        }
        attempt.skipSpaces()
        guard let value = attempt.decimal() else { return nil }
        var marker = attempt
        marker.skipSpaces()
        let isPercent = marker.take("%")
        self = isPercent ? marker : attempt
        return (sign * value, isPercent ? "percent" : "fixed")
    }

    private mutating func decimal() -> Double? {
        let whole = digits()
        guard !whole.isEmpty else { return nil }
        guard take(".") else { return Double(whole) }
        return Double(whole + "." + digits() + "0")
    }

    /// `YYYY-MM`.
    mutating func month() -> String? {
        var attempt = self
        guard let year = attempt.fixedDigits(4), attempt.take("-"), let month = attempt.fixedDigits(2) else {
            return nil
        }
        self = attempt
        return "\(year)-\(month)"
    }

    /// `YYYY-MM-DD`.
    mutating func date() -> String? {
        var attempt = self
        guard let month = attempt.month(), attempt.take("-"), let day = attempt.fixedDigits(2) else {
            return nil
        }
        self = attempt
        return "\(month)-\(day)"
    }

    private mutating func fixedDigits(_ count: Int) -> Substring? {
        let run = rest.prefix(count)
        guard run.count == count, run.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        rest = rest.dropFirst(count)
        return run
    }

    mutating func periodCount() -> (amount: Int, period: String)? {
        if take("day") { return (1, "day") }
        if take("week") { return (1, "week") }
        if take("year") { return (1, "year") }
        var attempt = self
        guard let count = Int(attempt.digits()) else { return nil }
        attempt.skipSpaces()
        for (word, period) in [("days", "day"), ("weeks", "week"), ("months", "month"), ("years", "year")]
        where attempt.take(word) {
            self = attempt
            return (count, period)
        }
        return nil
    }

    mutating func repeatInterval() -> (annual: Bool, count: Int?)? {
        if take("month") { return (false, nil) }
        if take("year") { return (true, nil) }
        var attempt = self
        guard let count = attempt.positive() else { return nil }
        attempt.skipSpaces()
        if attempt.take("months") {
            self = attempt
            return (false, count)
        }
        if attempt.take("years") {
            self = attempt
            return (true, count)
        }
        return nil
    }

    /// Everything up to a tab.
    mutating func takeName() -> String {
        let name = rest.prefix { $0 != "\t" && !$0.isNewline }
        rest = rest.dropFirst(name.count)
        return String(name)
    }

    /// Runs to the end of the line or to an `[increase ...]` / `[decrease ...]`.
    mutating func scheduleName() -> String? {
        guard let first = rest.first, first != " ", first != "\t", !startsAdjustment(rest) else { return nil }
        var end = rest.index(after: rest.startIndex)
        while end < rest.endIndex {
            var probe = NoteCursor(rest[end...])
            probe.skipSpaces()
            if startsAdjustment(probe.rest) { break }
            end = rest.index(after: end)
        }
        let name = rest[..<end]
        rest = rest[end...]
        return name.trimmingCharacters(in: .whitespaces)
    }

    private func startsAdjustment(_ text: Substring) -> Bool {
        var probe = NoteCursor(text)
        guard probe.take("[") else { return false }
        return probe.take("increase") || probe.take("decrease")
    }
}
