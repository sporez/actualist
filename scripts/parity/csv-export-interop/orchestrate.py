#!/usr/bin/env python3
"""Run the CSV observation workflow once under one shared deadline."""

import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid
import shutil


def _required_path(name):
    value = os.environ.get(name)
    if not value or not os.path.isabs(value):
        sys.exit(f"error: set {name} to an absolute path (see README: Machine-local paths)")
    return Path(value)


# This checkout, derived from the harness location (scripts/parity/csv-export-interop).
ROOT = Path(__file__).resolve().parents[3]
HARNESS = ROOT / "scripts/parity/csv-export-interop"
# Machine-local inputs come from the environment; nothing here names a user or host.
PINNED = _required_path("ACTUALIST_PARITY_ORACLE_ROOT")
NODE = _required_path("ACTUALIST_PARITY_NODE")
PROTECTED_CHECKOUT = Path(os.environ.get("ACTUALIST_PARITY_PROTECTED_CHECKOUT") or PINNED.parents[2])
YARN_CACHE = Path.home() / ".yarn/berry/cache"
SANDBOX_PARAMS = ["-D", f"PROTECTED_CHECKOUT={PROTECTED_CHECKOUT}", "-D", f"YARN_CACHE={YARN_CACHE}"]
EXPECTED_ACTUAL_COMMIT = "59fe126f637d858c061e1eeedbef5436c8f2225a"
EXPECTED_NODE_SHA256 = "e4b5a3af0e05c75de2eae013904145f40fe7fc2a6e6f17510128bf45cca4e79b"
EXPECTED_YARN_SHA256 = "471ffb15e0523663865bbf46a69e7d157ecf532412eb436c48dfab6e3f2abe88"
EXPECTED_VITEST_PACKAGE_SHA256 = "caa41f04799bd42f3cfd100c4282e630d77ffc7deb1e7e4927794fcb7f137f34"
OWNED_ROOT = ROOT / ".artifacts/csv-export-interop"
PROFILE = HARNESS / "readonly-inputs.sb"
SUPERVISOR = HARNESS / "supervise.py"
TOTAL_SECONDS = 1440.0
PREPARATION_SECONDS = 90.0
PREPARATION_CLEANUP_SECONDS = 10.0
STAGE_CLEANUP_RESERVE_SECONDS = 10.0
MIN_STAGE_REMAINDER_SECONDS = STAGE_CLEANUP_RESERVE_SECONDS + 1.0
SUPERVISOR_REAP_RESERVE_SECONDS = 1.0


class RunFailure(Exception):
    pass


pending_signal = None
active_child = None


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


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_group(process, pgid, deadline):
    while group_exists(pgid) and time.monotonic() < deadline:
        process.poll()
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    process.poll()
    return not group_exists(pgid)


def terminate_group(process, pgid, deadline):
    if not group_exists(pgid):
        process.poll()
        return True
    try:
        os.killpg(pgid, signal.SIGTERM)
        os.killpg(pgid, signal.SIGCONT)
    except ProcessLookupError:
        pass
    hard_kill_at = max(time.monotonic(), deadline - 2.0)
    if wait_group(process, pgid, hard_kill_at):
        return True
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    return wait_group(process, pgid, deadline)


def check_deadline(deadline, label, reserve=0.0):
    if pending_signal is not None:
        raise RunFailure(f"interrupted by signal {pending_signal}; evidence retained")
    if time.monotonic() + reserve >= deadline:
        raise RunFailure(f"deadline reserve exhausted before {label}; evidence retained")


