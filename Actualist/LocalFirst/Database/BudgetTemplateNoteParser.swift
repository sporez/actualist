// Pure note-directive parser for the note-managed template staleness guard.
// See BudgetDatabase+TemplateNoteSync.swift for the guard and DB reads.
import Foundation

// MARK: - Pure note-directive parser (comparison only)

enum BudgetTemplateNoteParser {
    /// One `#template` / `#goal` line scanned from a category note, parsed into
    /// the behaviorally-relevant fields Actual stores in `goal_def`.
    ///
    /// `type` is `nil` when the line is malformed or uses a syntax this scanner
    /// cannot classify (for example multi-line YAML). A `nil` type is treated
    /// as a parse failure and reconciled against `goal_def` error entries.
    struct Directive: Equatable {
        let keyword: String        // "template" | "goal"
        let type: String?          // detected template type, nil if untypeable
        let monthly: Double?
        let amount: Double?
        let percent: Double?
        let previous: Bool
        let sourceCategory: String?
        let numMonths: Int?
        let lookBack: Int?
        let weight: Double?
        let periodAmount: Int?
        let periodPeriod: String?
        let starting: String?
        let month: String?
        let fromMonth: String?
        let annual: Bool
        let repeatInterval: Int?
        let scheduleName: String?
        let scheduleId: String?
        let full: Bool
        let adjustment: Double?
        let adjustmentType: String?
        let limitAmount: Double?
        let limitPeriod: String?
        let limitStart: String?
    }

    /// Scans every `#template` / `#goal` directive line in `note`, in order.
    static func directives(in note: String) -> [Directive] {
        let pattern = #"^\s*#(template|goal)(?:[ \t]+(.*))?$"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines]
        ) else { return [] }

        let nsNote = note as NSString
        let matches = regex.matches(
            in: note,
            range: NSRange(location: 0, length: nsNote.length)
        )
        return matches.map { match -> Directive in
            let keyword = nsNote.substring(with: match.range(at: 1))
            let argument: String
            if match.range(at: 2).location == NSNotFound {
                argument = ""
            } else {
                argument = nsNote.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
            }
            return parse(keyword: keyword, argument: argument)
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
        if noteDirective.type != goalEntry.type {
            return "the category note template type changed"
        }

        switch noteDirective.type {
        case "simple":
            if !equal(noteDirective.monthly, goalEntry.monthly) {
                return "the category note template amount changed"
            }
            if let limitReason = limitMismatch(noteDirective, goalEntry.limit) {
                return limitReason
            }
        case "periodic":
            if !equal(noteDirective.amount, goalEntry.amount) {
                return "the category note periodic amount changed"
            }
            if !equalInt(noteDirective.periodAmount, goalEntry.period?.amount) {
                return "the category note periodic interval changed"
            }
            if normalized(noteDirective.periodPeriod) != normalized(goalEntry.period?.period) {
                return "the category note periodic period changed"
            }
            if normalized(noteDirective.starting) != normalized(goalEntry.starting) {
                return "the category note periodic start date changed"
            }
            if let limitReason = limitMismatch(noteDirective, goalEntry.limit) {
                return limitReason
            }
        case "copy":
            if !equalInt(noteDirective.lookBack, goalEntry.lookBack) {
                return "the category note copy look-back changed"
            }
        case "average":
            if !equalInt(noteDirective.numMonths, goalEntry.numMonths) {
                return "the category note average window changed"
            }
        case "remainder":
            if !equal(noteDirective.weight, goalEntry.weight) {
                return "the category note remainder weight changed"
            }
            if let limitReason = limitMismatch(noteDirective, goalEntry.limit) {
                return limitReason
            }
        case "percentage":
            if !equal(noteDirective.percent, goalEntry.percentageAmount) {
                return "the category note percentage changed"
            }
            if noteDirective.previous != (goalEntry.previous ?? false) {
                return "the category note percentage previous flag changed"
            }
            if normalizeSourceCategory(noteDirective.sourceCategory)
                != normalizeSourceCategory(goalEntry.sourceCategory) {
                return "the category note percentage source changed"
            }
        case "schedule":
            if let reason = scheduleMismatch(noteDirective, goalEntry) {
                return reason
            }
        case "spend":
            if !equal(noteDirective.amount, goalEntry.amount) {
                return "the category note spend amount changed"
            }
            if normalized(noteDirective.month) != normalized(goalEntry.month) {
                return "the category note spend target month changed"
            }
            if normalized(noteDirective.fromMonth) != normalized(goalEntry.fromMonth) {
                return "the category note spend start month changed"
            }
        case "by":
            if !equal(noteDirective.amount, goalEntry.amount) {
                return "the category note by amount changed"
            }
            if normalized(noteDirective.month) != normalized(goalEntry.month) {
                return "the category note by target month changed"
            }
            if noteDirective.annual != (goalEntry.annual ?? false) {
                return "the category note by annual flag changed"
            }
        case "limit":
            let goalLimit = goalEntry.standaloneLimit
            if !equal(noteDirective.limitAmount, goalLimit?.amount) {
                return "the category note up-to limit amount changed"
            }
            if normalized(noteDirective.limitPeriod) != normalized(goalLimit?.period) {
                return "the category note up-to limit period changed"
            }
            if normalized(noteDirective.limitStart) != normalized(goalLimit?.start) {
                return "the category note up-to limit start date changed"
            }
        case "goal":
            if !equal(noteDirective.amount, goalEntry.amount) {
                return "the category note goal amount changed"
            }
            // The goal target month is only compared when both sides express
            // it; Actual may store the target on `long_goal` instead.
            if let noteMonth = normalized(noteDirective.month),
               normalized(goalEntry.month) != nil,
               noteMonth != normalized(goalEntry.month) {
                return "the category note goal target month changed"
            }
        default:
            // Unknown stored type: cannot verify, treat as stale rather than
            // risk applying an unverifiable definition.
            return "the category note uses a template type that cannot be verified"
        }
        return nil
    }

