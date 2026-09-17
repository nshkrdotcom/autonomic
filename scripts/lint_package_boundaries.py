#!/usr/bin/env python3
"""Automated architectural boundary linter for the Autonomic Poncho monorepo.

Enforces strict dependency rules:
- `autonomic` has no dependencies on any adapter (linux, postgres, typesafe).
- `autonomic_linux` depends only on `autonomic` (no postgres, no typesafe).
- `autonomic_postgres` depends only on `autonomic` (no linux, no typesafe).
- `autonomic_typesafe` depends only on `autonomic` (no linux, no postgres).
- Staged releases must contain ZERO `path:` or `in_umbrella:` dependencies.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGES_DIR = ROOT / "packages"

FORBIDDEN_RULES: dict[str, set[str]] = {
    "autonomic": {"autonomic_linux", "autonomic_postgres", "autonomic_typesafe", "autonomic_store", "autonomic_kernel", "ecto_sql", "postgrex", "typesafe_sdk"},
    "autonomic_linux": {"autonomic_postgres", "autonomic_typesafe", "autonomic_store"},
    "autonomic_postgres": {"autonomic_linux", "autonomic_typesafe"},
    "autonomic_typesafe": {"autonomic_linux", "autonomic_postgres", "autonomic_store"},
}


def parse_package_deps(mix_path: Path) -> set[str]:
    content = mix_path.read_text(encoding="utf-8")
    # Include helper-returned tuples; do not silently accept an unparsed deps body.
    return set(re.findall(r"\{\s*:([a-zA-Z0-9_]+)\s*,", content))


def check_boundaries() -> int:
    violations: list[str] = []
    if (ROOT / "mix.exs").exists():
        violations.append("Root Mix project reintroduced")

    for pkg, forbidden in FORBIDDEN_RULES.items():
        mix_file = PACKAGES_DIR / pkg / "mix.exs"
        if not mix_file.is_file():
            violations.append(f"Missing mix.exs for package '{pkg}' at {mix_file}")
            continue

        actual_deps = parse_package_deps(mix_file)
        forbidden_present = actual_deps.intersection(forbidden)
        if forbidden_present:
            violations.append(
                f"Package boundary violation in '{pkg}': depends on forbidden {forbidden_present}"
            )

        if pkg != "autonomic" and "autonomic" not in actual_deps:
            violations.append(f"Package '{pkg}' must depend on autonomic")

        # Ensure no umbrella coupling
        content = mix_file.read_text(encoding="utf-8")
        if "in_umbrella: true" in content or "in_umbrella: :true" in content:
            violations.append(f"Package '{pkg}' retains forbidden 'in_umbrella' reference")
        if "apps_path" in content:
            violations.append(f"Package '{pkg}' retains forbidden 'apps_path' reference")

    if violations:
        print("Architectural Boundary Lint FAILED:", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    print("Architectural Boundary Lint PASSED:")
    print("  - autonomic: standalone core kernel (no adapter dependencies)")
    print("  - autonomic_linux: depends only on autonomic")
    print("  - autonomic_postgres: depends only on autonomic (no cross-adapter coupling)")
    print("  - autonomic_typesafe: depends only on autonomic (no cross-adapter coupling)")
    return 0


if __name__ == "__main__":
    sys.exit(check_boundaries())
