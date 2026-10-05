# D0 encrypted new-file registration: source result and corrected oracle proposal

Date: 2026-09-27 (accepted upstream packet); copied to DEV for local review  
Mode: source inspection and artifact-only static authoring  
Pinned upstream: `$ACTUALIST_PARITY_ORACLE_ROOT`\
Revision: `59fe126f637d858c061e1eeedbef5436c8f2225a`

No runtime, build, typecheck, test, Node process, server request, network access,
credential retrieval, Xcode action, production edit, or commit was performed.
The coordinator remains the sole possible runtime owner.

## Source-supported conclusion

Pinned source supports this reachable new-file state:

1. `/upload-user-file` accepts encrypted ZIP bytes plus whole-file encryption
   metadata for a new generated file ID and creates a fresh group
   (`packages/sync-server/src/app-sync.ts:298-410`).
2. The new row initially has `encrypt_keyid = null`; the constructor default is
   null (`app-sync/services/files-service.ts:41-80`).
3. The owner can then call `/user-create-key` for that existing file, storing the
   matching key ID, salt, and encrypted password-test content without resetting
   the group or rewriting the uploaded bytes (`app-sync.ts:232-259`).
4. Sync accepts the resulting state only when uploaded metadata key, registered
   key, request key, and group match
   (`app-sync/validation.js:7-46`).
5. Official clients obtain registered key data, derive PBKDF2-SHA512/10,000
   keys, validate the password test, and decrypt AES-256-GCM file metadata
   (`loot-core/src/server/encryption/app.ts:55-123`,
   `encryption-internals.electron.ts:6-48,73-88`, and
   `cloud-storage.ts:444-505`).

Important qualification: `/user-create-key` blindly stores caller-provided key
metadata. It does not prove that the password-test ciphertext or key matches the
already uploaded blob. Source therefore proves only that a caller supplying
matching values can construct a consistent state. The corrected oracle requires
an official correct-password unlock/download immediately after registration and
before any same-ID/group re-upload.

The pinned checkout proves what revision `59fe126f` implements locally. It does
not prove that the disposable remote server runs that same revision. Runtime
evidence must record the server's separately observed version rather than label
remote behavior as pinned solely from this source checkout.

The official product UI still uses plaintext upload → loaded file → reset/key
registration → encrypted re-upload. `encryption/app.ts:23-29` explicitly says
onboarding encryption is not supported, and `sync/reset.ts:25-80` implements the
reset/re-upload flow. That is the official product path, not a server-protocol
requirement for a new file.

## Retry finding

If a successful new-file upload response is lost, repeating the request without
the returned group is rejected as `file-has-reset`; it does not recover the
group. Correct recovery retains the pre-generated file ID, lists that known ID,
obtains its group, and then continues with the same identity. Generating a new
file ID on uncertainty risks a duplicate budget.

The oracle intentionally discards the first upload response body. It does not
claim to induce a real transport cut. It then:

- confirms a groupless same-ID retry is rejected;
- recovers the group solely from listing by the durably receipted file ID; and
- independently checks exactly one live match by generated ID, exact run name,
  and recovered group.

The same independent singularity check applies to the official starter case.

## Corrected one-run, four-case investigation

One Vitest test executes four cases serially and stops on the first failed
acceptance condition. It has no automatic rerun and no fallback protocol:

1. **Synthetic starter source** — create Actual's pinned starter offline, assert
   three starter groups, seven categories, and zero accounts; make one synthetic
   account/transaction first write; record the ordered group/category-name
   projection without transient IDs; durably save and hash the exported ZIP.
2. **Unencrypted new identity** — use its pre-generated/durably receipted file
   ID; discard the first response body; recover solely by listing; prove
   independent ID/name/group singularity, a same-ID/group retry, official reload,
   and one mutation in each direction between official clients.
3. **Direct encrypted new identity** — durably stage encrypted bytes and the
   generated file/key/salt/test/upload metadata before mutation; discard the
   first response body and recover by known ID; compare exact key ID, algorithm,
   IV, and auth tag from `/get-user-file-info` before and after key registration;
   require fresh-directory missing-password and wrong-password failures; then
   require a correct official unlock/download **before** same-ID/group re-upload
   and bidirectional peer writes.
4. **Official fresh starter** — create the starter offline, pre-generate and
   atomically persist its cloud file ID in both the ownership receipt and local
   metadata, then invoke the official `upload-budget` handler. This avoids the
   normal `create-budget` handler's swallowed upload failure without introducing
   a server lease. Prove ID/name/group singularity, first account/starting-balance
   sync, and fresh official reload.

This remains a bounded registration oracle, not full D4 acceptance. It does not
test the unimplemented Actualist coordinator, imported local-ID regeneration,
ZIP hardening, every crash phase, Actualist export, or user-facing recovery.

## Process-singleton limitation

Every official API client uses a fresh exclusive data directory, but all clients
run in one Vitest process and share Actual's module singleton. `api.shutdown()`
does not unload encryption keys. Missing-password validation still occurs before
download, and wrong-password `key-test` rejects/unloads its candidate key, but
this is not process isolation. The result may establish official API
interoperability in this harness; it must not be described as independent-process
or separate-device proof.

## Resolution and finite ceilings

- `oracle-setup.ts` installs the global fetch wrapper before the API test module
  imports Actual. It combines any existing request signal with
  `AbortSignal.timeout`; it never replaces an existing signal.
- Per-request ceiling: **15 seconds**.
- Investigation fetch deadline: **180 seconds** from setup start.
- Cleanup fetch deadline: **225 seconds** from setup start. This provides **up
  to 45 seconds** after an investigation fetch reaches its deadline, but it is
  shorter—or may be skipped—if local API, filesystem, or SQLite work stalls past
  180 seconds.
