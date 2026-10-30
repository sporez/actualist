# Template note parity harness

`generate.mjs` runs Actual's pinned `storeNoteTemplates` on a real test database
for each note below and records what it stores. It writes
`template-note-contract.json` and `template-note-manifest.json` into
`ActualistTests/Fixtures/ActualCore26_10_0/TemplateNotes/`.

`TemplateNoteOracleReplayTests` replays every case through
`BudgetTemplateNoteParser`, the guard that keeps a stale note-managed definition
from being applied.

## Cases

- **Forms.** One note. The guard must accept the definition Actual stores for it,
  including an error entry for a line Actual's grammar rejects.
- **Changes.** A definition stored from one note, then a different note. `stale`
  is true when Actual would store something that behaves differently. A
  description is display text and an error entry never applies, so neither counts.

Every expected value comes from running Actual. Add a form or a change to the
lists in `generate.mjs`, regenerate, and replay. Do not edit the fixture by hand.

## Commands

```sh
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/template-note-parity/generate.mjs
ACTUALIST_PARITY_ORACLE_ROOT=<pinned-actual> node scripts/template-note-parity/generate.mjs --check
node scripts/template-note-parity/verify.mjs
```

The generator writes a temporary runner into the oracle checkout and removes it
afterwards. `verify.mjs` needs no oracle.
