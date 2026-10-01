#!/usr/bin/env python3
"""Fake-only, bounded diagnostic for the CSV stage deadline coordinator."""

import datetime
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time
import uuid

import orchestrate


ROOT = orchestrate.ROOT
ARTIFACTS = ROOT / ".artifacts"
DIAGNOSTIC_SECONDS = 28.0
STAGE_CAP_SECONDS = 16.0
LATE_STAGE_REMAINDER_SECONDS = 14.0
FAKE_ENV = {"PATH": "/usr/bin:/bin"}


class DiagnosticFailure(Exception):
    pass


started_signal = None


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def atomic_json(path, value):
    temporary = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def read_json(path):
    if path.is_symlink() or not path.is_file():
        raise DiagnosticFailure(f"expected evidence file missing or symlinked: {path}")
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def create_output_root():
    if not ARTIFACTS.is_dir() or ARTIFACTS.is_symlink():
        raise DiagnosticFailure("DEV .artifacts must already be a real directory")
    if os.path.realpath(ROOT) != str(ROOT) or os.path.realpath(ARTIFACTS) != str(ARTIFACTS):
        raise DiagnosticFailure("DEV diagnostic path has a symlinked ancestor")
    output = ARTIFACTS / f"csv-export-interop-diagnostic-{uuid.uuid4()}"
    os.mkdir(output, 0o700)
    os.chmod(output, 0o700)
    metadata = output.lstat()
    if stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise DiagnosticFailure("diagnostic root is not an exclusive mode-0700 directory")
    identity = (metadata.st_dev, metadata.st_ino)
    for name in ("logs", "receipts"):
        os.mkdir(output / name, 0o700)
    return output, identity


