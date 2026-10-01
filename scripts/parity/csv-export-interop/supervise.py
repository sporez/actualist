#!/usr/bin/env python3
"""Bound one CSV workflow stage by its local and shared monotonic deadlines."""

import argparse
import datetime
import json
import os
import signal
import subprocess
import sys
import time


CLEANUP_RESERVE_SECONDS = 10.0
RECEIPT_RESERVE_SECONDS = 1.0


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_receipt(path, receipt):
    temporary = f"{path}.tmp-{os.getpid()}"
    with open(temporary, "x", encoding="utf-8") as handle:
        json.dump(receipt, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)


def process_group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def signal_exact_group(pgid, signum):
    try:
        os.killpg(pgid, signum)
        return True
    except ProcessLookupError:
        return False


def wait_for_group_exit(process, pgid, deadline):
    while process_group_exists(pgid) and time.monotonic() < deadline:
        process.poll()
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    process.poll()
    return not process_group_exists(pgid)


def terminate_exact_group(process, pgid, deadline):
    if not process_group_exists(pgid):
        process.poll()
        return True
    signal_exact_group(pgid, signal.SIGTERM)
    signal_exact_group(pgid, signal.SIGCONT)
    kill_deadline = max(time.monotonic(), deadline - 2.0)
    if wait_for_group_exit(process, pgid, kill_deadline):
        return True
    signal_exact_group(pgid, signal.SIGKILL)
    return wait_for_group_exit(process, pgid, deadline)


def wait_for_leader(process, deadline):
    remaining = max(0.0, deadline - time.monotonic())
    try:
        return process.wait(timeout=remaining), True
    except subprocess.TimeoutExpired:
        return None, False