def run_command(command, *, cwd, env, deadline, log_path, label, capture=False):
    """Run one known preparation command in its own, exactly-owned process group."""
    global active_child
    execution_deadline = deadline - PREPARATION_CLEANUP_SECONDS
    check_deadline(execution_deadline, label)
    stdout_target = subprocess.PIPE if capture else log_path.open("ab", buffering=0)
    stderr_target = subprocess.PIPE if capture else subprocess.STDOUT
    try:
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=stdout_target,
            stderr=stderr_target,
            start_new_session=True,
        )
    except BaseException:
        if not capture:
            stdout_target.close()
        raise
    active_child = (process, "group")
    output = b""
    error_output = b""
    try:
        while process.poll() is None and time.monotonic() < execution_deadline:
            if pending_signal is not None:
                break
            time.sleep(min(0.05, max(0.0, execution_deadline - time.monotonic())))
        if process.poll() is None or pending_signal is not None:
            cleanup_deadline = min(deadline, time.monotonic() + PREPARATION_CLEANUP_SECONDS)
            quiescent = terminate_group(process, process.pid, cleanup_deadline)
            if not quiescent:
                raise RunFailure(
                    f"{label} did not quiesce in its preparation reserve; "
                    "its exact process group and artifacts are retained for audit"
                )
            if pending_signal is not None:
                raise RunFailure(f"interrupted by signal {pending_signal}; evidence retained")
            raise RunFailure(f"{label} exceeded the bounded preparation window")
        if capture:
            output, error_output = process.communicate(timeout=max(0.01, deadline - time.monotonic()))
        process.poll()
        if group_exists(process.pid):
            quiescent = terminate_group(process, process.pid, deadline)
            if not quiescent:
                raise RunFailure(f"{label} left a live owned process group; evidence retained")
            raise RunFailure(f"{label} exited while an owned descendant remained")
        if process.returncode != 0:
            detail = (error_output or output).decode("utf-8", errors="replace")[-2000:]
            raise RunFailure(f"{label} exited {process.returncode}: {detail.strip()}")
        return output.decode("utf-8", errors="replace")
    except subprocess.TimeoutExpired as error:
        quiescent = terminate_group(process, process.pid, deadline)
        if not quiescent:
            raise RunFailure(f"{label} timed out and its process group is unresolved") from error
        raise RunFailure(f"{label} exceeded its bounded preparation window") from error
    finally:
        if not group_exists(process.pid):
            active_child = None
        if not capture:
            stdout_target.close()


def safe_output_root():
    requested = Path(os.environ.get("ACTUALIST_CSV_INTEROP_OUTPUT", str(OWNED_ROOT)))
    if not requested.is_absolute() or os.path.abspath(requested) != str(OWNED_ROOT):
        raise RunFailure(f"output must be exactly the owned root {OWNED_ROOT}")
    if os.path.realpath(ROOT) != str(ROOT) or os.path.realpath(ROOT / ".artifacts") != str(ROOT / ".artifacts"):
        raise RunFailure("DEV or .artifacts has a symlinked path component")
    parent = ROOT / ".artifacts"
    if not parent.is_dir() or parent.is_symlink():
        raise RunFailure("the DEV .artifacts parent must already be a real directory")
    if os.path.lexists(OWNED_ROOT):
        raise RunFailure(f"refusing existing output path (one shot; no cleanup): {OWNED_ROOT}")
    os.mkdir(OWNED_ROOT, 0o700)
    os.chmod(OWNED_ROOT, 0o700)
    metadata = OWNED_ROOT.lstat()
    if stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise RunFailure("fresh output root is not a real mode-0700 directory")
    return OWNED_ROOT, (metadata.st_dev, metadata.st_ino)


def verify_output_identity(output, identity):
    metadata = output.lstat()
    if stat.S_ISLNK(metadata.st_mode) or (metadata.st_dev, metadata.st_ino) != identity:
        raise RunFailure("owned output root identity changed; preserving all artifacts")


def make_subdir(output, name):
    path = output / name
    os.mkdir(path, 0o700)
    if path.is_symlink() or not path.is_dir():
        raise RunFailure(f"owned output directory is not a real directory: {path}")
    return path


def hash_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_pinned_checkout(deadline, log_path):
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    revision = run_command(
        ["/usr/bin/git", "--no-optional-locks", "-C", str(PINNED), "rev-parse", "HEAD"],
        cwd=ROOT, env=env, deadline=deadline, log_path=log_path,
        label="pinned Actual revision check", capture=True,
    ).strip()
    if revision != EXPECTED_ACTUAL_COMMIT:
        raise RunFailure(f"pinned Actual revision mismatch: {revision}")
    status = run_command(
        ["/usr/bin/git", "--no-optional-locks", "-C", str(PINNED), "status", "--short"],
        cwd=ROOT, env=env, deadline=deadline, log_path=log_path,
        label="pinned Actual read-only status check", capture=True,
    )
    if status:
        raise RunFailure("pinned Actual checkout is dirty; refusing the run")


