#!/usr/bin/env bash
# Day and month text, packed dates and UTC calendars have one owner each
# (AGENTS.md, Reuse Before You Build, Canonical Owners). This fails on a new
# hand-built copy: a raw GMT zone, a `yyyy-MM...` formatter, or a local
# `dayID`/`monthID`/`shiftedMonth` function outside the files below.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATTERN='TimeZone\(secondsFromGMT: 0\)|dateFormat = "yyyy-MM|func dayID\(|func monthID\(|func shiftedMonth\('

# Every entry is "path|reason". Add a file only with a reason; prefer moving
# the code onto an owner.
ALLOWED=(
  # Owners.
  "Actualist/Shared/ActualDateOnly.swift|owner of day IDs and Date conversion"
  "Actualist/Shared/ActualScheduleRecurrence.swift|owner of the fixed GMT Gregorian calendar and dayID(from:calendar:)"
  "Actualist/Shared/YearMonthParsing.swift|owner of month IDs and month arithmetic"
  "Actualist/Shared/PackedDate.swift|owner of packed YYYYMMDD values"
  "Actualist/Shared/ImportDateParsing.swift|Actual import date parity"
  "Actualist/Widgets/WidgetMonthID.swift|the widget target cannot see YearMonth"
  "ActualistWidget/WidgetPreviewData.swift|widget preview data; the widget target cannot see ActualDateOnly"
  # Left deliberately: changing them would change output.
  "Actualist/Shared/ActualDateParsing.swift|String.actualDate is a lenient device-zone formatter (decision D7)"
  "Actualist/LocalFirst/Network/SimpleFINBridgeClient.swift|unixSeconds(fromDay:) gives odd values for malformed 10-character text if migrated"
  "Actualist/Features/Reports/ReportsModels.swift|ReportCalendar day, month and shift variants; gregorianUTC feeds the SwiftUI calendar environment"
  "Actualist/Features/Reports/ReportsView.swift|SwiftUI timeZone environment matching ReportCalendar.gregorianUTC"
  "Actualist/Features/Reports/ReportExplorerView.swift|SwiftUI timeZone environment matching ReportCalendar.gregorianUTC"
  "Actualist/Features/Budget/BudgetViewportModel.swift|monthID(_:offsetBy:) is the Budget swipe wrapper over YearMonth.shiftedID"
  "Actualist/Features/Schedules/ScheduleEditorDraft.swift|dayID(from:timeZone:) forwarder to ActualDateOnly, pinned by DateOwnershipCharacterizationTests"
  "Actualist/Features/Settings/RuleEditorDraftState.swift|dayID(from:) forwarder to ActualDateOnly, pinned by DateOwnershipCharacterizationTests"
  "Actualist/Features/Templates/BudgetTemplateEditorCalendar.swift|dayID(_:movingToWeekday:) moves a day, it does not format one"
  "Actualist/Shared/BankSyncSupport.swift|dayID(fromUnixSeconds:) is the named UTC compact-day variant"
  "Actualist/LocalFirst/Database/BudgetTemplateCalendar.swift|template calendar: local-noon dayID(from:) and the range-checked, throwing shiftedMonth"
  # Date-and-time formatters, not day IDs.
  "Actualist/Features/Settings/DiagnosticReport.swift|ISO 8601 timestamp formatters"
  "Actualist/LocalFirst/Sync/SyncTimestamp.swift|CRDT timestamp format"
  # Hand-built UTC formatters and calendars not yet migrated onto ActualDateOnly.
  "Actualist/LocalFirst/Database/BudgetDatabase+Rules.swift|UTC yyyy-MM-dd formatter for the payee-rule lookup window, not migrated"
  "Actualist/LocalFirst/Database/BudgetDatabase+BasicReads.swift|UTC yyyy-MM-dd formatter for the 12-week cutoff, not migrated"
  "Actualist/LocalFirst/Database/BudgetDatabase+Reports.swift|UTC display calendar for the transaction calendar, not migrated"
  "Actualist/LocalFirst/Database/BudgetDatabase+TransactionQuery.swift|UTC calendar for the filter's approximate date bounds, not migrated"
)

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required for the date ownership lint but was not found on PATH." >&2
  exit 2
fi

globs=()
for entry in "${ALLOWED[@]}"; do
  globs+=(--glob "!${entry%%|*}")
done

rc=0
matches="$(cd "$ROOT_DIR" && rg --line-number --glob '*.swift' "${globs[@]}" -e "$PATTERN" Actualist ActualistWidget)" || rc=$?
case "$rc" in
  0)
    echo "$matches"
    cat >&2 <<'MSG'

Date ownership lint failed.

Use the Canonical Owners in AGENTS.md: ActualDateOnly for day IDs and Date
conversion, YearMonth for month IDs and arithmetic, PackedDate for packed
YYYYMMDD values. If a copy must differ, add a named variant to the owner. Only
list a file in ALLOWED in scripts/lint-date-ownership.sh with a reason.
MSG
    exit 1
    ;;
  1) echo "ok: no hand-built day or month copies outside ${#ALLOWED[@]} listed files" ;;
  *) echo "error: rg failed with exit ${rc}" >&2; exit 2 ;;
esac
