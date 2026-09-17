#!/usr/bin/env python3
"""Autonomic Kernel QC and conformance reporter.

Strict mode is release gating: every mandatory external gate must pass.
Handoff mode records honest pending gates but exits zero so an implementation
artifact can be packaged on an incapable build host without misrepresenting it.
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
import tomllib
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
LOGS = ARTIFACTS / "logs"
REPORT = ARTIFACTS / "conformance_report.json"

MANDATORY = {
    "source_contract_inventory",
    "secret_scan",
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
    "README.md", "HANDOFF.md", "docs/ARCHITECTURE.md", "docs/SECURITY.md",
    "docs/OPERATIONS.md", "docs/DEVELOPMENT.md", "docs/PERSISTENCE_RECOVERY.md",
    "docs/EFFECT_ADAPTERS.md", "docs/TYPESAFE_SENSORS.md",
    "docs/IMPLEMENTATION_CHECKLIST.md", "scripts/preflight.sh",
    "apps/autonomic_kernel/lib/autonomic/effect_broker.ex",
    "apps/autonomic_store/priv/repo/migrations/20260917000000_create_autonomic_tables.exs",
    "apps/autonomic_linux/lib/autonomic/linux/backend.ex",
    "apps/autonomic_typesafe/lib/autonomic/typesafe/bank.ex",
    "native/autonomic_launcher/src/main.rs",
    "apps/autonomic_store/test/reference/coding_agent_test.exs",
]

SECRET_PATTERNS = {
    "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "aws_access_key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "github_token": re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b"),
    "openai_key": re.compile(rb"\bsk-[A-Za-z0-9_-]{32,}\b"),
}

SKIP_DIRS = {"_build", "deps", "target", ".git", "artifacts"}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def tool_version(cmd: str, args: list[str] | None = None) -> str | None:
    path = shutil.which(cmd)
    if not path:
        return None
    try:
        cp = subprocess.run([path] + (args or ["--version"]), cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=10, check=False)
        return cp.stdout.strip().splitlines()[0] if cp.stdout.strip() else path
    except Exception as exc:  # pragma: no cover - diagnostic path
        return f"present but version failed: {exc}"


def run_gate(gate_id: str, command: list[str], *, env: dict[str, str] | None = None,
             timeout: int = 1800) -> dict[str, Any]:
    LOGS.mkdir(parents=True, exist_ok=True)
    log_path = LOGS / f"{gate_id}.log"
    started = now_iso()
    merged = os.environ.copy()
    if env:
        merged.update(env)
    try:
        with log_path.open("wb") as log:
            cp = subprocess.run(command, cwd=ROOT, env=merged, stdout=log,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
        status = "passed" if cp.returncode == 0 else "failed"
        return {
            "id": gate_id, "status": status, "mandatory": gate_id in MANDATORY,
            "command": command, "exit_code": cp.returncode, "started_at": started,
            "finished_at": now_iso(), "log": str(log_path.relative_to(ROOT)),
        }
    except subprocess.TimeoutExpired:
        return {
            "id": gate_id, "status": "failed", "mandatory": gate_id in MANDATORY,
            "command": command, "reason": f"timeout after {timeout}s", "started_at": started,
            "finished_at": now_iso(), "log": str(log_path.relative_to(ROOT)),
        }
    except Exception as exc:
        return {
            "id": gate_id, "status": "failed", "mandatory": gate_id in MANDATORY,
            "command": command, "reason": repr(exc), "started_at": started,
            "finished_at": now_iso(),
        }


def pending(gate_id: str, reason: str, command: list[str] | None = None) -> dict[str, Any]:
    item: dict[str, Any] = {
        "id": gate_id, "status": "not_run", "mandatory": gate_id in MANDATORY,
        "reason": reason,
    }
    if command:
        item["command"] = command
    return item


def static_inventory() -> dict[str, Any]:
    missing = [path for path in REQUIRED_FILES if not (ROOT / path).is_file()]
    # Parse JSON/TOML that is expected to be machine-readable.
    parse_errors: list[str] = []
    for p in ROOT.rglob("*.json"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        try:
            json.loads(p.read_text())
        except Exception as exc:
            parse_errors.append(f"{p.relative_to(ROOT)}: {exc}")
    try:
        tomllib.loads((ROOT / "native/autonomic_launcher/Cargo.toml").read_text())
    except Exception as exc:
        parse_errors.append(f"native/autonomic_launcher/Cargo.toml: {exc}")

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
        "id": "source_contract_inventory", "status": status, "mandatory": True,
        "missing_required_files": missing, "parse_errors": parse_errors,
        "trailing_whitespace": bad_whitespace,
    }


def source_files():
    for p in ROOT.rglob("*"):
        if not p.is_file() or any(part in SKIP_DIRS for part in p.relative_to(ROOT).parts):
            continue
        yield p


def secret_scan() -> dict[str, Any]:
    findings: list[dict[str, str]] = []
    for p in source_files():
        # Hostile fixture mentions secret *paths* intentionally; patterns only match actual credential formats.
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
        "id": "secret_scan", "status": "passed" if not findings else "failed",
        "mandatory": True, "findings": findings,
    }


def source_digest() -> str:
    h = hashlib.sha256()
    for p in sorted(source_files(), key=lambda x: str(x.relative_to(ROOT))):
        rel = str(p.relative_to(ROOT)).encode()
        h.update(rel); h.update(b"\0"); h.update(p.read_bytes()); h.update(b"\0")
    return h.hexdigest()


def gate_by_id(gates: list[dict[str, Any]], gate_id: str) -> dict[str, Any] | None:
    return next((g for g in gates if g["id"] == gate_id), None)


def add_alias_gate(gates: list[dict[str, Any]], gate_id: str, source_id: str, note: str) -> None:
    source = gate_by_id(gates, source_id)
    if source is None:
        gates.append(pending(gate_id, f"source gate {source_id} missing"))
    else:
        gates.append({
            "id": gate_id, "status": source["status"], "mandatory": gate_id in MANDATORY,
            "evidence_gate": source_id, "reason": note if source["status"] != "passed" else note,
        })


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--strict", action="store_true", help="release gate (default)")
    mode.add_argument("--handoff", action="store_true", help="record unavailable gates honestly and exit zero")
    args = parser.parse_args()
    strict = not args.handoff

    ARTIFACTS.mkdir(exist_ok=True)
    LOGS.mkdir(exist_ok=True)
    gates: list[dict[str, Any]] = [static_inventory(), secret_scan()]

    versions = {
        "os": platform.platform(), "kernel": platform.release(), "architecture": platform.machine(),
        "python": platform.python_version(), "git": tool_version("git"),
        "elixir": tool_version("elixir"), "mix": tool_version("mix"),
        "erlang_otp": tool_version("erl", ["-noshell", "-eval", "io:format(\"~s\", [erlang:system_info(otp_release)]), halt()."]),
        "rustc": tool_version("rustc"), "cargo": tool_version("cargo"), "psql": tool_version("psql"),
    }

    mix = shutil.which("mix")
    cargo = shutil.which("cargo")
    psql = shutil.which("psql")

    if mix:
        gates.append(run_gate("mix_deps_get", [mix, "deps.get"], timeout=900))
        if gate_by_id(gates, "mix_deps_get")["status"] == "passed":
            for gate_id, command, timeout in [
                ("format", [mix, "format", "--check-formatted"], 300),
                ("compile_warnings_as_errors", [mix, "compile", "--warnings-as-errors"], 900),
                ("exunit_full", [mix, "test"], 1200),
                ("credo_strict", [mix, "credo", "--strict"], 600),
                ("dialyzer", [mix, "dialyzer"], 1800),
                ("exdoc_warnings_as_errors", [mix, "docs", "--warnings-as-errors"], 900),
            ]:
                gates.append(run_gate(gate_id, command, timeout=timeout))
        else:
            for gid in ["format", "compile_warnings_as_errors", "exunit_full", "credo_strict", "dialyzer", "exdoc_warnings_as_errors"]:
                gates.append(pending(gid, "dependency resolution failed", [mix]))
    else:
        for gid, cmd in [
            ("mix_deps_get", ["mix", "deps.get"]), ("format", ["mix", "format", "--check-formatted"]),
            ("compile_warnings_as_errors", ["mix", "compile", "--warnings-as-errors"]), ("exunit_full", ["mix", "test"]),
            ("credo_strict", ["mix", "credo", "--strict"]), ("dialyzer", ["mix", "dialyzer"]),
            ("exdoc_warnings_as_errors", ["mix", "docs", "--warnings-as-errors"]),
        ]:
            gates.append(pending(gid, "Mix/Elixir toolchain unavailable", cmd))

    manifest = "native/autonomic_launcher/Cargo.toml"
    if cargo:
        gates.append(run_gate("rust_launcher_fmt", [cargo, "fmt", "--manifest-path", manifest, "--", "--check"], timeout=300))
        gates.append(run_gate("rust_launcher_clippy", [cargo, "clippy", "--manifest-path", manifest, "--all-targets", "--", "-D", "warnings"], timeout=900))
        gates.append(run_gate("rust_launcher_tests", [cargo, "test", "--manifest-path", manifest], timeout=900))
    else:
        for gid, cmd in [
            ("rust_launcher_fmt", ["cargo", "fmt", "--manifest-path", manifest, "--", "--check"]),
            ("rust_launcher_clippy", ["cargo", "clippy", "--manifest-path", manifest, "--all-targets", "--", "-D", "warnings"]),
            ("rust_launcher_tests", ["cargo", "test", "--manifest-path", manifest]),
        ]:
            gates.append(pending(gid, "Rust toolchain unavailable", cmd))

    db_url = os.environ.get("AUTONOMIC_TEST_DATABASE_URL")
    db_ready = bool(mix and psql and db_url)
    if db_ready:
        env = {"MIX_ENV": "test", "AUTONOMIC_TEST_DATABASE_URL": db_url}
        migrate = run_gate("postgresql_migrations", [mix, "ecto.migrate", "-r", "Autonomic.Store.Repo"], env=env, timeout=300)
        gates.append(migrate)
        if migrate["status"] == "passed":
            pg = run_gate("postgresql_integration", [mix, "test", "apps/autonomic_store/test/integration", "--include", "postgres", "--exclude", "linux", "--exclude", "reference", "--exclude", "db_outage"], env=env, timeout=1200)
            gates.append(pg)
            for gid, note in [
                ("postgresql_epoch_commit_race", "covered by real PostgreSQL concurrency barriers"),
                ("af_unix_effect_broker", "covered by real AF_UNIX + local HTTP broker integration"),
                ("git_authoritative_commit_reconciliation", "covered by real local Git CAS/reconciliation tests"),
                ("stale_epoch_race", "covered by PostgreSQL authority/reconciliation tests"),
                ("broker_crash_after_external_mutation_reconciliation", "covered by post-mutation crash reconciliation test"),
                ("class4_human_horizon", "covered by Class-4 signed human/slow/semantic horizon test"),
            ]:
                add_alias_gate(gates, gid, "postgresql_integration", note)
        else:
            gates.append(pending("postgresql_integration", "migration gate failed"))
            for gid in ["postgresql_epoch_commit_race", "af_unix_effect_broker", "git_authoritative_commit_reconciliation", "stale_epoch_race", "broker_crash_after_external_mutation_reconciliation", "class4_human_horizon"]:
                gates.append(pending(gid, "PostgreSQL integration prerequisites failed"))
    else:
        reason = "requires Mix, psql and AUTONOMIC_TEST_DATABASE_URL"
        gates.append(pending("postgresql_integration", reason))
        for gid in ["postgresql_epoch_commit_race", "af_unix_effect_broker", "git_authoritative_commit_reconciliation", "stale_epoch_race", "broker_crash_after_external_mutation_reconciliation", "class4_human_horizon"]:
            gates.append(pending(gid, reason))

    pg_server_tools = all(shutil.which(x) for x in ["pg_config", "runuser"] if os.geteuid() == 0) and shutil.which("pg_config") is not None
    if mix and pg_server_tools:
        gates.append(run_gate("db_outage_blocks_authority", ["bash", "scripts/run_db_outage_gate.sh"], timeout=1200))
    else:
        gates.append(pending("db_outage_blocks_authority", "requires Mix and PostgreSQL server binaries (pg_config/initdb/pg_ctl/createdb) on a host permitted to start an ephemeral cluster", ["bash", "scripts/run_db_outage_gate.sh"]))

    linux_enabled = os.environ.get("AUTONOMIC_LINUX") == "1"
    linux_ready = bool(mix and cargo and linux_enabled and os.geteuid() == 0 or (mix and cargo and linux_enabled and shutil.which("sudo")))
    if linux_ready:
        linux_gate = run_gate("linux_namespaces_cgroup_seccomp_overlay", [mix, "test", "apps/autonomic_linux/test/integration", "--include", "linux"], timeout=1200)
        gates.append(linux_gate)
        add_alias_gate(gates, "old_process_fork_cleanup", "linux_namespaces_cgroup_seccomp_overlay", "covered by fork-tree cgroup teardown test")
        add_alias_gate(gates, "overlay_rollback", "linux_namespaces_cgroup_seccomp_overlay", "covered by checkpoint/restore upperdir discard test")
    else:
        reason = "requires Mix, Rust launcher build and AUTONOMIC_LINUX=1 on a privileged cgroup-v2 host"
        gates.append(pending("linux_namespaces_cgroup_seccomp_overlay", reason))
        gates.append(pending("old_process_fork_cleanup", reason))
        gates.append(pending("overlay_rollback", reason))

    # Component semantic behavior is part of the normal ExUnit suite. Real broker
    # saturation/load uses PostgreSQL + the trusted HTTP adapter integration path.
    add_alias_gate(gates, "semantic_outage_degradation", "exunit_full", "covered by TypeSafeSDK.Test outage/model/unknown/capability tests")
    add_alias_gate(gates, "backpressure_load", "postgresql_integration", "covered by real PostgreSQL broker saturation with concurrent trusted HTTP commits")

    live_key = os.environ.get("TYPESAFE_API_KEY")
    if mix and live_key:
        gates.append(run_gate("typesafe_live_evaluate_v4", [mix, "test", "apps/autonomic_typesafe/test/live_gate_test.exs", "--include", "live"], timeout=600))
    else:
        gates.append(pending("typesafe_live_evaluate_v4", "requires Mix, network and intentionally configured TYPESAFE_API_KEY"))

    reference_ready = db_ready and linux_ready
    if reference_ready:
        env = {"MIX_ENV": "test", "AUTONOMIC_TEST_DATABASE_URL": db_url or "", "AUTONOMIC_LINUX": "1"}
        ref = run_gate("coding_agent_reference", [mix, "test", "apps/autonomic_store/test/reference/coding_agent_test.exs", "--include", "reference", "--include", "postgres", "--include", "linux"], env=env, timeout=1800)
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

    if shutil.which("bash"):
        gates.append(run_gate("host_preflight", ["bash", "scripts/preflight.sh"], timeout=120))
    else:
        gates.append(pending("host_preflight", "bash unavailable"))

    # Remove accidental duplicate IDs while preserving the first concrete execution record.
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

    mandatory_failures = [g for g in gates if g["id"] in MANDATORY and g["status"] != "passed"]
    report = {
        "schema_version": 1,
        "project": "autonomic_kernel",
        "generated_at": now_iso(),
        "mode": "strict" if strict else "handoff",
        "status": "release_ready" if not mandatory_failures else "handoff_pending_or_failed",
        "release_ready": not mandatory_failures,
        "source_sha256": source_digest(),
        "environment": versions,
        "availability": {
            "elixir_toolchain": bool(mix), "rust_toolchain": bool(cargo),
            "postgresql_tooling": bool(psql), "postgresql_test_url_configured": bool(db_url),
            "linux_gate_enabled": linux_enabled, "typesafe_credentials_configured": bool(live_key),
        },
        "gates": gates,
        "mandatory_not_green": [g["id"] for g in mandatory_failures],
        "determination": (
            "Every mandatory acceptance gate executed and passed on this environment."
            if not mandatory_failures else
            "One or more mandatory gates failed or could not execute. This repository is an implementation handoff, not a security-qualified release, until those gates are green on the target host."
        ),
    }
    REPORT.write_text(json.dumps(report, indent=2, sort_keys=False) + "\n")

    for gate in gates:
        marker = {"passed": "PASS", "failed": "FAIL", "not_run": "PEND"}.get(gate["status"], gate["status"].upper())
        print(f"{marker:4} {gate['id']}")
    print(f"\nconformance: {REPORT.relative_to(ROOT)}")
    print(f"release_ready: {report['release_ready']}")
    return 1 if strict and mandatory_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
