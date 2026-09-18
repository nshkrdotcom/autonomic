#!/usr/bin/env python3
"""Deterministic Hex Release Staging and Inspection System for Autonomic.

Provides a robust, repository-owned release preparation workflow:
- scripts/release check
- scripts/release stage [version]
- scripts/release build [version]
- scripts/release inspect [version]
- scripts/release publish [package] [version] (guarded dry-run)

Topological publication order:
  1. autonomic
  2. autonomic_linux
  3. autonomic_postgres
  4. autonomic_typesafe
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PACKAGES_DIR = ROOT / "packages"
STAGE_BASE = ROOT / "_release_stage"

TOPOLOGICAL_ORDER = [
    "autonomic",
    "autonomic_linux",
    "autonomic_postgres",
    "autonomic_typesafe",
]

EXCLUDE_PATTERNS = {
    "_build",
    "deps",
    ".git",
    ".elixir_ls",
    "doc",
    "target",
    "var",
    "__pycache__",
    ".env",
    "priv/autonomic_launcher",
}


def run_cmd(cmd: list[str], cwd: Path | None = None, env: dict[str, str] | None = None) -> tuple[int, str]:
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**os.environ, **(env or {})},
    )
    return proc.returncode, proc.stdout


def command_check(args: argparse.Namespace) -> int:
    print("=== Running Autonomic Release Pre-Flight Checks ===")

    # 1. Check architectural boundaries
    boundary_script = ROOT / "scripts" / "lint_package_boundaries.py"
    if boundary_script.is_file():
        code, out = run_cmd([sys.executable, str(boundary_script)])
        print(out.strip())
        if code != 0:
            print("ERROR: Architectural boundary check failed.", file=sys.stderr)
            return code
    else:
        print("ERROR: lint_package_boundaries.py not found.", file=sys.stderr)
        return 1

    # 2. Check metadata in all packages
    print("\nValidating package metadata in source monorepo:")
    for pkg in TOPOLOGICAL_ORDER:
        mix_file = PACKAGES_DIR / pkg / "mix.exs"
        if not mix_file.is_file():
            print(f"ERROR: Missing {mix_file}", file=sys.stderr)
            return 1

        content = mix_file.read_text(encoding="utf-8")
        if not re.search(r"app:\s*:" + re.escape(pkg) + r"\b", content):
            print(f"ERROR: Incorrect OTP identity for {pkg}", file=sys.stderr)
            return 1
        if not re.search(r'@version "[0-9]+\.[0-9]+\.[0-9]+"', content):
            print(f"ERROR: Invalid version for {pkg}", file=sys.stderr)
            return 1
        if 'licenses: ["MIT"]' not in content:
            print(f"ERROR: Missing MIT license metadata for {pkg}", file=sys.stderr)
            return 1
        if "package:" not in content and "defp package" not in content:
            print(f"ERROR: Package metadata missing in {pkg}/mix.exs", file=sys.stderr)
            return 1
        if "description:" not in content:
            print(f"ERROR: Description missing in {pkg}/mix.exs", file=sys.stderr)
            return 1
        if "docs:" not in content:
            print(f"ERROR: Docs configuration missing in {pkg}/mix.exs", file=sys.stderr)
            return 1

        readme_file = PACKAGES_DIR / pkg / "README.md"
        license_file = PACKAGES_DIR / pkg / "LICENSE"
        changelog_file = PACKAGES_DIR / pkg / "CHANGELOG.md"
        if not readme_file.is_file():
            print(f"ERROR: Missing README in {pkg}", file=sys.stderr)
            return 1
        if not license_file.is_file():
            print(f"ERROR: Missing LICENSE in {pkg}", file=sys.stderr)
            return 1
        if not changelog_file.is_file():
            print(f"ERROR: Missing CHANGELOG in {pkg}", file=sys.stderr)
            return 1

        print(f"  [OK] {pkg}: valid metadata, README, LICENSE, CHANGELOG")

    print("\nTopological publish order:")
    for idx, pkg in enumerate(TOPOLOGICAL_ORDER, 1):
        print(f"  {idx}. {pkg}")

    print("\nPre-flight check passed.")
    return 0


def copy_package_files(src_dir: Path, dest_dir: Path) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    for root, dirs, files in os.walk(src_dir):
        rel_root = Path(root).relative_to(src_dir)

        # Skip excluded dirs
        dirs[:] = [
            d for d in dirs
            if d not in EXCLUDE_PATTERNS and not any(part in EXCLUDE_PATTERNS for part in (rel_root / d).parts)
        ]

        target_dir = dest_dir / rel_root
        target_dir.mkdir(parents=True, exist_ok=True)

        for f in files:
            if str(rel_root / f) in EXCLUDE_PATTERNS or f.startswith(".env") or f.endswith(".tar") or f == ".DS_Store" or f.endswith(".beam"):
                continue
            src_file = Path(root) / f
            dest_file = target_dir / f
            shutil.copy2(src_file, dest_file)


def command_stage(args: argparse.Namespace) -> int:
    version = args.version or "0.1.0"
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        print("ERROR: Expected a semantic version", file=sys.stderr)
        return 1
    versions = {pkg: re.search(r'@version "([^"]+)"', (PACKAGES_DIR / pkg / "mix.exs").read_text()).group(1)
                for pkg in TOPOLOGICAL_ORDER}
    if versions["autonomic"] != version:
        print("ERROR: Requested compatibility version does not match core version", file=sys.stderr)
        return 1
    stage_dir = STAGE_BASE / version
    print(f"=== Staging Autonomic Hex Packages for version {version} ===")
    print(f"Destination: {stage_dir}\n")

    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)

    for pkg in TOPOLOGICAL_ORDER:
        src_pkg = PACKAGES_DIR / pkg
        dest_pkg = stage_dir / pkg
        print(f"Staging package '{pkg}'...")
        copy_package_files(src_pkg, dest_pkg)

        # Rewrite local path dependencies to Hex version dependencies in mix.exs
        mix_path = dest_pkg / "mix.exs"
        content = mix_path.read_text(encoding="utf-8")

        # Replace {:autonomic, path: "../autonomic"} with {:autonomic, "~> version"}
        transformed = re.sub(
            r'\{:autonomic,\s*path:\s*"[^"]+"\}',
            f'{{:autonomic, "~> {version}"}}',
            content,
        )

        # Source-only SDK override must never become consumer behavior.
        transformed = re.sub(
            r'defp sdk_dependency do.*?\n  end',
            'defp sdk_dependency, do: {:typesafe_sdk, "~> 0.4.0"}',
            transformed, flags=re.DOTALL,
        )
        if re.search(r"\b(?:path|in_umbrella|apps_path|build_path|deps_path|config_path|lockfile)\s*:", transformed):
            print(f"ERROR: Workspace coupling remains in {pkg}", file=sys.stderr)
            return 1

        mix_path.write_text(transformed, encoding="utf-8")
        print(f"  [OK] Staged '{pkg}' with versioned Hex dependencies")

    print(f"\nAll 4 packages staged successfully at {stage_dir}")
    return 0


def command_build(args: argparse.Namespace) -> int:
    version = args.version or "0.1.0"
    stage_dir = STAGE_BASE / version

    # Always rebuild from current source, never silently reuse stale staging.
    code = command_stage(args)
    if code != 0:
        return code

    tarballs_dir = stage_dir / "tarballs"
    tarballs_dir.mkdir(parents=True, exist_ok=True)
    print(f"\n=== Building Hex Package Tarballs (mix hex.build) ===")

    for pkg in TOPOLOGICAL_ORDER:
        pkg_dir = stage_dir / pkg
        print(f"\nBuilding '{pkg}' in {pkg_dir}...")
        code, out = run_cmd(["mix", "hex.build"], cwd=pkg_dir)
        print(out.strip())
        if code != 0:
            print(f"ERROR: mix hex.build failed for {pkg}", file=sys.stderr)
            return code

        # Find generated tar file
        tar_files = list(pkg_dir.glob(f"{pkg}-*.tar"))
        if not tar_files:
            print(f"ERROR: No .tar file generated for {pkg}", file=sys.stderr)
            return 1

        tar_file = tar_files[0]
        dest_tar = tarballs_dir / tar_file.name
        shutil.copy2(tar_file, dest_tar)
        print(f"  [OK] Built: {dest_tar.name} ({dest_tar.stat().st_size} bytes)")

    print(f"\nAll 4 package tarballs built in {tarballs_dir}")
    return 0


def command_inspect(args: argparse.Namespace) -> int:
    version = args.version or "0.1.0"
    stage_dir = STAGE_BASE / version
    tarballs_dir = stage_dir / "tarballs"

    code = command_build(args)
    if code != 0:
        return code

    unpacked_dir = stage_dir / "unpacked"
    if unpacked_dir.exists():
        shutil.rmtree(unpacked_dir)
    unpacked_dir.mkdir(parents=True, exist_ok=True)

    print(f"\n=== Inspecting Unpacked Hex Package Tarballs ===")
    inspection_passed = True

    for pkg in TOPOLOGICAL_ORDER:
        tar_files = list(tarballs_dir.glob(f"{pkg}-*.tar"))
        if not tar_files:
            print(f"ERROR: Missing tarball for {pkg}", file=sys.stderr)
            return 1

        pkg_tar = tar_files[0]
        pkg_unpack = unpacked_dir / pkg
        pkg_unpack.mkdir(parents=True, exist_ok=True)

        print(f"\nInspecting '{pkg}' ({pkg_tar.name}):")
        with tarfile.open(pkg_tar, "r:*") as tf:
            # Hex tarball contains metadata.config, VERSION, and contents.tar.gz
            members = tf.getnames()
            print(f"  Tarball archive members: {members}")
            if "contents.tar.gz" not in members:
                print("  ERROR: contents.tar.gz missing from Hex tarball", file=sys.stderr)
                inspection_passed = False
                continue

            # Extract contents.tar.gz
            contents_member = tf.getmember("contents.tar.gz")
            contents_f = tf.extractfile(contents_member)
            if contents_f:
                with tarfile.open(fileobj=contents_f, mode="r:gz") as ctf:
                    content_files = ctf.getnames()
                    ctf.extractall(path=pkg_unpack, filter="data")
            else:
                print("  ERROR: Could not read contents.tar.gz", file=sys.stderr)
                inspection_passed = False
                continue

        # Assertions
        print(f"  Extracted {len(content_files)} files into {pkg_unpack}")

        # 1. mix.exs must exist and contain no path dependencies
        mix_exs = pkg_unpack / "mix.exs"
        if not mix_exs.is_file():
            print("  ERROR: mix.exs missing from package contents!", file=sys.stderr)
            inspection_passed = False
        else:
            mix_text = mix_exs.read_text(encoding="utf-8")
            if re.search(r"\bpath\s*:", mix_text):
                print("  ERROR: Residual relative path dependency found in packaged mix.exs!", file=sys.stderr)
                inspection_passed = False
            if "in_umbrella: true" in mix_text:
                print("  ERROR: Residual in_umbrella found in packaged mix.exs!", file=sys.stderr)
                inspection_passed = False

        expected = {"autonomic_linux": "native/autonomic_launcher/Cargo.lock",
                    "autonomic_postgres": "priv/repo/migrations"}
        if pkg in expected and not (pkg_unpack / expected[pkg]).exists():
            print(f"ERROR: Missing installation inputs for {pkg}", file=sys.stderr)
            inspection_passed = False

        # 2. Mandatory files
        for req in ["README.md", "LICENSE", "CHANGELOG.md"]:
            if not (pkg_unpack / req).is_file():
                print(f"  ERROR: Mandatory file '{req}' missing from package contents!", file=sys.stderr)
                inspection_passed = False
            else:
                print(f"  [OK] Found {req}")

        # 3. Forbidden artifacts
        for bad in ["_build", "deps", ".git", ".env", "target"]:
            matches = [f for f in content_files if bad in f.split("/")]
            if matches:
                print(f"  ERROR: Forbidden artifact '{bad}' bundled in package: {matches}", file=sys.stderr)
                inspection_passed = False

        if inspection_passed:
            print(f"  [PASS] Package '{pkg}' meets all Hex distribution criteria.")

    if not inspection_passed:
        print("\nRelease inspection FAILED.", file=sys.stderr)
        return 1

    print("\nAll 4 packages PASSED Hex release inspection.")
    return 0


def command_publish(args: argparse.Namespace) -> int:
    pkg = args.package
    version = args.version or "0.1.0"
    print("=== Hex Publication Guard ===")
    print(f"Target: package '{pkg}', version '{version}'")
    print("STATUS: ACCIDENTAL PUBLICATION GUARD ACTIVE.")
    print("Notice: Per prompt instructions, actual publication to Hex is disabled during this task.")
    print("\nWhen authorized to publish, the publication sequence is:")
    for idx, p in enumerate(TOPOLOGICAL_ORDER, 1):
        print(f"  Step {idx}: cd _release_stage/{version}/{p} && mix hex.publish")
    print("\nDry run completed safely without modifying Hex.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Autonomic Hex release staging & verification tooling")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("check", help="Run pre-flight checks and architectural boundary lint")

    stage_parser = subparsers.add_parser("stage", help="Stage packages with rewritten Hex dependencies")
    stage_parser.add_argument("version", nargs="?", default="0.1.0", help="Release version (e.g. 0.1.0)")

    build_parser = subparsers.add_parser("build", help="Build Hex package tarballs in staging")
    build_parser.add_argument("version", nargs="?", default="0.1.0", help="Release version (e.g. 0.1.0)")

    inspect_parser = subparsers.add_parser("inspect", help="Unpack and inspect Hex tarballs")
    inspect_parser.add_argument("version", nargs="?", default="0.1.0", help="Release version (e.g. 0.1.0)")

    pub_parser = subparsers.add_parser("publish", help="Guarded publish command (dry run)")
    pub_parser.add_argument("package", nargs="?", default="all", help="Package to publish")
    pub_parser.add_argument("version", nargs="?", default="0.1.0", help="Release version")

    args = parser.parse_args()

    if args.command == "check":
        return command_check(args)
    elif args.command == "stage":
        return command_stage(args)
    elif args.command == "build":
        return command_build(args)
    elif args.command == "inspect":
        return command_inspect(args)
    elif args.command == "publish":
        return command_publish(args)
    else:
        parser.print_help()
        return 1


if __name__ == "__main__":
    sys.exit(main())