    private static func limitMismatch(
        _ noteDirective: Directive,
        _ goalLimit: BudgetTemplateLimit?
    ) -> String? {
        // A limit clause is optional on simple/periodic/remainder. Only
        // compare when the note expresses one.
        guard noteDirective.limitAmount != nil || noteDirective.limitPeriod != nil
            || noteDirective.limitStart != nil else { return nil }
        if !equal(noteDirective.limitAmount, goalLimit?.amount) {
            return "the category note up-to limit amount changed"
        }
        if normalized(noteDirective.limitPeriod) != normalized(goalLimit?.period) {
            return "the category note up-to limit period changed"
        }
        if normalized(noteDirective.limitStart) != normalized(goalLimit?.start) {
            return "the category note up-to limit start date changed"
        }
        return nil
    }

    private static func scheduleMismatch(
        _ noteDirective: Directive,
        _ goalEntry: BudgetTemplateEntry
    ) -> String? {
        // Identity: scheduleId if present, else name.
        if let parsedID = noteDirective.scheduleId {
            if parsedID != (goalEntry.scheduleId ?? "") {
                return "the category note schedule reference changed"
            }
        } else if let parsedName = noteDirective.scheduleName {
            if normalized(parsedName) != normalized(goalEntry.name) {
                return "the category note schedule reference changed"
            }
        } else {
            return "the category note schedule reference changed"
        }
        if noteDirective.full != (goalEntry.full ?? false) {
            return "the category note schedule full flag changed"
        }
        if !equal(noteDirective.adjustment, goalEntry.adjustment)
            || normalized(noteDirective.adjustmentType) != normalized(goalEntry.adjustmentType) {
            return "the category note schedule adjustment changed"
        }
        return nil
    }

    // MARK: Comparison helpers

    private static func equal(_ a: Double?, _ b: Double?, tolerance: Double = 0.01) -> Bool {
        switch (a, b) {
        case let (x?, y?): return abs(x - y) < tolerance
        case (nil, nil): return true
        default: return false
        }
    }

