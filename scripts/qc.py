#!/usr/bin/env python3
"""Autonomic Poncho Monorepo QC and Conformance Suite.

Orchestrates quality control, static analysis, boundary linting, compilation,
formatting, testing, documentation, type checking, release inspection, and
security gates across all four published Hex packages and the internal
acceptance test suite:
  - packages/autonomic
  - packages/autonomic_linux
  - packages/autonomic_postgres
  - packages/autonomic_typesafe
  - integration/autonomic_acceptance

Strict mode (--strict) is release gating: every mandatory gate must pass.
Handoff mode (--handoff) records honest pending states for environmental gates
(such as live network, unconfigured DB, or non-privileged kernel namespaces)
and exits zero only when no executed gate failed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
LOGS = ARTIFACTS / "logs"
REPORT = ARTIFACTS / "conformance_report.json"

PACKAGES = [
    "packages/autonomic",
    "packages/autonomic_linux",
    "packages/autonomic_postgres",
    "packages/autonomic_typesafe",
]

INTEGRATION_PROJECTS = [
    "integration/autonomic_acceptance",
]

ALL_PROJECTS = PACKAGES + INTEGRATION_PROJECTS

MANDATORY = {
    "source_contract_inventory",
    "secret_scan",
    "package_boundary_lint",
    "release_check",
    "hex_release_inspect",
    "release_tooling_tests",
    "mix_deps_get",
    "format",
    "compile_warnings_as_errors",
    "exunit_full",
    "credo_strict",
    "dialyzer",
    "exdoc_warnings_as_errors",
    "rust_launcher_fmt",
    "rust_launcher_clippy",
    "rust_launcher_tests",
    "postgresql_integration",
    "postgresql_epoch_commit_race",
    "db_outage_blocks_authority",
    "af_unix_effect_broker",
    "git_authoritative_commit_reconciliation",
    "stale_epoch_race",
    "broker_crash_after_external_mutation_reconciliation",
    "class4_human_horizon",
    "linux_namespaces_cgroup_seccomp_overlay",
    "old_process_fork_cleanup",
    "overlay_rollback",
    "sensor_poisoning",
    "semantic_outage_degradation",
    "backpressure_load",
    "typesafe_live_evaluate_v4",
    "coding_agent_normal_repair",
    "coding_agent_violation_repair_epoch2",
    "host_preflight",
}

REQUIRED_FILES = [
    "README.md",
    "HANDOFF.md",
    "docs/ARCHITECTURE.md",
    "docs/SECURITY.md",
    "docs/OPERATIONS.md",
    "docs/DEVELOPMENT.md",
    "docs/PERSISTENCE_RECOVERY.md",
    "docs/EFFECT_ADAPTERS.md",
    "docs/TYPESAFE_SENSORS.md",
    "docs/IMPLEMENTATION_CHECKLIST.md",
    "docs/PONCHO_MIGRATION.md",
    "docs/PONCHO_IMPLEMENTATION_CHECKLIST.md",
    "scripts/preflight.sh",
    "scripts/lint_package_boundaries.py",
    "scripts/release.py",
    "packages/autonomic/lib/autonomic/effect_broker.ex",
    "packages/autonomic_postgres/priv/repo/migrations/20260917000000_create_autonomic_tables.exs",
    "packages/autonomic_linux/lib/autonomic/linux/backend.ex",
    "packages/autonomic_typesafe/lib/autonomic/typesafe/bank.ex",
    "packages/autonomic_linux/native/autonomic_launcher/src/main.rs",
    "integration/autonomic_acceptance/test/coding_agent_test.exs",
    "integration/autonomic_acceptance/test/class4_horizon_test.exs",
]

SECRET_PATTERNS = {
    "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "aws_access_key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "github_token": re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "openai_key": re.compile(rb"\bsk-[A-Za-z0-9_-]{32,}\b"),
}

SKIP_DIRS = {
    "_build",
    "deps",
    "target",
    ".git",
    "artifacts",
    "doc",
    "__pycache__",
    "var",
    "cover",
    ".elixir_ls",
    "_release_stage",
}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def tool_version(cmd: str, args: list[str] | None = None) -> str | None:
    path = shutil.which(cmd)
    if not path:
        return None
    try:
        cp = subprocess.run(
            [path] + (args or ["--version"]),
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=10,
            check=False,
        )
        return cp.stdout.strip().splitlines()[0] if cp.stdout.strip() else path
    except Exception as exc:
        return f"present but version failed: {exc}"


def source_files():
    for p in ROOT.rglob("*"):
        if not p.is_file() or any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        yield p


def source_digest() -> str:
    h = hashlib.sha256()
    for p in sorted(source_files(), key=lambda x: str(x.relative_to(ROOT))):
        rel = str(p.relative_to(ROOT)).encode()
        h.update(rel)
        h.update(b"\0")
        h.update(p.read_bytes())
        h.update(b"\0")
    return h.hexdigest()


def static_inventory() -> dict[str, Any]:
    missing = [path for path in REQUIRED_FILES if not (ROOT / path).is_file()]
    parse_errors: list[str] = []
    for p in ROOT.rglob("*.json"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        try:
            json.loads(p.read_text(encoding="utf-8"))
        except Exception as exc:
            parse_errors.append(f"{p.relative_to(ROOT)}: {exc}")

    manifest_path = ROOT / "packages/autonomic_linux/native/autonomic_launcher/Cargo.toml"
    try:
        tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:
        parse_errors.append(f"{manifest_path.relative_to(ROOT)}: {exc}")

    bad_whitespace: list[str] = []
    for p in source_files():
        if p.suffix not in {".ex", ".exs", ".rs", ".py", ".sh", ".md", ".json", ".toml"}:
            continue
        try:
            for number, line in enumerate(p.read_text(errors="replace").splitlines(), 1):
                if line.endswith(" ") or line.endswith("\t"):
                    bad_whitespace.append(f"{p.relative_to(ROOT)}:{number}")
                    if len(bad_whitespace) >= 50:
                        break
        except OSError:
            pass
        if len(bad_whitespace) >= 50:
            break

    status = "passed" if not missing and not parse_errors and not bad_whitespace else "failed"
    return {
        "id": "source_contract_inventory",
        "status": status,
        "mandatory": True,
        "missing_required_files": missing,
        "parse_errors": parse_errors,
        "trailing_whitespace": bad_whitespace,
    }


def secret_scan() -> dict[str, Any]:
    findings: list[dict[str, str]] = []
    for p in source_files():
        try:
            data = p.read_bytes()
        except OSError:
            continue
        if len(data) > 8 * 1024 * 1024:
            continue
        for name, pattern in SECRET_PATTERNS.items():
            if pattern.search(data):
                findings.append({"path": str(p.relative_to(ROOT)), "pattern": name})
    return {
        "id": "secret_scan",
        "status": "passed" if not findings else "failed",
        "mandatory": True,
        "findings": findings,
    }


HEARTBEAT_SECONDS = max(int(os.environ.get("AUTONOMIC_QC_HEARTBEAT_SECONDS", "10")), 1)


def progress(message: str) -> None:
    print(message, flush=True)


def _terminate_process(process: subprocess.Popen[Any]) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "posix":
            os.killpg(process.pid, 15)
        else:
            process.terminate()
        process.wait(timeout=5)
    except Exception:
        try:
            if os.name == "posix":
                os.killpg(process.pid, 9)
            else:
                process.kill()
        except Exception:
            pass


def _run_logged_command(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    log: Any,
    timeout: int,
    label: str,
) -> int:
    started = time.monotonic()
    next_heartbeat = started + HEARTBEAT_SECONDS
    process = subprocess.Popen(
        command,
        cwd=str(cwd),
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=os.name == "posix",
    )

    try:
        while True:
            return_code = process.poll()
            if return_code is not None:
                return return_code

            now = time.monotonic()
            elapsed = now - started
            if elapsed >= timeout:
                _terminate_process(process)
                raise subprocess.TimeoutExpired(command, timeout)

            if now >= next_heartbeat:
                progress(f"WAIT  {label} {elapsed:.0f}s")
                next_heartbeat = now + HEARTBEAT_SECONDS

            time.sleep(0.25)
    except BaseException:
        _terminate_process(process)
        raise


def run_gate(
    gate_id: str,
    command: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 1800,
) -> dict[str, Any]:
    LOGS.mkdir(parents=True, exist_ok=True)
    log_path = LOGS / f"{gate_id}.log"
    started = now_iso()
    timer = time.monotonic()
    merged = os.environ.copy()
    if env:
        merged.update(env)
    if gate_id == "exdoc_warnings_as_errors":
        merged["MIX_ENV"] = "dev"

    effective_cwd = cwd or ROOT
    progress(
        f"START {gate_id} cwd={effective_cwd.relative_to(ROOT) if effective_cwd != ROOT else '.'} "
        f"log={log_path.relative_to(ROOT)}"
    )

    try:
        with log_path.open("wb") as log:
            return_code = _run_logged_command(
                command,
                cwd=effective_cwd,
                env=merged,
                log=log,
                timeout=timeout,
                label=gate_id,
            )
        log_bytes = log_path.read_bytes()
        status = "passed" if return_code == 0 else "failed"
        if len(command) > 1 and Path(command[0]).name == "mix" and command[1] == "test" and not re.search(
            rb"Result: [1-9][0-9]*(?:/[0-9]+)? passed", log_bytes
        ):
            status = "failed"
        elapsed = time.monotonic() - timer
        progress(f"{'PASS' if status == 'passed' else 'FAIL'}  {gate_id} {elapsed:.1f}s")
        return {
            "id": gate_id,
            "status": status,
            "mandatory": gate_id in MANDATORY,
            "command": command,
            "exit_code": return_code,
            "started_at": started,
            "log_sha256": hashlib.sha256(log_bytes).hexdigest(),
            "finished_at": now_iso(),
            "log": str(log_path.relative_to(ROOT)),
        }
    except subprocess.TimeoutExpired:
        elapsed = time.monotonic() - timer
        progress(f"FAIL  {gate_id} {elapsed:.1f}s timeout={timeout}s")
        return {
            "id": gate_id,
            "status": "failed",
            "mandatory": gate_id in MANDATORY,
            "command": command,
            "reason": f"timeout after {timeout}s",
            "started_at": started,
            "finished_at": now_iso(),
            "log": str(log_path.relative_to(ROOT)),
        }
    except Exception as exc:
        elapsed = time.monotonic() - timer
        progress(f"FAIL  {gate_id} {elapsed:.1f}s error={type(exc).__name__}")
        return {
            "id": gate_id,
            "status": "failed",
            "mandatory": gate_id in MANDATORY,
            "command": command,
            "reason": repr(exc),
            "started_at": started,
            "finished_at": now_iso(),
        }


def run_compound_gate(
    gate_id: str,
    steps: list[tuple[str, list[str], Path]],
    *,
    env: dict[str, str] | None = None,
    timeout_per_step: int = 600,
) -> dict[str, Any]:
    """Runs a command across multiple package directories and records combined output."""
    LOGS.mkdir(parents=True, exist_ok=True)
    log_path = LOGS / f"{gate_id}.log"
    started = now_iso()
    timer = time.monotonic()
    merged = os.environ.copy()
    if env:
        merged.update(env)
    if gate_id == "exdoc_warnings_as_errors":
        merged["MIX_ENV"] = "dev"

    progress(f"START {gate_id} steps={len(steps)} log={log_path.relative_to(ROOT)}")
    overall_code = 0
    all_commands = []
    with log_path.open("wb") as log:
        for index, (label, cmd, cwd) in enumerate(steps, 1):
            header = f"\n=== [{label}] in {cwd.relative_to(ROOT)} ===\n$ {' '.join(cmd)}\n".encode()
            log.write(header)
            log.flush()
            all_commands.append(f"{label}: {' '.join(cmd)}")
            progress(f"STEP  {gate_id} {index}/{len(steps)} {label} cwd={cwd.relative_to(ROOT)}")
            try:
                return_code = _run_logged_command(
                    cmd,
                    cwd=cwd,
                    env=merged,
                    log=log,
                    timeout=timeout_per_step,
                    label=f"{gate_id}/{label}",
                )
                if return_code != 0:
                    overall_code = return_code
            except subprocess.TimeoutExpired:
                log.write(f"\nERROR: timeout after {timeout_per_step}s\n".encode())
                overall_code = 1
                break
            except Exception as exc:
                log.write(f"\nERROR: {exc}\n".encode())
                overall_code = 1
                break

    log_bytes = log_path.read_bytes()
    status = "passed" if overall_code == 0 else "failed"

    if gate_id == "exunit_full" and status == "passed":
        if not re.search(rb"Result: [1-9][0-9]*(?:/[0-9]+)? passed", log_bytes):
            status = "failed"

    elapsed = time.monotonic() - timer
    progress(f"{'PASS' if status == 'passed' else 'FAIL'}  {gate_id} {elapsed:.1f}s")
    return {
        "id": gate_id,
        "status": status,
        "mandatory": gate_id in MANDATORY,
        "commands": all_commands,
        "exit_code": overall_code,
        "started_at": started,
        "log_sha256": hashlib.sha256(log_bytes).hexdigest(),
        "finished_at": now_iso(),
        "log": str(log_path.relative_to(ROOT)),
    }


def pending(gate_id: str, reason: str, command: list[str] | None = None) -> dict[str, Any]:
    progress(f"PEND  {gate_id}: {reason}")
    item: dict[str, Any] = {
        "id": gate_id,
        "status": "not_run",
        "mandatory": gate_id in MANDATORY,
        "reason": reason,
    }
    if command:
        item["command"] = command
    return item


def gate_by_id(gates: list[dict[str, Any]], gate_id: str) -> dict[str, Any] | None:
    return next((g for g in gates if g["id"] == gate_id), None)


def add_alias_gate(gates: list[dict[str, Any]], gate_id: str, source_id: str, note: str) -> None:
    source = gate_by_id(gates, source_id)
    if source is None:
        gates.append(pending(gate_id, f"source gate {source_id} missing"))
    else:
        gates.append({
            "id": gate_id,
            "status": source["status"],
            "mandatory": gate_id in MANDATORY,
            "evidence_gate": source_id,
            "reason": note,
        })


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomic Poncho Monorepo QC & Conformance Runner")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--strict", action="store_true", help="Release gate mode: every mandatory gate must pass (default)")
    mode.add_argument("--handoff", action="store_true", help="Handoff mode: allow unavailable gates, fail executed errors")
    parser.add_argument("--package", help="Filter checks/tests to a specific package name")
    parser.add_argument("--include", help="Include tag for ExUnit tests (e.g. postgres, linux, live)")
    parser.add_argument("--exclude", help="Exclude tag for ExUnit tests")
    args = parser.parse_args()
    strict = not args.handoff

    ARTIFACTS.mkdir(exist_ok=True)
    LOGS.mkdir(exist_ok=True)

    target_projects = ALL_PROJECTS
    if args.package:
        matching = [p for p in ALL_PROJECTS if Path(p).name == args.package or p == args.package]
        if not matching:
            print(f"ERROR: Unknown package '{args.package}'. Available: {ALL_PROJECTS}", file=sys.stderr)
            return 1
        target_projects = matching

    gates: list[dict[str, Any]] = [static_inventory(), secret_scan()]

    versions = {
        "os": platform.platform(),
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "python": platform.python_version(),
        "git": tool_version("git"),
        "elixir": tool_version("elixir"),
        "mix": tool_version("mix"),
        "erlang_otp": tool_version(
            "erl",
            ["-noshell", "-eval", 'io:format("~s", [erlang:system_info(otp_release)]), halt().'],
        ),
        "rustc": tool_version("rustc"),
        "cargo": tool_version("cargo"),
        "psql": tool_version("psql"),
    }

    mix = shutil.which("mix")
    cargo = shutil.which("cargo")
    psql = shutil.which("psql")

    gates.append(run_gate("release_tooling_tests", [sys.executable, "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py"]))

    # 1. Package Boundary Lint
    boundary_script = ROOT / "scripts" / "lint_package_boundaries.py"
    if boundary_script.is_file():
        gates.append(run_gate("package_boundary_lint", [sys.executable, str(boundary_script)]))
    else:
        gates.append(pending("package_boundary_lint", "scripts/lint_package_boundaries.py missing"))

    # 2. Hex Release Check
    release_script = ROOT / "scripts" / "release.py"
    if release_script.is_file():
        gates.append(run_gate("release_check", [sys.executable, str(release_script), "check"]))
        gates.append(run_gate("hex_release_inspect", [sys.executable, str(release_script), "inspect", "0.1.0"]))
    else:
        gates.append(pending("release_check", "scripts/release.py missing"))
        gates.append(pending("hex_release_inspect", "scripts/release.py missing"))

    # 3. Mix toolchain checks across Poncho monorepo projects
    if mix:
        deps_steps = [(Path(p).name, [mix, "deps.get"], ROOT / p) for p in target_projects]
        gates.append(run_compound_gate("mix_deps_get", deps_steps, timeout_per_step=300))

        if gate_by_id(gates, "mix_deps_get")["status"] == "passed":
            # Formatting
            fmt_steps = [(Path(p).name, [mix, "format", "--check-formatted"], ROOT / p) for p in target_projects]
            gates.append(run_compound_gate("format", fmt_steps, timeout_per_step=120))

            # Compilation with warnings-as-errors
            compile_steps = [(Path(p).name, [mix, "compile", "--warnings-as-errors"], ROOT / p) for p in target_projects]
            gates.append(run_compound_gate("compile_warnings_as_errors", compile_steps, timeout_per_step=300))

            # ExUnit tests
            test_args = [mix, "test"]
            if args.include:
                test_args.extend(["--include", args.include])
            if args.exclude:
                test_args.extend(["--exclude", args.exclude])
            test_steps = [(Path(p).name, list(test_args), ROOT / p) for p in target_projects]
            gates.append(run_compound_gate("exunit_full", test_steps, timeout_per_step=600))

            # Credo strict (across published packages that configure credo)
            credo_projects = [p for p in target_projects if p in PACKAGES]
            credo_steps = [(Path(p).name, [mix, "credo", "--strict"], ROOT / p) for p in credo_projects]
            gates.append(run_compound_gate("credo_strict", credo_steps, timeout_per_step=300))

            # Dialyzer (across published packages)
            dialyzer_projects = [p for p in target_projects if p in PACKAGES]
            dialyzer_steps = [(Path(p).name, [mix, "dialyzer"], ROOT / p) for p in dialyzer_projects]
            gates.append(run_compound_gate("dialyzer", dialyzer_steps, timeout_per_step=900))

            # ExDoc warnings as errors
            exdoc_projects = [p for p in target_projects if p in PACKAGES]
            exdoc_steps = [(Path(p).name, [mix, "docs", "--warnings-as-errors"], ROOT / p) for p in exdoc_projects]
            gates.append(run_compound_gate("exdoc_warnings_as_errors", exdoc_steps, timeout_per_step=300))
        else:
            for gid in ["format", "compile_warnings_as_errors", "exunit_full", "credo_strict", "dialyzer", "exdoc_warnings_as_errors"]:
                gates.append(pending(gid, "dependency resolution failed", [mix]))
    else:
        for gid, cmd in [
            ("mix_deps_get", ["mix", "deps.get"]),
            ("format", ["mix", "format", "--check-formatted"]),
            ("compile_warnings_as_errors", ["mix", "compile", "--warnings-as-errors"]),
            ("exunit_full", ["mix", "test"]),
            ("credo_strict", ["mix", "credo", "--strict"]),
            ("dialyzer", ["mix", "dialyzer"]),
            ("exdoc_warnings_as_errors", ["mix", "docs", "--warnings-as-errors"]),
        ]:
            gates.append(pending(gid, "Mix/Elixir toolchain unavailable", cmd))

    # 4. Rust native launcher checks
    rust_manifest = ROOT / "packages/autonomic_linux/native/autonomic_launcher/Cargo.toml"
    if cargo and rust_manifest.is_file():
        gates.append(run_gate("rust_launcher_fmt", [cargo, "fmt", "--manifest-path", str(rust_manifest), "--", "--check"], timeout=120))
        gates.append(run_gate("rust_launcher_clippy", [cargo, "clippy", "--manifest-path", str(rust_manifest), "--all-targets", "--", "-D", "warnings"], timeout=300))
        gates.append(run_gate("rust_launcher_tests", [cargo, "test", "--manifest-path", str(rust_manifest)], timeout=300))
    else:
        for gid, cmd in [
            ("rust_launcher_fmt", ["cargo", "fmt", "--manifest-path", str(rust_manifest), "--", "--check"]),
            ("rust_launcher_clippy", ["cargo", "clippy", "--manifest-path", str(rust_manifest), "--all-targets", "--", "-D", "warnings"]),
            ("rust_launcher_tests", ["cargo", "test", "--manifest-path", str(rust_manifest)]),
        ]:
            gates.append(pending(gid, "Rust toolchain unavailable or manifest missing", cmd))

    # 5. PostgreSQL integration gates
    db_url = os.environ.get("AUTONOMIC_TEST_DATABASE_URL")
    db_ready = bool(mix and psql and db_url)
    if db_ready:
        pg_dir = ROOT / "packages/autonomic_postgres"
        env = {"MIX_ENV": "test", "AUTONOMIC_TEST_DATABASE_URL": db_url}
        migrate = run_gate("postgresql_migrations", [mix, "ecto.migrate", "-r", "Autonomic.Store.Repo"], cwd=pg_dir, env=env, timeout=300)
        gates.append(migrate)
        if migrate["status"] == "passed":
            pg = run_gate(
                "postgresql_integration",
                [mix, "test", "test/integration", "--include", "postgres", "--exclude", "linux", "--exclude", "reference", "--exclude", "db_outage"],
                cwd=pg_dir,
                env=env,
                timeout=1200,
            )
            gates.append(pg)
            gates.append(run_gate(
                "class4_human_horizon",
                [mix, "test", "test/class4_horizon_test.exs", "--include", "postgres"],
                cwd=ROOT / "integration/autonomic_acceptance", env=env, timeout=600,
            ))
            for gid, note in [
                ("postgresql_epoch_commit_race", "covered by real PostgreSQL concurrency barriers"),
                ("af_unix_effect_broker", "covered by real AF_UNIX + local HTTP broker integration"),
                ("git_authoritative_commit_reconciliation", "covered by real local Git CAS/reconciliation tests"),
                ("stale_epoch_race", "covered by PostgreSQL authority/reconciliation tests"),
                ("broker_crash_after_external_mutation_reconciliation", "covered by post-mutation crash reconciliation test"),

            ]:
                add_alias_gate(gates, gid, "postgresql_integration", note)
        else:
            gates.append(pending("postgresql_integration", "migration gate failed"))
            for gid in [
                "postgresql_epoch_commit_race",
                "af_unix_effect_broker",
                "git_authoritative_commit_reconciliation",
                "stale_epoch_race",
                "broker_crash_after_external_mutation_reconciliation",
                "class4_human_horizon",
            ]:
                gates.append(pending(gid, "PostgreSQL integration prerequisites failed"))
    else:
        reason = "requires Mix, psql and AUTONOMIC_TEST_DATABASE_URL"
        gates.append(pending("postgresql_integration", reason))
        for gid in [
            "postgresql_epoch_commit_race",
            "af_unix_effect_broker",
            "git_authoritative_commit_reconciliation",
            "stale_epoch_race",
            "broker_crash_after_external_mutation_reconciliation",
            "class4_human_horizon",
        ]:
            gates.append(pending(gid, reason))

    # 6. Database outage gate
    pg_server_tools = all(shutil.which(x) for x in ["pg_config", "runuser"] if os.geteuid() == 0) and shutil.which("pg_config") is not None
    if mix and pg_server_tools:
        gates.append(run_gate("db_outage_blocks_authority", ["bash", "scripts/run_db_outage_gate.sh"], timeout=1200))
    else:
        gates.append(
            pending(
                "db_outage_blocks_authority",
                "requires Mix and PostgreSQL server binaries (pg_config/initdb/pg_ctl/createdb) on a host permitted to start an ephemeral cluster",
                ["bash", "scripts/run_db_outage_gate.sh"],
            )
        )

    # 7. Linux isolation gate
    linux_enabled = os.environ.get("AUTONOMIC_LINUX") == "1"
    linux_ready = bool(mix and cargo and linux_enabled and (os.geteuid() == 0 or shutil.which("sudo")))
    if linux_ready:
        linux_gate = run_gate(
            "linux_namespaces_cgroup_seccomp_overlay",
            [mix, "test", "test/integration", "--include", "linux"],
            cwd=ROOT / "packages/autonomic_linux",
            timeout=1200,
        )
        gates.append(linux_gate)
        add_alias_gate(gates, "old_process_fork_cleanup", "linux_namespaces_cgroup_seccomp_overlay", "covered by fork-tree cgroup teardown test")
        add_alias_gate(gates, "overlay_rollback", "linux_namespaces_cgroup_seccomp_overlay", "covered by checkpoint/restore upperdir discard test")
    else:
        reason = "requires Mix, Rust launcher build and AUTONOMIC_LINUX=1 on a privileged cgroup-v2 host"
        gates.append(pending("linux_namespaces_cgroup_seccomp_overlay", reason))
        gates.append(pending("old_process_fork_cleanup", reason))
        gates.append(pending("overlay_rollback", reason))

    # Aliased gates to normal suite
    add_alias_gate(gates, "semantic_outage_degradation", "exunit_full", "covered by TypeSafeSDK.Test outage/model/unknown/capability tests")
    add_alias_gate(gates, "backpressure_load", "postgresql_integration", "covered by real PostgreSQL broker saturation with concurrent trusted HTTP commits")

    # 8. TypeSafe live evaluation gate
    live_key = os.environ.get("TYPESAFE_API_KEY")
    if mix and live_key:
        gates.append(
            run_gate(
                "typesafe_live_evaluate_v4",
                [mix, "test", "test/live_gate_test.exs", "--include", "live"],
                cwd=ROOT / "packages/autonomic_typesafe",
                timeout=600,
            )
        )
    else:
        gates.append(pending("typesafe_live_evaluate_v4", "requires Mix, network and intentionally configured TYPESAFE_API_KEY"))

    # 9. Reference coding agent acceptance test
    reference_ready = db_ready and linux_ready
    if reference_ready:
        env = {"MIX_ENV": "test", "AUTONOMIC_TEST_DATABASE_URL": db_url or "", "AUTONOMIC_LINUX": "1"}
        ref = run_gate(
            "coding_agent_reference",
            [mix, "test", "test/coding_agent_test.exs", "--include", "reference", "--include", "postgres", "--include", "linux"],
            cwd=ROOT / "integration/autonomic_acceptance",
            env=env,
            timeout=1800,
        )
        gates.append(ref)
        add_alias_gate(gates, "coding_agent_normal_repair", "coding_agent_reference", "normal verified authoritative Git repair variant")
        add_alias_gate(gates, "coding_agent_violation_repair_epoch2", "coding_agent_reference", "hostile direct-network tripwire + epoch-2 repair variant")
        add_alias_gate(gates, "sensor_poisoning", "coding_agent_reference", "hostile repository prompt-injection fixture plus deterministic containment")
    else:
        reason = "requires real PostgreSQL plus privileged Linux launcher gate"
        gates.append(pending("coding_agent_reference", reason))
        gates.append(pending("coding_agent_normal_repair", reason))
        gates.append(pending("coding_agent_violation_repair_epoch2", reason))
        gates.append(pending("sensor_poisoning", reason))

    # 10. Host preflight
    if shutil.which("bash"):
        gates.append(run_gate("host_preflight", ["bash", "scripts/preflight.sh"], timeout=120))
    else:
        gates.append(pending("host_preflight", "bash unavailable"))

    # Dedup gates preserving order
    dedup: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for gate in gates:
        gid = gate["id"]
        if gid not in dedup:
            order.append(gid)
            dedup[gid] = gate
        elif dedup[gid]["status"] == "not_run" and gate["status"] != "not_run":
            dedup[gid] = gate
    gates = [dedup[x] for x in order]

    for missing_id in sorted(MANDATORY - {g["id"] for g in gates}):
        gates.append(pending(missing_id, "mandatory gate missing from execution plan"))

    mandatory_failures = [g for g in gates if g["id"] in MANDATORY and g["status"] != "passed"]
    report = {
        "schema_version": 1,
        "project": "autonomic_poncho_monorepo",
        "generated_at": now_iso(),
        "mode": "strict" if strict else "handoff",
        "status": "release_ready" if not mandatory_failures else "handoff_pending_or_failed",
        "release_ready": not mandatory_failures,
        "source_sha256": source_digest(),
        "environment": versions,
        "availability": {
            "elixir_toolchain": bool(mix),
            "rust_toolchain": bool(cargo),
            "postgresql_tooling": bool(psql),
            "postgresql_test_url_configured": bool(db_url),
            "linux_gate_enabled": linux_enabled,
            "typesafe_credentials_configured": bool(live_key),
        },
        "gates": gates,
        "mandatory_not_green": [g["id"] for g in mandatory_failures],
        "determination": (
            "Every mandatory acceptance gate executed and passed on this environment."
            if not mandatory_failures
            else "One or more mandatory gates failed or could not execute. This repository is an implementation handoff, not a security-qualified release, until those gates are green on the target host."
        ),
    }
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=False) + "\n", encoding="utf-8")

    for gate in gates:
        marker = {"passed": "PASS", "failed": "FAIL", "not_run": "PEND"}.get(gate["status"], gate["status"].upper())
        print(f"{marker:4} {gate['id']}")
    print(f"\nconformance: {REPORT.relative_to(ROOT)}")
    print(f"release_ready: {report['release_ready']}")
    return 1 if any(g["status"] == "failed" for g in gates) or (strict and mandatory_failures) else 0


if __name__ == "__main__":
    raise SystemExit(main())
