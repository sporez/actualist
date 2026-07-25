# Actualist Remediation Closeout

Reviewed: 2026-07-25

## Conclusion

All numbered code remediations in the work order have landed as independently
bisectable commits. The structural phase is also implemented.

The strengthening work is not literally complete until the physical-device
checks required by items 13, 15, and 16 are performed. Item 19 is intentionally
partial: the app now explains recovery requirements at encrypted-budget entry
points, but the proposed reminder/export product work has not been designed or
implemented. Item 17 remains permissive by design until real-server evidence
supports enforcement.

## Work-order status

| Item | Status | Commit | Verification / remaining boundary |
|---|---|---|---|
| Phase 0 | Done | No commit | The work order records no detected divergence and the corrected collision consequences. |
| 1. Budget paths | Done | `1905f66` | Path, traversal, long-ID, null-byte, and symlink containment tests. |
| 2. Integer operations | Done | `ef235f6` | Boundary and overflow tests; integrated simulator suite. |
| 3. Diagnostic redaction | Done | `c499d08` | Redaction tests and repository-wide sensitive-log sweep. |
| 4. Remote-data quotas | Done | `f41f78b` | Download, archive, ZIP-slip, and sync-response quota tests. |
| 5. Template bounds | Done | `6654c5f` | Invalid values are rejected before persistence; recurrence bounds are tested. |
| 6. Response caching | Done | `5452f83` | Session configuration and credentialed-request cache/cookie tests. |
| 7. Token header | Done | `3a2fd69` | Exact-header regression test. |
| 8. Persistent HLC | Done | `678b1b4` | Concurrent, suspended, and lifecycle timestamp tests. |
| 8a. Superseded writes | Done | `15125f2` | Same-cell collision produces a detectable error. |
| 8b. Rollback handling | Done | `f13be47` | Forced mid-batch failure preserves database and visible state and surfaces the error. |
| 9. Connection staging | Done | `7f62583` | Failure-point tests preserve the working connection and encryption keys. |
| 10. Atomic reimport | Done | `e735215` | Failure injection covers download, decrypt, extract, archive, and schema failures. |
| 11. Background refresh | Done | `50ddad0` | Applied-message ID tracking and bounded-completion tests. |
| 12. Keychain fake | Done | `78d6776` | Full attribute assertions and missing-accessibility rejection. |
| 13. Keychain policy | Partial | `b2dc90d` | Atomic one-way promotion is covered in tests; reboot-cycle verification on a physical device remains required. |
| 14. Local HTTP | Done | `9932823` | Local, tailnet, IPv6, hostname, and non-local rejection tests. |
| 15. File protection | Partial | `2469a26` | Idempotent hardening and sidecar coverage are tested; effective protection and backup values still require physical-device inspection. |
| 16. Snapshot cover | Partial | `645147f` | Mode/state policy is tested; the work order's app-switcher thumbnail matrix still requires physical-device observation. |
| 17. Plaintext envelopes | Done as scoped | `7e26ade` | Mixed-envelope allow/log and reject-mode tests. Enforcement intentionally remains off pending field evidence. |
| 18. Backup decision | Done | `6425998` | The pending-outbox loss tradeoff is documented in `README.md`. |
| 19. Restore path | Partial | `535600f` | Onboarding and budget-switch flows explain that the password and device-bound key are not recoverable. Reminder cadence, a permanent Settings recovery note, and manual export remain product follow-ups. |
| 20. Template engine | Done | `d777826` | Pure `BudgetTemplateEngine` extraction with focused tests and integrated simulator verification. |

## Structural maintainability review

The app no longer contains any multi-thousand-line production Swift files.
Large screen files and the local-first store suite were divided at
responsibility boundaries:

- `BudgetView.swift`: 2,234 to 543 lines. Selection sheets, rows, move-money UI,
  assignment keypad, and shared infrastructure now have dedicated files.
- `SettingsView.swift`: 1,673 to 755 lines. Diagnostics, budget selection,
  account ordering, and appearance UI now have dedicated files.
- `AccountTransactionsView.swift`: 1,208 to under 1,000 lines. Category-month
  state/presentation and the Spending entry screen are separate.
- `LocalFirstActualStoreTests.swift`: 4,751-line mixed suite replaced by a
  25-line suite declaration, seven subsystem files, and shared test support.
  Every subsystem file is below 900 lines.

Three production files remain above 1,000 lines:

| File | Lines at review | Assessment |
|---|---:|---|
| `BudgetViewModel.swift` | 1,224 | Contains loading, alert, assignment, template, and move-money workflows. A file-extension split would expose private state without improving ownership. The maintainable next step is a composed move-money or assignment state object with its own tests. |
| `TransactionEditorViewModel.swift` | 1,108 | One tightly coupled editor state machine. Moving declarations alone would lower the count without lowering complexity. Extract pure draft-building and split-allocation collaborators only when their contracts are covered directly. |
| `AppState.swift` | 1,073 | The strongest remaining architectural candidate. Background refresh and notification delivery should become collaborators rather than cross-file extensions that still depend on AppState internals. This deserves a separately scoped behavioral refactor. |

These are large, but none is currently a multi-thousand-line file. Line count
alone should not trigger another split; the next changes should reduce state
ownership and coupling, not only move code between files.

Two test files also remain above 1,000 lines:
`TransactionEditorViewModelTests.swift` (1,525) and
`BudgetViewModelTests.swift` (1,224). They mirror the two cohesive feature state
machines above. Partition them alongside future collaborator extractions so the
test file boundaries describe the resulting production responsibilities,
rather than creating arbitrary test-only groupings now.