    private static func equalInt(_ a: Int?, _ b: Int?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return x == y
        case (nil, nil): return true
        default: return false
        }
    }

    private static func normalized(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeSourceCategory(_ s: String?) -> String? {
        guard var trimmed = normalized(s) else { return nil }
        let lower = trimmed.lowercased()
        if lower == "income" || lower == "all income" {
            trimmed = "all income"
        }
        return trimmed
    }

    // MARK: Parsing

    private static func parse(keyword: String, argument: String) -> Directive {
        if keyword == "goal" {
            return parseGoal(argument: argument)
        }
        return parseTemplate(argument: argument)
    }

    private static func parseGoal(argument: String) -> Directive {
        let tokens = tokenize(argument)
        guard let amountToken = tokens.first, let amount = parseNumber(amountToken) else {
            return malformed(keyword: "goal")
        }
        var month: String?
        if let byIndex = tokens.firstIndex(of: "by"), byIndex + 1 < tokens.count {
            month = tokens[byIndex + 1]
        }
        return Directive(
            keyword: "goal", type: "goal", monthly: nil, amount: amount,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: month, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    private static func parseTemplate(argument: String) -> Directive {
        let tokens = tokenize(argument)
        guard let first = tokens.first else { return malformed(keyword: "template") }
        let lowered = first.lowercased()

        switch lowered {
        case "remainder":
            return parseRemainder(tokens: tokens)
        case "copy":
            return parseCopy(tokens: tokens)
        case "average":
            return parseAverage(tokens: tokens)
        case "schedule":
            return parseSchedule(tokens: tokens)
        case "spend":
            return parseSpend(tokens: tokens)
        case "by":
            return parseBy(tokens: tokens)
        case "up":
            // `up to ...` standalone limit.
            return parseStandaloneLimit(tokens: tokens)
        default:
            break
        }

        if argument.contains("%") {
            return parsePercentage(tokens: tokens)
        }

        // Number-led: simple or periodic.
        guard let value = parseNumber(first) else { return malformed(keyword: "template") }

        if let period = periodFromTokens(tokens, after: 0) {
            return Directive(
                keyword: "template", type: "periodic", monthly: nil, amount: value,
                percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
                lookBack: nil, weight: nil,
                periodAmount: period.amount, periodPeriod: period.period,
                starting: nil, month: nil, fromMonth: nil, annual: false,
                repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
                adjustment: nil, adjustmentType: nil,
                limitAmount: nil, limitPeriod: nil, limitStart: nil
            )
        }

        // Simple, optionally with an attached limit.
        let limit = limitFromTokens(tokens, after: 0)
        return Directive(
            keyword: "template", type: "simple", monthly: value, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: limit?.amount, limitPeriod: limit?.period, limitStart: limit?.start
        )
    }

    private static func parseRemainder(tokens: [String]) -> Directive {
        // `remainder` optionally followed by a weight and/or an up-to limit.
        var weight: Double? = nil
        var rest = Array(tokens.dropFirst())
        if let first = rest.first, let n = parseNumber(first), !isLimitStart(first) {
            weight = n
            rest = Array(rest.dropFirst())
        }
        let limit = limitFromTokens(rest, after: -1)
        return Directive(
            keyword: "template", type: "remainder", monthly: nil, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: weight ?? 1, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: limit?.amount, limitPeriod: limit?.period, limitStart: limit?.start
        )
    }

    private static func parseCopy(tokens: [String]) -> Directive {
        var lookBack: Int? = nil
        if let next = tokens.dropFirst().first, let n = parseNumber(next) {
            lookBack = Int(n)
        }
        return Directive(
            keyword: "template", type: "copy", monthly: nil, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: lookBack ?? 1, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    private static func parseAverage(tokens: [String]) -> Directive {
        guard let next = tokens.dropFirst().first, let n = parseNumber(next) else {
            return malformed(keyword: "template")
        }
        return Directive(
            keyword: "template", type: "average", monthly: nil, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: Int(n),
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    private static func parseSchedule(tokens: [String]) -> Directive {
        // `schedule <ref> [full] [<adjustment>]`
        var rest = Array(tokens.dropFirst())
        guard let ref = rest.first else { return malformed(keyword: "template") }
        rest = Array(rest.dropFirst())

        var scheduleId: String?
        var scheduleName: String?
        if ref.lowercased().hasPrefix("id:") {
            scheduleId = String(ref.dropFirst(3))
        } else {
            scheduleName = ref
        }

        var full = false
        var adjustment: Double?
        var adjustmentType: String?
        for token in rest {
            if token.lowercased() == "full" {
                full = true
            } else if let adj = parseAdjustment(token) {
                adjustment = adj.value
                adjustmentType = adj.type
            }
        }
        return Directive(
            keyword: "template", type: "schedule", monthly: nil, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: scheduleName, scheduleId: scheduleId,
            full: full, adjustment: adjustment, adjustmentType: adjustmentType,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    private static func parseSpend(tokens: [String]) -> Directive {
        // `spend <amount> from <start> to <end>`
        let rest = Array(tokens.dropFirst())
        guard let amount = rest.first.flatMap(parseNumber) else {
            return malformed(keyword: "template")
        }
        let from = tokenAfter(rest, keyword: "from")
        let to = tokenAfter(rest, keyword: "to")
        return Directive(
            keyword: "template", type: "spend", monthly: nil, amount: amount,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: to, fromMonth: from, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    private static func parseBy(tokens: [String]) -> Directive {
        // `by <month> <amount> [repeat every year]`
        let rest = Array(tokens.dropFirst())
        guard let month = rest.first else { return malformed(keyword: "template") }
        let afterMonth = Array(rest.dropFirst())
        guard let amount = afterMonth.first.flatMap(parseNumber) else {
            return malformed(keyword: "template")
        }
        let annual = containsAnnualKeyword(afterMonth)
        return Directive(
            keyword: "template", type: "by", monthly: nil, amount: amount,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: month, fromMonth: nil, annual: annual,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    private static func parseStandaloneLimit(tokens: [String]) -> Directive {
        // `up to <amount> [daily|weekly|monthly] [starting <date>]`
        guard tokens.first?.lowercased() == "up",
              tokens.count > 1, tokens[1].lowercased() == "to" else {
            return malformed(keyword: "template")
        }
        let rest = Array(tokens.dropFirst(2))
        guard let amount = rest.first.flatMap(parseNumber) else {
            return malformed(keyword: "template")
        }
        let afterAmount = Array(rest.dropFirst())
        let period = periodKeywordFromTokens(afterAmount) ?? "monthly"
        let start = tokenAfter(afterAmount, keyword: "starting")
        return Directive(
            keyword: "template", type: "limit", monthly: nil, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: amount, limitPeriod: period, limitStart: start
        )
    }

    private static func parsePercentage(tokens: [String]) -> Directive {
        // `<pct>% [of] [previous] <source>` / `previous <pct>% of income`
        var previous = false
        var percent: Double?
        var source: String?

        for token in tokens {
            if token.lowercased() == "previous" {
                previous = true
                continue
            }
            if token.contains("%") {
                let digits = token.replacingOccurrences(of: "%", with: "")
                percent = parseNumber(digits)
                continue
            }
            if token.lowercased() == "of" { continue }
            if source == nil {
                source = token
            } else {
                source = source! + " " + token
            }
        }
        guard percent != nil else { return malformed(keyword: "template") }
        return Directive(
            keyword: "template", type: "percentage", monthly: nil, amount: nil,
            percent: percent, previous: previous, sourceCategory: source,
            numMonths: nil, lookBack: nil, weight: nil, periodAmount: nil,
            periodPeriod: nil, starting: nil, month: nil, fromMonth: nil,
            annual: false, repeatInterval: nil, scheduleName: nil, scheduleId: nil,
            full: false, adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }

    // MARK: Token helpers

    /// Splits an argument into whitespace-separated tokens, treating quoted
    /// substrings as a single token (quotes stripped).
    private static func tokenize(_ argument: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in argument {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func parseNumber(_ token: String) -> Double? {
        let cleaned = token.trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private static func parseAdjustment(_ token: String) -> (value: Double, type: String)? {
        guard !token.isEmpty else { return nil }
        let isPercent = token.hasSuffix("%")
        var body = token
        if isPercent { body.removeLast() }
        guard let sign = body.first, sign == "+" || sign == "-" else { return nil }
        guard let value = Double(body) else { return nil }
        return (value, isPercent ? "percent" : "fixed")
    }

    private static let periodKeywords: [String: (amount: Int, period: String)] = [
        "daily": (1, "day"), "day": (1, "day"), "days": (1, "day"),
        "weekly": (1, "week"), "week": (1, "week"), "weeks": (1, "week"),
        "monthly": (1, "month"), "month": (1, "month"), "months": (1, "month"),
        "yearly": (1, "year"), "year": (1, "year"), "years": (1, "year")
    ]

    /// Limit periods use Actual's adjectival vocabulary (`monthly` / `daily` /
    /// `weekly`), distinct from the periodic noun vocabulary
    /// (`month` / `day` / `week` / `year`).
    private static let limitPeriodKeywords: [String: String] = [
        "daily": "daily", "day": "daily", "days": "daily",
        "weekly": "weekly", "week": "weekly", "weeks": "weekly",
        "monthly": "monthly", "month": "monthly", "months": "monthly"
    ]

    /// Parses a period expression beginning at `start` in `tokens`, supporting
    /// `<word>`, `every <word>`, and `every <n> <word>`.
    private static func periodFromTokens(
        _ tokens: [String],
        after start: Int
    ) -> (amount: Int, period: String)? {
        var i = start + 1
        if i < tokens.count, tokens[i].lowercased() == "every" { i += 1 }
        // `every <n> <unit>`
        if i < tokens.count, let n = parseNumber(tokens[i]),
           i + 1 < tokens.count, let period = periodKeywords[tokens[i + 1].lowercased()] {
            return (max(Int(n), 1), period.period)
        }
        if i < tokens.count, let period = periodKeywords[tokens[i].lowercased()] {
            return (period.amount, period.period)
        }
        return nil
    }

    private static func periodKeywordFromTokens(_ tokens: [String]) -> String? {
        for token in tokens {
            if let p = limitPeriodKeywords[token.lowercased()] {
                return p
            }
            if token.lowercased() == "starting" { break }
        }
        return nil
    }

    private static func isLimitStart(_ token: String) -> Bool {
        token.lowercased() == "up" || token.lowercased() == "to"
    }

    /// Parses an `up to <amount> [period] [starting <date>]` clause beginning
    /// anywhere in `tokens` after `start`.
    private static func limitFromTokens(
        _ tokens: [String],
        after start: Int
    ) -> (amount: Double, period: String?, start: String?)? {
        var search = start + 1
        while search < tokens.count - 1 {
            if tokens[search].lowercased() == "up",
               tokens[search + 1].lowercased() == "to" {
                let after = Array(tokens.dropFirst(search + 2))
                guard let amount = after.first.flatMap(parseNumber) else { return nil }
                let afterAmount = Array(after.dropFirst())
                let period = periodKeywordFromTokens(afterAmount) ?? "monthly"
                let startStr = tokenAfter(afterAmount, keyword: "starting")
                return (amount, period, startStr)
            }
            search += 1
        }
        return nil
    }

    private static func tokenAfter(_ tokens: [String], keyword: String) -> String? {
        guard let index = tokens.firstIndex(where: { $0.lowercased() == keyword }),
              index + 1 < tokens.count else { return nil }
        return tokens[index + 1]
    }

    private static func containsAnnualKeyword(_ tokens: [String]) -> Bool {
        tokens.contains { $0.lowercased() == "year" || $0.lowercased() == "yearly" }
            || (tokens.contains { $0.lowercased() == "repeat" }
                && tokens.contains { $0.lowercased() == "year" })
    }

    private static func malformed(keyword: String) -> Directive {
        Directive(
            keyword: keyword, type: nil, monthly: nil, amount: nil,
            percent: nil, previous: false, sourceCategory: nil, numMonths: nil,
            lookBack: nil, weight: nil, periodAmount: nil, periodPeriod: nil,
            starting: nil, month: nil, fromMonth: nil, annual: false,
            repeatInterval: nil, scheduleName: nil, scheduleId: nil, full: false,
            adjustment: nil, adjustmentType: nil,
            limitAmount: nil, limitPeriod: nil, limitStart: nil
        )
    }
}