- Vitest test ceiling: **240 seconds**.
- Outer runner sends TERM at **290 seconds** and allows at most **10 seconds**
  before KILL, preserving a **300-second hard ceiling**.
- The runner establishes and verifies a distinct child process group and signals
  only that exact group. Guarded PID/PGID state, EXIT/HUP/INT/TERM traps, and the
  termination/reap function are installed before launch. A launch-pending state
  is persisted before spawning; if a signal arrives before normal assignment,
  the EXIT guard recovers the sole permitted provisional job from `$!` or a
  one-job `jobs -p` fallback. `jobs -p` deliberately includes running and
  stopped jobs. A pre-child signal performs no empty-PID wait.
  Failed post-launch verification terminates and reaps that exact provisional
  group. The EXIT guard remains active through normal reap. It uses no broad
  kill, simulator action, shared lock framework, or retry.
- Watchdog and grace checks treat both running and stopped states as active. TERM
  is followed by CONT so a stopped exact group can observe TERM; if it remains
  active through grace, KILL targets only that group. A stopped-status `wait`
  never marks the child reaped: the runner KILLs the exact group, waits again,
  and marks reaped only after the owned job is no longer active.
- API source resolution mirrors the pinned API Vite config's `api` conditions,
  `ssr.noExternal`, and `better-sqlite3` external setting. The filesystem shim
  alias is an exact regular expression, so it cannot rewrite
  `#platform/server/fs/path-join`.

The 300-second outer ceiling is the only hard whole-process bound. Vitest's
timeout does not force cancellation or guarantee `finally` cleanup. If local
work stalls, the outer runner may terminate the exact child group before cleanup
starts or finishes. The already-durable ownership receipt supports deliberate
recovery; it is not proof that cleanup occurred. Such a run is incomplete and
cannot be treated as acceptance.

## Durable evidence and cleanup

Before any remote mutation the harness:

1. exclusively creates a new run root (`recursive: false`);
2. captures all baseline remote file IDs;
3. pre-generates three distinct candidate file IDs; and
4. atomically writes and fsyncs `ownership-receipt.json` with the baseline and
   operations.

Phase transitions, recovered groups, encrypted registration inputs, and failures
are atomically persisted before cleanup. `result.json` is redacted and excludes
server URL, token, passwords, IDs, groups, key IDs, and financial values. The
mode-`0600` ownership receipt necessarily contains synthetic IDs and encrypted
registration metadata, but no endpoint, token, password, or plaintext budget
values. Synthetic API client data and ZIP/ciphertext staging remain inside the
exclusive mode-`0700` run directory.

Cleanup never infers ownership from a name. It considers only pre-generated IDs
that were absent from the durable baseline. Before deleting a known ID it checks
that exactly one live row has that ID, exactly one has the exact run name, and—if
recovered—exactly one has its group, all referring to the same row. Any mismatch
is atomically recorded as ambiguous and left untouched. Confirmed owned deletions
are individually verified. Cleanup ambiguity or failure leaves the run failed.

## Exact proposed invocation — not run

Credentials must already exist only in the coordinator-owned environment. Do
not place values in the script, command history, logs, or evidence.

```sh
export ACTUAL_ORACLE_SERVER_URL
export ACTUAL_ORACLE_SERVER_PASSWORD
export ACTUAL_ORACLE_ENCRYPTION_PASSWORD
export ACTUAL_ORACLE_RUN_ID="d0-$(date -u +%Y%m%dT%H%M%SZ)"
export ACTUAL_ORACLE_CLEANUP=1
export ACTUALIST_PARITY_ORACLE_ROOT  # pinned Actual v26.9.0 checkout

scripts/parity/d0-source-approved/run-oracle-proposal.sh
```

Expected success is one serial passing test, four passing cases, three singular
new remote identities, missing/wrong-password rejection, correct encrypted
unlock before retry, bidirectional official peer writes, starter first-write
reload, three confirmed owned deletions, zero ambiguities, a redacted
`result.json`, and a durable private ownership receipt. Any failed condition
stops later cases. Finally cleanup is attempted with whatever time remains before
the cleanup-fetch and hard process ceilings; durable receipts preserve recovery
inputs when cleanup is shortened or preempted.

## Files

- `D0-encrypted-registration-follow-up.md` — this source/result boundary.
- `run-oracle-proposal.sh` — pinned preflight, exact-child watchdog, and command.
- `oracle.vitest.config.ts` — pinned API SSR resolution and one-test serial limit.
- `oracle-setup.ts` — pre-import combined-signal finite fetch wrapper.
- `oracle-fs-shim.ts` — pinned source migration/default-DB locations.
- `zip-registration-oracle.test.ts` — four cases, durable receipts, assertions,
  and constrained cleanup.

The source-approved packet was copied from
the sprint-integration checkout's
`.artifacts/parity-sprint-20260927/zip-registration-research/`.
In this DEV copy, the runner/config resolve this checkout's `scripts/parity`
from their own location, read the pinned upstream from
`ACTUALIST_PARITY_ORACLE_ROOT`, and confine evidence/cache output to this
checkout's `.artifacts/parity-sprint-20260927/d0-source-approved/`. These
path adaptations change packet hashes; compare `source-approved-hashes.json`
with coordinator-approved hashes and review the DEV-only changes before any
execution. Original evidence/worktrees remain read-only. This DEV packet itself
has not been typechecked or executed.

## Remaining product fork

If the direct encrypted case passes, the coordinator still needs the product
decision: admit encrypted upload → durable receipt → key registration → official
reload, or require Actual's longer plaintext-first reset/re-upload product flow.
If it fails, encrypted D4 remains blocked; this same run must not silently execute
an unapproved fallback.