def signal_exact_process(process, signum):
    try:
        process.send_signal(signum)
        return True
    except ProcessLookupError:
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", required=True)
    parser.add_argument("--timeout", required=True, type=float)
    parser.add_argument("--deadline-monotonic", required=True, type=float)
    parser.add_argument("--stage-deadline-monotonic", required=True, type=float)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--termination", required=True, choices=("owner", "group"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command[1:] if arguments.command[:1] == ["--"] else arguments.command
    if not command:
        parser.error("a command is required after --")
    if arguments.timeout <= CLEANUP_RESERVE_SECONDS + RECEIPT_RESERVE_SECONDS:
        parser.error("timeout must exceed cleanup and receipt reserves")

    started_at = utc_now()
    started = time.monotonic()
    local_deadline = started + arguments.timeout
    hard_deadline = min(
        local_deadline,
        arguments.deadline_monotonic,
        arguments.stage_deadline_monotonic,
    )
    effective_seconds = hard_deadline - started
    if effective_seconds <= CLEANUP_RESERVE_SECONDS + RECEIPT_RESERVE_SECONDS:
        parser.error("shared deadline leaves no bounded execution window")
    execution_deadline = hard_deadline - CLEANUP_RESERVE_SECONDS
    cleanup_deadline = hard_deadline - RECEIPT_RESERVE_SECONDS
    receipt = {
        "schema": 2,
        "stage": arguments.stage,
        "command": command,
        "cwd": arguments.cwd,
        "stageCapSeconds": arguments.timeout,
        "timeoutSecondsInclusive": round(effective_seconds, 3),
        "sharedDeadlineMonotonic": arguments.deadline_monotonic,
        "stageDeadlineMonotonic": arguments.stage_deadline_monotonic,
        "effectiveDeadlineMonotonic": hard_deadline,
        "executionBudgetSeconds": round(max(0.0, execution_deadline - started), 3),
        "cleanupReserveSeconds": CLEANUP_RESERVE_SECONDS,
        "receiptReserveSeconds": RECEIPT_RESERVE_SECONDS,
        "startedAt": started_at,
        "supervisorPID": os.getpid(),
        "phase": "starting",
        "outcome": "running",
    }
    process = None
    exit_code = 1
    interrupted_signal = None

    def interrupt(signum, _frame):
        nonlocal interrupted_signal
        interrupted_signal = signum
        raise InterruptedError(f"received signal {signum}")

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupt)

    write_receipt(arguments.receipt, receipt)
    with open(arguments.log, "xb", buffering=0) as log:
        try:
            if time.monotonic() >= execution_deadline:
                raise TimeoutError("no execution window remains")
            process = subprocess.Popen(
                command,
                cwd=arguments.cwd,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            receipt.update({"phase": "running", "pid": process.pid,
                            "ownedProcessGroup": process.pid})
            write_receipt(arguments.receipt, receipt)
            leader_status, leader_exited = wait_for_leader(process, execution_deadline)

            if arguments.termination == "owner":
                receipt["simulatorHostAuditRequired"] = True
                if leader_exited:
                    receipt["wrapperExited"] = True
                    receipt["wrapperExitCode"] = leader_status
                    if leader_status == 0:
                        receipt["outcome"] = "passed"
                        receipt["payloadStatus"] = "wrapper-exited"
                        exit_code = 0
                    else:
                        receipt["outcome"] = "failed"
                        receipt["payloadStatus"] = "unverified-after-wrapper-failure"
                        receipt["testLockRecoveryRequired"] = True
                        exit_code = leader_status
                else:
                    receipt["outcome"] = "timed-out"
                    receipt["payloadStatus"] = "unknown"
                    receipt["testLockRecoveryRequired"] = True
                    signal_exact_process(process, signal.SIGTERM)
                    wrapper_status, wrapper_exited = wait_for_leader(process, cleanup_deadline)
                    if not wrapper_exited:
                        signal_exact_process(process, signal.SIGKILL)
                        wrapper_status, wrapper_exited = wait_for_leader(process, cleanup_deadline)
                    receipt["wrapperExited"] = wrapper_exited
                    if wrapper_exited:
                        receipt["wrapperExitCode"] = wrapper_status
                    receipt["simulatorHostQuiescence"] = "unresolved; main-owner audit required"
                    exit_code = 124 if wrapper_exited else 125
            else:
                if leader_exited and not process_group_exists(process.pid):
                    receipt["outcome"] = "passed" if leader_status == 0 else "failed"
                    receipt["processGroupQuiescent"] = True
                    exit_code = leader_status
                else:
                    receipt["outcome"] = "timed-out" if not leader_exited else "failed-nonquiescent"
                    receipt["phase"] = "group-cleanup"
                    receipt["processGroupQuiescent"] = terminate_exact_group(
                        process, process.pid, cleanup_deadline
                    )
                    if not leader_exited:
                        leader_status, leader_exited = wait_for_leader(process, cleanup_deadline)
                    receipt["leaderExited"] = leader_exited
                    exit_code = 124 if receipt["processGroupQuiescent"] and receipt["outcome"] == "timed-out" else (
                        1 if receipt["processGroupQuiescent"] else 125
                    )
        except BaseException as error:
            receipt["outcome"] = "interrupted" if interrupted_signal else "supervisor-failed"
            receipt["error"] = f"{type(error).__name__}: {error}"
            if process is not None:
                interrupted_cleanup_deadline = min(
                    cleanup_deadline,
                    time.monotonic() + CLEANUP_RESERVE_SECONDS,
                )
                if arguments.termination == "owner":
                    receipt["simulatorHostAuditRequired"] = True
                    receipt["testLockRecoveryRequired"] = True
                    receipt["payloadStatus"] = "unknown"
                    signal_exact_process(process, signal.SIGTERM)
                    _, wrapper_exited = wait_for_leader(process, interrupted_cleanup_deadline)
                    if not wrapper_exited:
                        signal_exact_process(process, signal.SIGKILL)
                        _, wrapper_exited = wait_for_leader(process, interrupted_cleanup_deadline)
                    receipt["wrapperExited"] = wrapper_exited
                    receipt["simulatorHostQuiescence"] = "unresolved; main-owner audit required"
                else:
                    receipt["processGroupQuiescent"] = terminate_exact_group(
                        process, process.pid, interrupted_cleanup_deadline
                    )
                    _, leader_exited = wait_for_leader(process, interrupted_cleanup_deadline)
                    receipt["leaderExited"] = leader_exited
            exit_code = 128 + interrupted_signal if interrupted_signal else 1
        finally:
            receipt["phase"] = "receipt"
            receipt["exitCode"] = exit_code
            receipt["completedAt"] = utc_now()
            receipt["durationSeconds"] = round(time.monotonic() - started, 3)
            receipt["receiptWriteStartedMonotonic"] = time.monotonic()
            write_receipt(arguments.receipt, receipt)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
