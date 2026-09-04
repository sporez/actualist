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
  lifecycle. Preview states distinguish inactive, empty, invalid, loading, ready,
  and failed. A new request immediately invalidates earlier displayed amounts.
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
- `BudgetTemplateEditorPersistenceTests`: cap/Note preservation, Refill + Limit,
  rejected writes with no outbox messages, save/reopen, and actual persisted
  Apply parity for Fill, Overwrite, and Apply Category in envelope/tracking mode
  with USD, JPY, None, and hide-fraction preferences.
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

Check largest accessibility text as well as standard sizes. Template section
headings stack their contribution at accessibility sizes, keep the amount on one
line, and scale the multiline Note editor with Dynamic Type.
