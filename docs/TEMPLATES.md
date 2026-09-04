# Template editor contract and verification

The editor supports the UI-managed Actual 26.8.1 template catalog. Category
long-press, Category Details, and the Settings Templates browser open the same
form. Category-note templates remain read-only; unsupported fields protect the
whole definition from rewriting.

## Ownership

- `BudgetTemplateDraftEditor` owns the normalized list, unfinished input, Notes,
  reference selections, and field/type transitions. Unrelated controls retain
  unfinished text. Only hiding a dependent field or explicitly changing type
  discards that field's input.
- `BudgetTemplateEditorViewModel` owns the session, permissions, Save, and preview
  lifecycle. Preview states distinguish inactive, empty, invalid, editing,
  loading, ready, and failed. Typing invalidates earlier amounts, then waits for
  field completion before requesting a preview. Visible validation waits for
  completion too; Save always checks the current input. Note-only edits leave
  the preview unchanged.
- Shared input views own native keyboard focus and Done, theme tint, and field
  layout. Preview status and Note actions keep stable row space. A repaired date
  retains its text control for the rest of that editor session.
- Money inputs are leading native numeric TextFields with Decimal currency
  FormatStyle (plain number for a currency-neutral budget), locale-aware
  punctuation, and full editing precision even with hidden display fractions.
  Conversion into the existing draft interpreter stays in the view model.
  Total uses the decimal pad; signed fixed adjustments retain the punctuation
  keyboard. Other freeform inputs are leading fields, not trailing labels.
  `BudgetTemplateMoneyFormat` delegates presentation and full-string matching
  to Foundation's localized currency/number FormatStyles. It rejects partial
  numeric matches and stays unpadded during editing so inserted zeros or focus
  changes cannot replace the entered value.
- Budget months display localized month/year names and open two native wheel
  Pickers. `BudgetTemplateEditorMonth` converts selections to existing YYYY-MM
  storage; no day is shown. The year wheel covers 1900 through 100 years ahead,
  expanded to include an existing outlying year. Repetition, priority, and
  historical counts use native Steppers with existing engine bounds. Repeat
  interval and period appear only while Repeats is on. Save and Cancel remain
  in the navigation bar, with no bottom Save action.
- The strict editor codec detects unknown keys before the math decoder can drop
  them. Representable invalid values open for repair. One pure authoring validator
  gates both the form and the SQLite definition-write boundary.
- Save writes only `categories.goal_def` and source metadata through the existing
  CRDT/outbox path, refreshes local state, and never assigns money or records a
  budget History gesture. Apply remains a separate explicit action.
- Editor preview shows unclamped demand. Apply preview follows persisted Apply,
  including currency precision and available-funds clamping.

## Pinned fixtures

`ActualistTests/Fixtures/ActualCore26_8_1/Templates/` contains 44 source-derived
normalization, reducer, and validation cases pinned to commit
`063df03763ca772b51f6264752b88ddec22cfb8a` (`v26.8.1`). The manifest records source,
generator, and fixture hashes. It states the oracle's scope and synthetic date
adapters explicitly; these cases do not claim to execute Actual's money engine.

Regenerate from any Actual checkout containing that commit:

```sh
node scripts/template-parity/generate.mjs /path/to/actual
node scripts/template-parity/generate.mjs /path/to/actual --check
```

The generator reads the pinned git objects, regardless of the checkout's HEAD.
The checked-in results do not require that checkout to run Swift tests or the
mechanical gate. `scripts/check.sh` verifies their provenance and hashes.

## Acceptance suites

- `BudgetTemplateEditorOracleTests`: pinned normalization and transitions,
  validation, and unchanged aggregate demand after legacy normalization.
- `BudgetTemplateEditorRegressionTests`: Total input, invalid/intermediate text,
  dependent-field transitions, stale previews, privacy, repairable definitions,
  signed modifiers, and cancellation.
- `BudgetTemplateEditorInteractionTests`: typing and field completion, deferred
  visible errors, preview request counts, note-only edits, focus reset, and
  saving the current input while a field remains focused. Money presentation
  covers focus/Done, invalid text, privacy, adjustment units, and unchanged
  saved amounts across currency scales and hide-fraction settings.
- `BudgetTemplateEditorPersistenceTests`: cap/Note preservation, Refill + Limit,
  rejected writes with no outbox messages, save/reopen, and actual persisted
  Apply parity for Fill, Overwrite, and Apply Category in envelope/tracking mode
  with USD, JPY, None, and hide-fraction preferences.
- `BudgetTemplateNativeFormTests`: localized currency formatting/parsing,
  numeric saves, privacy, month/year display and storage round trips, invalid
  month repair, existing stepper bounds, and repeat-toggle transitions.
- Existing template, browser, source-lock, store-refresh, preview, and Apply
  suites retain coverage from the original editor rollout.

In Sample Values, amount inputs and Notes are hidden and cannot be edited;
otherwise-permitted definition changes preserve their stored values. Editing
amounts retains currency precision even when display fractions are hidden.

## Simulator visual verification

Use `scripts/run-ios-simulator.sh --boot --demo --screen settings/templates --screenshot`.
The helper targets the pinned simulator throughout and does not need an unlocked
Mac to capture a screen. With an existing selected budget, the demo flag preserves
it; use a known demo simulator for authoring checks. UI tests can open the editor,
enter text, and capture sheets without desktop input.

The category total stays visible. Individual template amounts appear only when
there are multiple contributing templates; Goal and Balance Limit entries do
not count toward that breakdown. Visibility does not change with typed amounts.
Check largest accessibility text as well as standard sizes. Template section
headings stack visible contributions at accessibility sizes, keep the amount on
one line, and scale the multiline Note editor with Dynamic Type.