def verify_output(output, identity):
    metadata = output.lstat()
    if stat.S_ISLNK(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != identity:
        raise DiagnosticFailure("diagnostic output identity changed")


def verify_reaped_receipt(output, stage_name, *, expected_supervisor_exit, require_payload_log=True):
    receipt_path = output / "receipts" / f"{stage_name}.json"
    owner_path = output / "receipts" / f"{stage_name}-owner.json"
    receipt = read_json(receipt_path)
    owner = read_json(owner_path)
    if owner.get("state") != "supervisor-exited" or owner.get("supervisorExitCode") != expected_supervisor_exit:
        raise DiagnosticFailure(f"stage supervisor was not reaped with an owner receipt: {stage_name}")
    supervisor_pid = owner.get("supervisorPID")
    if not isinstance(supervisor_pid, int) or owner.get("supervisorPGID") != supervisor_pid:
        raise DiagnosticFailure(f"stage owner receipt lacks its exact supervisor identity: {stage_name}")
    if group_exists(supervisor_pid):
        raise DiagnosticFailure(f"recorded fake supervisor group remains: {supervisor_pid}")
    payload_pgid = receipt.get("ownedProcessGroup")
    if receipt.get("processGroupQuiescent") is True:
        if not isinstance(payload_pgid, int) or group_exists(payload_pgid):
            raise DiagnosticFailure(f"recorded fake payload group was not reaped: {stage_name}")
    # A synthetic supervisor replacing the production one runs no payload through
    # the production logging path, so only production-driven stages own a log.
    if require_payload_log and not (output / "logs" / f"{stage_name}.log").is_file():
        raise DiagnosticFailure(f"stage payload log missing: {stage_name}")
    if not (output / "logs" / f"{stage_name}-supervisor.log").is_file():
        raise DiagnosticFailure(f"stage supervisor log missing: {stage_name}")
    return receipt, owner


def verify_stage_budget(receipt, owner, *, cap, expected_total_capped):
    effective = receipt.get("timeoutSecondsInclusive")
    cleanup = receipt.get("cleanupReserveSeconds")
    receipt_reserve = receipt.get("receiptReserveSeconds")
    execution = receipt.get("executionBudgetSeconds")
    if not all(isinstance(value, (int, float)) for value in (effective, cleanup, receipt_reserve, execution)):
        raise DiagnosticFailure("stage receipt is missing monotonic budget fields")
    if cleanup != orchestrate.STAGE_CLEANUP_RESERVE_SECONDS or receipt_reserve != 1.0:
        raise DiagnosticFailure("stage cleanup/receipt reserves changed unexpectedly")
    if execution + cleanup > effective + 0.002 or receipt_reserve > cleanup:
        raise DiagnosticFailure("execution, cleanup and receipt exceed the stage budget")
    if receipt.get("effectiveDeadlineMonotonic") > receipt.get("sharedDeadlineMonotonic"):
        raise DiagnosticFailure("stage deadline exceeded the shared total deadline")
    if abs(owner.get("stageDeadlineMonotonic") - owner.get("supervisorDeadlineMonotonic") - 1.0) > 0.002:
        raise DiagnosticFailure("outer supervisor-reap reserve is not inside the stage cap")
    if expected_total_capped:
        if owner.get("stageDeadlineMonotonic") != owner.get("sharedDeadlineMonotonic"):
            raise DiagnosticFailure("remaining-total cap did not win min(stage, remaining total)")
        if effective >= cap:
            raise DiagnosticFailure("remaining-total cap was not narrower than the stage cap")
    else:
        if owner.get("stageDeadlineMonotonic") >= owner.get("sharedDeadlineMonotonic"):
            raise DiagnosticFailure("stage cap did not win while total time remained")
        if effective >= cap:
            raise DiagnosticFailure("stage cap was not reflected in the effective stage budget")


def expect_rejected_stage(output, identity, overall_deadline, stage_name, command,
                          *, next_stage_marker, supervisor_path=None):
    old_supervisor = orchestrate.SUPERVISOR
    if supervisor_path is not None:
        orchestrate.SUPERVISOR = supervisor_path
    try:
        try:
            orchestrate.run_stage(
                output=output,
                identity=identity,
                overall_deadline=overall_deadline,
                stage_name=stage_name,
                cap=STAGE_CAP_SECONDS,
                termination="group",
                command=command,
                env=FAKE_ENV,
                cwd=ROOT,
            )
        except orchestrate.RunFailure:
            return
        next_stage_marker.write_text("unexpected next-stage invocation\n", encoding="utf-8")
        raise DiagnosticFailure(f"{stage_name} was accepted despite a fake failure/unresolved receipt")
    finally:
        orchestrate.SUPERVISOR = old_supervisor


def signal_handler(signum, _frame):
    global started_signal
    started_signal = signum
    orchestrate.pending_signal = signum


def check_budget(deadline, reserve=1.0):
    if started_signal is not None:
        raise DiagnosticFailure(f"diagnostic interrupted by signal {started_signal}")
    if time.monotonic() + reserve >= deadline:
        raise DiagnosticFailure("28-second diagnostic budget reserve exhausted")


def main():
    started = time.monotonic()
    overall_deadline = started + DIAGNOSTIC_SECONDS
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, signal_handler)

    output = None
    identity = None
    report = {
        "schema": 1,
        "state": "running",
        "startedAt": utc_now(),
        "fakeBudgetSeconds": DIAGNOSTIC_SECONDS,
        "productionBudgetSeconds": orchestrate.TOTAL_SECONDS,
        "payloads": "Python-only fake commands; no production stages",
        "cleanupPolicy": "retain every diagnostic artifact; remove nothing",
        "checks": {},
    }
    exit_code = 1
    try:
        if orchestrate.TOTAL_SECONDS != 1440.0:
            raise DiagnosticFailure("production total deadline is no longer 1,440 seconds")
        output, identity = create_output_root()
        report["artifactRoot"] = str(output)
        report_path = output / "diagnostic-report.json"
        for dirname in ("logs", "receipts"):
            verify_output(output, identity)
            if not (output / dirname).is_dir():
                raise DiagnosticFailure(f"diagnostic evidence directory missing: {dirname}")
        atomic_json(report_path, report)

        # Stage-cap branch: a real fake payload runs under the production supervisor.
        before_cap_stage = time.monotonic()
        cap_receipt = orchestrate.run_stage(
            output=output,
            identity=identity,
            overall_deadline=overall_deadline,
            stage_name="fake-stage-cap",
            cap=STAGE_CAP_SECONDS,
            termination="group",
            command=[sys.executable, "-c", "raise SystemExit(0)"],
            env=FAKE_ENV,
            cwd=ROOT,
        )
        cap_receipt, cap_owner = verify_reaped_receipt(
            output, "fake-stage-cap", expected_supervisor_exit=0
        )
        verify_stage_budget(cap_receipt, cap_owner, cap=STAGE_CAP_SECONDS, expected_total_capped=False)
        if cap_receipt.get("outcome") != "passed" or cap_receipt.get("processGroupQuiescent") is not True:
            raise DiagnosticFailure("successful fake stage did not prove exact payload-group quiescence")
        if cap_owner["stageDeadlineMonotonic"] - before_cap_stage > STAGE_CAP_SECONDS + 0.1:
            raise DiagnosticFailure("stage-cap branch exceeded its monotonic cap")
        report["checks"]["stageLimitWins"] = True
        report["fakeStageCapReceipt"] = "receipts/fake-stage-cap.json"
        report["fakeStageCapOwnerReceipt"] = "receipts/fake-stage-cap-owner.json"

        # Timeout branch: the real helper must TERM/CONT/KILL only its fake PGID,
        # confirm that group is gone, and write its receipt inside the budget.
        timeout_name = "fake-stage-timeout"
        next_after_timeout = output / "receipts/next-after-timeout.json"
        expect_rejected_stage(
            output, identity, overall_deadline, timeout_name,
            [sys.executable, "-c", "import time; time.sleep(30)"],
            next_stage_marker=next_after_timeout,
        )
        timeout_receipt, timeout_owner = verify_reaped_receipt(
            output, timeout_name, expected_supervisor_exit=124
        )
        if timeout_receipt.get("outcome") != "timed-out" or timeout_receipt.get("processGroupQuiescent") is not True:
            raise DiagnosticFailure("timed-out fake payload group was not confirmed quiescent")
        if group_exists(timeout_receipt["ownedProcessGroup"]):
            raise DiagnosticFailure("timed-out fake payload process group remains")
        if next_after_timeout.exists():
            raise DiagnosticFailure("a fake later stage ran after timeout")
        verify_stage_budget(timeout_receipt, timeout_owner, cap=STAGE_CAP_SECONDS,
                            expected_total_capped=False)
        report["checks"]["timeoutCleanupAndReceipt"] = True
        report["checks"]["timeoutStopsSequence"] = True
        report["fakeTimeoutReceipt"] = "receipts/fake-stage-timeout.json"

        # A normal nonzero fake payload must fail closed; the following stage is
        # deliberately represented by a marker that must remain absent.
        failure_name = "fake-stage-failure"
        next_after_failure = output / "receipts/next-after-failure.json"
        expect_rejected_stage(
            output, identity, overall_deadline, failure_name,
            [sys.executable, "-c", "raise SystemExit(7)"],
            next_stage_marker=next_after_failure,
        )
        failure_receipt, failure_owner = verify_reaped_receipt(
            output, failure_name, expected_supervisor_exit=7
        )
        if failure_receipt.get("outcome") != "failed" or failure_receipt.get("processGroupQuiescent") is not True:
            raise DiagnosticFailure("fake nonzero stage receipt did not preserve its failure/quiescence")
        if next_after_failure.exists():
            raise DiagnosticFailure("a fake later stage ran after failure")
        report["checks"]["failureStopsSequence"] = True
        report["fakeFailureReceipt"] = "receipts/fake-stage-failure.json"

        # Inject only a synthetic unresolved receipt from a tiny fake supervisor.
        # The fake supervisor itself must still be reaped; no payload is left alive.
        unresolved_script = output / "fake-unresolved-supervisor.py"
        unresolved_script.write_text(
            "import json, sys\n"
            "args = sys.argv\n"
            "receipt = args[args.index('--receipt') + 1]\n"
            "stage = args[args.index('--stage') + 1]\n"
            "with open(receipt, 'x', encoding='utf-8') as handle:\n"
            "    json.dump({'schema': 1, 'stage': stage, 'outcome': 'passed', "
            "'exitCode': 0, 'processGroupQuiescent': False}, handle)\n",
            encoding="utf-8",
        )
        unresolved_name = "fake-stage-unresolved"
        next_after_unresolved = output / "receipts/next-after-unresolved.json"
        expect_rejected_stage(
            output, identity, overall_deadline, unresolved_name,
            [sys.executable, "-c", "raise SystemExit(0)"],
            next_stage_marker=next_after_unresolved,
            supervisor_path=unresolved_script,
        )
        unresolved_receipt, unresolved_owner = verify_reaped_receipt(
            output, unresolved_name, expected_supervisor_exit=0, require_payload_log=False
        )
        if unresolved_receipt.get("processGroupQuiescent") is not False:
            raise DiagnosticFailure("synthetic unresolved receipt was not preserved")
        if next_after_unresolved.exists():
            raise DiagnosticFailure("a fake later stage ran after unresolved quiescence")
        report["checks"]["unresolvedQuiescenceStopsSequence"] = True
        report["checks"]["syntheticUnresolvedHasNoLivePayload"] = True
        report["fakeUnresolvedReceipt"] = "receipts/fake-stage-unresolved.json"
        report["fakeUnresolvedOwnerReceipt"] = "receipts/fake-stage-unresolved-owner.json"

        # Delay only the driver, then demonstrate min(stage limit, remaining total)
        # with just over the production supervisor's minimum viable reserve.
        late_start = overall_deadline - LATE_STAGE_REMAINDER_SECONDS
        if time.monotonic() < late_start:
            time.sleep(late_start - time.monotonic())
        check_budget(overall_deadline, MINIMUM_FINAL_STAGE_REMAINDER)
        total_capped = orchestrate.run_stage(
            output=output,
            identity=identity,
            overall_deadline=overall_deadline,
            stage_name="fake-stage-total-cap",
            cap=20.0,
            termination="group",
            command=[sys.executable, "-c", "raise SystemExit(0)"],
            env=FAKE_ENV,
            cwd=ROOT,
        )
        total_receipt, total_owner = verify_reaped_receipt(
            output, "fake-stage-total-cap", expected_supervisor_exit=0
        )
        verify_stage_budget(total_receipt, total_owner, cap=20.0, expected_total_capped=True)
        if total_receipt.get("outcome") != "passed" or total_receipt.get("processGroupQuiescent") is not True:
            raise DiagnosticFailure("remaining-total-capped fake stage did not finish cleanly")
        report["checks"]["remainingTotalWins"] = True
        report["fakeTotalCapReceipt"] = "receipts/fake-stage-total-cap.json"
        report["fakeTotalCapOwnerReceipt"] = "receipts/fake-stage-total-cap-owner.json"

        check_budget(overall_deadline, 1.0)
        verify_output(output, identity)
        report.update({
            "state": "passed",
            "completedAt": utc_now(),
            "durationSeconds": round(time.monotonic() - started, 3),
            "allArtifactsRetained": True,
            "realProcessesLeft": False,
        })
        atomic_json(report_path, report)
        print(f"Fake-only diagnostic evidence: {report_path}")
        exit_code = 0
    except BaseException as error:
        report.update({
            "state": "blocked",
            "failure": f"{type(error).__name__}: {error}",
            "completedAt": utc_now(),
            "durationSeconds": round(time.monotonic() - started, 3),
            "allArtifactsRetained": True,
        })
        if output is not None:
            try:
                atomic_json(output / "diagnostic-report.json", report)
            except OSError:
                pass
        print(f"Fake-only diagnostic blocked; retain evidence at {output}: {report['failure']}", file=sys.stderr)
        exit_code = 1
    return exit_code


MINIMUM_FINAL_STAGE_REMAINDER = orchestrate.MIN_STAGE_REMAINDER_SECONDS + 1.5


if __name__ == "__main__":
    sys.exit(main())
