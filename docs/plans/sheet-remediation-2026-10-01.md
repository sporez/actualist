# Sprint Sheet Remediation Plan (2026-10-01)

Remediation for the review-pass findings against the sprint's sheet work.
Visual master: the template apply preview sheet
(`BudgetTemplateConfirmationSheet` + `BudgetTemplateReviewContent`).
Review evidence and screenshots: `.artifacts/sprint-review-screenshots/review/`.

## Findings being remediated

- **B1** Schedule editor bottom action bar overlaps form content (Options card
  and "Automatically post after sync" row render under the Cancel/Review pills;
  with the keyboard up the bar covers the Amount label and helper text).
- **B2** Schedule editor text fields have weak input affordance: on a real
  device the amount row is reachable with the keyboard up (Neil verified), but
  the plain TextFields do not read as input fields. (An earlier reading —
  "unreachable" — was a UI-test hit-testing artifact plus the bar overlap.)
- **B3** Schedule writes fail against budgets whose `schedules` table lacks the
  new columns. Root cause (DB-verified): the bundled demo budget's `schedules`
  table has only `id, name, rule, completed, tombstone` — no `posts_transaction`
  (or `custom_upcoming_length`/`sort_order`/`active`). Reads defend with
  fallbacks, but `ScheduleCreationMessagePlan` → `requiredColumns` throws
  `unsupportedCapability("missing column schedules.posts_transaction")` on
  every create. The editor surfaces this as a raw SQL error notice at the top
  of the form; the conversion flow fails the same way (no schedule persisted,
  verified — an earlier claim that conversion commits was a probe artifact).
  Nothing tells the user at entry that schedule authoring is unsupported on
  this budget.
- **B4** `safeAreaBar` buttons lose their accessibility identifiers (editor
  Cancel/Review and save-review Back/Save report the parent identifier);
  `schedule-save-review-button` / `schedule-save-confirm` probes are false.
  This is why the sprint's `SchedulesUITests` cannot pass.
- **Style deviations** (double headers, action-row sizing, value alignment,
  CSV export action placement, Saved Filters field styling, reports
  inconsistencies, schedules list details) and nits — see the review list.

Root-cause hypothesis for B1/B2: the master is a plain `.sheet`, while the
broken sheets run inside `NavigationStack` +
`.presentationSizing(.page.fitted(horizontal: true, vertical: false))`; the
`safeAreaBar` bottom inset does not propagate through that structure, so the
bar overlays scroll content. Mild underlap from the same cause is visible on
the report filter sheet.

## Decisions (Neil, 2026-10-01)

- Workers may be used for self-contained phases (default model).
- **Headers:** inline in-content header matching the template apply sheet is
  the standard; navigation-bar titles are dropped where no back button is
  needed. Pushed pages that need back chrome may use a different header
  treatment (nav title stays acceptable there).
- **Schedules search field:** moves to the top of the list (iOS convention).
- **Saved Filters when unavailable:** default to hiding the
  "Save Current Filters" form entirely (pending override).
- **B2 input affordance:** restyle the editor's text fields with the app's
  rounded control-surface treatment so they read as inputs (the row is
  reachable on device; the earlier "unreachable" reading was a test artifact).
- Commits allowed on the sprint branch `dev/side-by-side` only, never main.

## Phase 0 — Root-cause confirmation (diagnosis only)

- B3 root cause is confirmed (see above): stale demo budget schema +
  `requiredColumns` capability guard + raw error text leaking into the editor
  notice. Remaining diagnosis: determine why the bundled `DemoBudget.zip`
  lacks the new columns (`scripts/generate-demo-budget/generate_demo_budget.py`
  was updated this sprint — check whether the zip was regenerated), and
  whether real server budgets can also lack the columns (write-gating design).
- B1/B2: minimal reproduction comparing `safeAreaBar` in a plain sheet vs a
  NavigationStack + page-fitted sheet, confirming the inset-propagation
  hypothesis before changing code.

## Phase 1 — Blocker fixes (dependency order)

1. **B3 save failure** — three layers:
   a. Regenerate `DemoBudget.zip` so the demo budget carries the current
      schedule schema (`posts_transaction` etc.); verify a created schedule
      persists and the "Schedule Created" confirmation appears.
   b. Pre-gate schedule authoring entry on the schema capability the read path
      already computes (`supportsScheduleRuleEdit`): disable or explain the
      "+" / conversion entries on budgets that cannot support writes, instead
      of failing at save time.
   c. Error hygiene: `unsupportedCapability` and unknown write errors must map
      to tester-voiced notices, never raw SQL text
      ("missing column schedules.posts_transaction").
2. **B1 action-bar overlap** — systemic fix for every sheet using the
   `ReviewSheetContent` + `safeAreaBar` pattern (schedule editor, save review,
   action review, posting review, conversion review, transaction filters,
   saved filters, report filters, account close): opaque bar background plus
   explicit bottom content inset, or an equivalent restructure that keeps the
   master's appearance.
3. **B2 input affordance** — restyle the editor's TextFields (name, amount,
   interval, occurrences) with the app's rounded control-surface treatment
   (as used by the batch category picker search field) so they read as inputs;
   re-verify keyboard behavior after the B1 fix.
4. **B4 identifier masking** — move `.accessibilityIdentifier` off the
   content+bar composite onto the scroll content only; verify the
   `schedule-save-review-button` / `schedule-save-confirm` probes; audit the
   sibling sheets using the same composite pattern.

## Phase 2 — Schedule UI test repair

Drive all five `SchedulesUITests` methods green against the fixed editor.
Only change the tests if a decision above legitimately changes intended
behavior.

## Phase 3 — UI polish (after blockers)

Order:

1. Double headers — remove navigation-bar titles wherever no back button is
   needed; keep nav chrome on pushed pages (filter options, category picker).
2. Batch-family action rows to the master's pattern (small Cancel + wide
   prominent confirm).
3. Duplicate/merge card values right-aligned like the master's label/value
   rows.
4. CSV export: bottom-pinned primary action (keep the toolbar Done).
5. Saved Filters: styled name field matching the app's rounded control
   surfaces; hide the save form when saved filters are unavailable.
6. Reports: title/range consistency, total-value color consistency, drilldown
   tab-bar underlap, title alignment.
7. Schedules list: neutral amount color (white), search field at top.
8. Nit batch: search placeholder contrast, non-money status colors,
   destructive red for delete confirms, account-chip truncation, copy voice,
   report filter dividers.

## Verification

- Failing test first at each seam; focused unit suites per change.
- Schedules UI tests green (Phase 2).
- Re-screenshot every changed sheet and re-review against the master at
  closeout; affected-screen simulator verification per repo policy.
- `scripts/check.sh` before handoff; `TestFlight-Note` trailers per repo
  rules on every tester-visible commit.