def run_stage(*, output, identity, overall_deadline, stage_name, cap, termination,
              command, env, cwd):
    verify_output_identity(output, identity)
    started = time.monotonic()
    stage_deadline = min(overall_deadline, started + cap)
    supervisor_deadline = stage_deadline - SUPERVISOR_REAP_RESERVE_SECONDS
    if supervisor_deadline - started <= MIN_STAGE_REMAINDER_SECONDS:
        raise RunFailure(f"insufficient shared deadline for {stage_name}")
    receipts = output / "receipts"
    logs = output / "logs"
    receipt_path = receipts / f"{stage_name}.json"
    supervisor_log = logs / f"{stage_name}-supervisor.log"
    launch = {
        "schema": 1,
        "stage": stage_name,
        "state": "launching",
        "stageCapSeconds": cap,
        "sharedDeadlineMonotonic": overall_deadline,
        "stageDeadlineMonotonic": stage_deadline,
        "supervisorDeadlineMonotonic": supervisor_deadline,
        "startedAt": utc_now(),
        "termination": termination,
        "command": command,
        "receipt": str(receipt_path),
    }
    launch_path = receipts / f"{stage_name}-owner.json"
    atomic_json(launch_path, launch)
    supervisor_command = [
        sys.executable, str(SUPERVISOR),
        "--stage", stage_name,
        "--timeout", str(cap),
        "--deadline-monotonic", repr(overall_deadline),
        "--stage-deadline-monotonic", repr(supervisor_deadline),
        "--cwd", str(cwd),
        "--termination", termination,
        "--log", str(logs / f"{stage_name}.log"),
        "--receipt", str(receipt_path),
        "--", *command,
    ]
    check_deadline(supervisor_deadline, f"launch of {stage_name}", MIN_STAGE_REMAINDER_SECONDS)
    with supervisor_log.open("xb", buffering=0) as log:
        supervisor = subprocess.Popen(
            supervisor_command,
            cwd=str(ROOT),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        launch.update({"state": "running", "supervisorPID": supervisor.pid,
                       "supervisorPGID": supervisor.pid})
        atomic_json(launch_path, launch)
        while supervisor.poll() is None:
            if pending_signal is not None:
                launch["state"] = "interrupted"
                launch["signal"] = pending_signal
                atomic_json(launch_path, launch)
                try:
                    supervisor.send_signal(signal.SIGTERM)
                except ProcessLookupError:
                    pass
                reap_deadline = min(stage_deadline, time.monotonic() + STAGE_CLEANUP_RESERVE_SECONDS + 1.0)
                while supervisor.poll() is None and time.monotonic() < reap_deadline:
                    time.sleep(min(0.05, max(0.0, reap_deadline - time.monotonic())))
                if supervisor.poll() is None:
                    launch["state"] = "supervisor-not-reaped"
                    launch["quiescence"] = "unresolved; main-owner audit required"
                    atomic_json(launch_path, launch)
                    raise RunFailure(f"interrupted {stage_name}; supervisor remains active and quiescence is unresolved")
                supervisor.wait()
                raise RunFailure(f"interrupted while {stage_name} was active; evidence retained")
            if time.monotonic() >= stage_deadline:
                launch["state"] = "supervisor-deadline-exceeded"
                launch["quiescence"] = "unresolved; main-owner audit required"
                atomic_json(launch_path, launch)
                try:
                    supervisor.send_signal(signal.SIGTERM)
                except ProcessLookupError:
                    pass
                raise RunFailure(f"{stage_name} supervisor exceeded its inclusive stage deadline; no later stage")
            time.sleep(min(0.05, max(0.0, stage_deadline - time.monotonic())))
        supervisor_status = supervisor.wait()
    launch["state"] = "supervisor-exited"
    launch["supervisorExitCode"] = supervisor_status
    launch["completedAt"] = utc_now()
    atomic_json(launch_path, launch)
    verify_output_identity(output, identity)
    if not receipt_path.is_file() or receipt_path.is_symlink():
        raise RunFailure(f"{stage_name} has no final receipt; no later stage")
    with receipt_path.open(encoding="utf-8") as handle:
        receipt = json.load(handle)
    if supervisor_status != 0 or receipt.get("outcome") != "passed" or receipt.get("exitCode") != 0:
        raise RunFailure(f"{stage_name} failed or was incomplete; receipt retained; no later stage")
    if termination == "group" and receipt.get("processGroupQuiescent") is not True:
        raise RunFailure(f"{stage_name} process group is unresolved; no later stage")
    if termination == "owner" and receipt.get("wrapperExited") is not True:
        raise RunFailure(f"{stage_name} wrapper exit is unresolved; no later stage")
    return receipt


def main():
    global pending_signal
    started = time.monotonic()
    overall_deadline = started + TOTAL_SECONDS
    started_at = utc_now()
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda _signum, _frame, number=signum: set_signal(number))

    output = None
    output_identity = None
    run_receipt = None
    exit_code = 1
    try:
        check_deadline(overall_deadline, "initialization")
        output, output_identity = safe_output_root()
        for dirname in ("fixture", "evidence", "logs", "receipts", "overlay-harness",
                        "home", "tmp", "cache", "yarn-cache"):
            make_subdir(output, dirname)
        run_receipt = {
            "schema": 1,
            "runID": str(uuid.uuid4()),
            "state": "preparing",
            "startedAt": started_at,
            "deadlineMonotonic": overall_deadline,
            "timeoutSecondsInclusive": TOTAL_SECONDS,
            "preparationCapSeconds": PREPARATION_SECONDS,
            "stageCapsSeconds": {"swift-fixture": 1200, "actual-parser-mapping": 120},
            "outputRoot": str(output),
            "protectedWriteDeny": [str(PROTECTED_CHECKOUT), str(YARN_CACHE)],
            "network": "denied for COW copy and Node stages",
        }
        run_receipt_path = output / "receipts/orchestrator.json"
        atomic_json(run_receipt_path, run_receipt)
        preparation_deadline = min(overall_deadline, started + PREPARATION_SECONDS)
        prep_log = output / "logs/preparation.log"
        os.chmod(prep_log, 0o600) if prep_log.exists() else None
        if not PINNED.is_dir() or PINNED.is_symlink() or os.path.realpath(PINNED) != str(PINNED):
            raise RunFailure("pinned Actual path is missing or has a symlinked path")
        if not NODE.is_file() or NODE.is_symlink() or os.path.realpath(NODE) != str(NODE):
            raise RunFailure("pinned Node executable is missing or symlinked")
        if hash_file(NODE) != EXPECTED_NODE_SHA256:
            raise RunFailure("pinned Node executable hash mismatch")
        verify_pinned_checkout(preparation_deadline, prep_log)
        check_deadline(preparation_deadline, "source freeze", PREPARATION_CLEANUP_SECONDS)
        # The committed freeze names external inputs with @ORACLE_ROOT@ and @NODE@
        # placeholders; render them for this machine before checking.
        rendered_freeze = output / "source-freeze.rendered.sha256"
        rendered_freeze.write_text(
            (HARNESS / "source-freeze.sha256").read_text()
            .replace("@ORACLE_ROOT@", str(PINNED)).replace("@NODE@", str(NODE))
        )
        run_command(
            ["/usr/bin/shasum", "-a", "256", "-c", str(rendered_freeze)],
            cwd=ROOT, env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            deadline=preparation_deadline, log_path=prep_log,
            label="source freeze verification",
        )
        shutil.copyfile(HARNESS / "source-freeze.sha256", output / "source-freeze.sha256")
        overlay = output / "actual-overlay"
        run_command(
            ["/usr/bin/sandbox-exec", *SANDBOX_PARAMS, "-f", str(PROFILE), "/bin/cp", "-cR", str(PINNED), str(overlay)],
            cwd=ROOT, env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            deadline=preparation_deadline, log_path=prep_log,
            label="sandboxed APFS copy-on-write preparation",
        )
        for filename in ("csv-export-interop.test.ts", "oracle.vitest.config.ts"):
            shutil.copyfile(HARNESS / filename, output / "overlay-harness" / filename)
        verify_output_identity(output, output_identity)
        verify_pinned_checkout(preparation_deadline, prep_log)
        overlay_revision = run_command(
            ["/usr/bin/git", "--no-optional-locks", "-C", str(overlay), "rev-parse", "HEAD"],
            cwd=ROOT, env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            deadline=preparation_deadline, log_path=prep_log,
            label="COW overlay revision check", capture=True,
        ).strip()
        if overlay_revision != EXPECTED_ACTUAL_COMMIT:
            raise RunFailure("COW overlay revision mismatch")
        overlay_status = run_command(
            ["/usr/bin/git", "--no-optional-locks", "-C", str(overlay), "status", "--short"],
            cwd=ROOT, env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
            deadline=preparation_deadline, log_path=prep_log,
            label="COW overlay read-only status check", capture=True,
        )
        if overlay_status:
            raise RunFailure("COW overlay is not clean")
        check_deadline(preparation_deadline, "preparation completion")

        encoder = ROOT / "Actualist/Shared/TransactionCSVEncoder.swift"
        fixture_test = ROOT / "ActualistTests/TransactionCSVImporterInteropTests.swift"
        encoder_hash = hash_file(encoder)
        test_hash = hash_file(fixture_test)
        freeze_hash = hash_file(HARNESS / "source-freeze.sha256")
        manifest = {
            "schema": 2,
            "actualCommit": EXPECTED_ACTUAL_COMMIT,
            "pinnedReadOnlySource": str(PINNED),
            "writableCOWOverlay": str(overlay),
            "node": {"path": str(NODE), "version": "24.21.0", "sha256": EXPECTED_NODE_SHA256},
            "yarn": {"version": "4.17.1", "sha256": EXPECTED_YARN_SHA256},
            "vitest": {"version": "4.1.10", "packageSHA256": EXPECTED_VITEST_PACKAGE_SHA256},
            "sourceFreezeSHA256": freeze_hash,
            "scheme": "Actualist Dev",
            "derivedData": str(ROOT / ".derivedData"),
            "simulatorUDID": os.environ["ACTUALIST_SIMULATOR_ID"],
            "timeoutSecondsInclusive": TOTAL_SECONDS,
            "stages": [
                {"name": "preparation", "capSecondsInclusive": PREPARATION_SECONDS},
                {"name": "swift-fixture", "capSecondsInclusive": 1200},
                {"name": "actual-parser-mapping", "capSecondsInclusive": 120},
            ],
            "sourceHashes": {"encoder": encoder_hash, "fixtureTest": test_hash},
        }
        atomic_json(output / "run-manifest.json", manifest)
        run_receipt.update({"state": "preparation-passed", "preparationCompletedAt": utc_now()})
        atomic_json(run_receipt_path, run_receipt)

        swift_env = os.environ.copy()
        swift_env.pop("ACTUALIST_CSV_INTEROP_OUTPUT", None)
        swift_env["ACTUALIST_SCHEME"] = "Actualist Dev"
        swift_env["DERIVED_DATA_PATH"] = str(ROOT / ".derivedData")
        swift_env["ACTUALIST_SIMULATOR_ID"] = os.environ["ACTUALIST_SIMULATOR_ID"]
        swift_env["GIT_OPTIONAL_LOCKS"] = "0"
        swift_env["TEST_RUNNER_ACTUALIST_CSV_INTEROP_OUTPUT"] = str(output / "fixture")
        swift_env["TEST_RUNNER_ACTUALIST_CSV_INTEROP_ENCODER_SHA256"] = encoder_hash
        swift_env["TEST_RUNNER_ACTUALIST_CSV_INTEROP_TEST_SHA256"] = test_hash
        run_receipt.update({"state": "swift-fixture-running", "simulatorHostAuditRequired": True})
        atomic_json(run_receipt_path, run_receipt)
        swift_receipt = run_stage(
            output=output, identity=output_identity, overall_deadline=overall_deadline,
            stage_name="swift-fixture", cap=1200, termination="owner",
            command=[str(ROOT / "scripts/test.sh"), "unit",
                     "TransactionCSVImporterInteropTests/writesActualImporterInteropFixture()"],
            env=swift_env, cwd=ROOT,
        )
        run_receipt["swiftFixtureOutcome"] = swift_receipt.get("outcome")
        run_receipt["simulatorHostAuditRequired"] = True
        atomic_json(run_receipt_path, run_receipt)
        lockdir = ROOT / ".artifacts/.test-run.lock"
        if os.path.lexists(lockdir):
            raise RunFailure("scripts/test.sh left or encountered its lock; preserve it for owner audit")
        fixture_csv = output / "fixture/transaction-export.csv"
        fixture_manifest = output / "fixture/manifest.json"
        if not fixture_csv.is_file() or fixture_csv.stat().st_size == 0:
            raise RunFailure("Swift fixture CSV is missing or empty; no Node stage")
        if not fixture_manifest.is_file() or fixture_manifest.stat().st_size == 0:
            raise RunFailure("Swift fixture manifest is missing or empty; no Node stage")
        if fixture_csv.is_symlink() or fixture_manifest.is_symlink():
            raise RunFailure("Swift fixture paths cannot be symlinks; no Node stage")

        node_env = {
            "PATH": f"{NODE.parent}:/usr/bin:/bin",
            "NODE_OPTIONS": "--experimental-vm-modules --trace-warnings",
            "HOME": str(output / "home"),
            "TMPDIR": str(output / "tmp"),
            "XDG_CACHE_HOME": str(output / "cache"),
            "YARN_ENABLE_GLOBAL_CACHE": "0",
            "YARN_CACHE_FOLDER": str(output / "yarn-cache"),
            "GIT_OPTIONAL_LOCKS": "0",
            "ACTUALIST_CSV_INTEROP_OWNED_ROOT": str(OWNED_ROOT),
            "ACTUALIST_CSV_INTEROP_FIXTURE_DIR": str(output / "fixture"),
            "ACTUALIST_CSV_INTEROP_EVIDENCE_DIR": str(output / "evidence"),
            "ACTUALIST_CSV_INTEROP_ACTUAL_OVERLAY": str(overlay),
            "ACTUALIST_CSV_INTEROP_OVERLAY_HARNESS": str(output / "overlay-harness"),
        }
        node_command = [
            "/usr/bin/sandbox-exec", *SANDBOX_PARAMS, "-f", str(PROFILE), str(NODE),
            str(overlay / "node_modules/vitest/vitest.mjs"), "run",
            "--configLoader", "native",
            "--config", str(output / "overlay-harness/oracle.vitest.config.ts"),
            str(output / "overlay-harness/csv-export-interop.test.ts"),
        ]
        run_receipt.update({"state": "actual-parser-mapping-running"})
        atomic_json(run_receipt_path, run_receipt)
        node_receipt = run_stage(
            output=output, identity=output_identity, overall_deadline=overall_deadline,
            stage_name="actual-parser-mapping", cap=120, termination="group",
            command=node_command, env=node_env, cwd=overlay,
        )
        run_receipt.update({"state": "postflight", "nodeOutcome": node_receipt.get("outcome")})
        atomic_json(run_receipt_path, run_receipt)
        verify_pinned_checkout(overall_deadline - 2.0, output / "logs/preparation.log")
        observation = output / "evidence/actual-import-observation.json"
        if observation.is_symlink() or not observation.is_file() or observation.stat().st_size == 0:
            raise RunFailure("Actual observation is missing, empty or symlinked")
        check_deadline(overall_deadline, "final receipt", 2.0)
        verify_output_identity(output, output_identity)
        run_receipt.update({"state": "passed", "completedAt": utc_now(),
                            "durationSeconds": round(time.monotonic() - started, 3),
                            "simulatorHostAuditRequired": True})
        atomic_json(run_receipt_path, run_receipt)
        print(f"Observation written to {output / 'evidence/actual-import-observation.json'}")
        exit_code = 0
    except BaseException as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            message = f"{type(error).__name__}: {error}"
        else:
            message = f"{type(error).__name__}: {error}"
        if output is not None and run_receipt is not None:
            prior_state = run_receipt.get("state")
            run_receipt.update({"state": "blocked", "failure": message,
                                "completedAt": utc_now(),
                                "durationSeconds": round(time.monotonic() - started, 3),
                                "artifactsPreserved": True})
            if prior_state == "swift-fixture-running":
                run_receipt["simulatorHostAuditRequired"] = True
                run_receipt["testLockRecoveryRequired"] = True
            if active_child is not None:
                child_process, child_kind = active_child
                run_receipt["unresolvedOwnedChild"] = {
                    "pid": child_process.pid,
                    "processGroup": child_process.pid if child_kind == "group" else None,
                    "kind": child_kind,
                    "quiescence": "unresolved; main-owner audit required",
                }
            if time.monotonic() < overall_deadline - 0.25:
                try:
                    atomic_json(output / "receipts/orchestrator.json", run_receipt)
                except OSError:
                    pass
        print(f"CSV interop blocked; preserve owned artifacts for audit: {message}", file=sys.stderr)
        exit_code = 1
    return exit_code


def set_signal(number):
    global pending_signal
    pending_signal = number


if __name__ == "__main__":
    sys.exit(main())
