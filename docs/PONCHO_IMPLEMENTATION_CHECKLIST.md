# Poncho Monorepo Implementation Checklist

This checklist tracks the architectural conversion of the Autonomic repository from an Elixir umbrella into a **Hex-ready Poncho monorepo** of four independently publishable packages and one internal acceptance test suite.

---

## 1. Monorepo Architecture & Directory Structure

- [x] **Umbrella semantics eliminated**
  - Root `apps/` directory removed.
  - Root `mix.exs` with `apps_path: "apps"` removed.
  - Root `mix.lock` removed.
  - All occurrences of `in_umbrella: true` removed across all projects.
- [x] **Package directories created**
  - [x] `packages/autonomic`: Core OTP control plane, homeostat, effect broker, contracts.
  - [x] `packages/autonomic_linux`: Linux isolation backend (cgroups v2, namespaces, seccomp, overlayfs).
  - [x] `packages/autonomic_postgres`: PostgreSQL authority governor, Ecto repo, transactional ledger, epoch fencing.
  - [x] `packages/autonomic_typesafe`: TypeSafe/Jev semantic sensor bank, drift detection, evidence redaction.
- [x] **Internal acceptance project created**
  - [x] `integration/autonomic_acceptance`: Internal integration suite depending on all four packages via `path:` dependencies.
- [x] **Native launcher relocation**
  - [x] `packages/autonomic_linux/native/autonomic_launcher`: Rust launcher owned directly by `autonomic_linux`.
  - [x] Builds to `packages/autonomic_linux/priv/autonomic_launcher` (mode 0755).

---

## 2. Package Configuration & Hex Distribution Readiness

| Package | App ID | Mix File | Lockfile | README | LICENSE | CHANGELOG | Logo | Hex Build (.tar) |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `autonomic` | `:autonomic` | [mix.exs](file:///home/home/p/g/n/autonomic/packages/autonomic/mix.exs) | Present | Present | MIT | Present | Present | Verified |
| `autonomic_linux` | `:autonomic_linux` | [mix.exs](file:///home/home/p/g/n/autonomic/packages/autonomic_linux/mix.exs) | Present | Present | MIT | Present | Present | Verified |
| `autonomic_postgres` | `:autonomic_postgres` | [mix.exs](file:///home/home/p/g/n/autonomic/packages/autonomic_postgres/mix.exs) | Present | Present | MIT | Present | Present | Verified |
| `autonomic_typesafe` | `:autonomic_typesafe` | [mix.exs](file:///home/home/p/g/n/autonomic/packages/autonomic_typesafe/mix.exs) | Present | Present | MIT | Present | Present | Verified |

- [x] **Hex Metadata configured in all 4 packages**:
  - `name`, `version` ("0.1.0"), `description`, `package` (licenses, files, links), `docs` (main, extras, assets).
- [x] **Hex Name Availability confirmed**:
  - Verified via Hex.pm API: `autonomic`, `autonomic_linux`, `autonomic_postgres`, and `autonomic_typesafe` are available for registration.

---

## 3. Package Boundaries & Invariants

- [x] **Topological Dependency Graph enforced**:
  - `autonomic`: Standalone core; no adapter dependencies.
  - `autonomic_linux`: Depends only on `autonomic`.
  - `autonomic_postgres`: Depends only on `autonomic`, `ecto_sql`, `postgrex`.
  - `autonomic_typesafe`: Depends only on `autonomic`, `typesafe_sdk`.
- [x] **No cross-adapter coupling**:
  - `autonomic_postgres` has zero dependencies on `autonomic_linux` or `autonomic_typesafe`.
  - `autonomic_linux` has zero dependencies on `autonomic_postgres` or `autonomic_typesafe`.
  - `autonomic_typesafe` has zero dependencies on `autonomic_linux` or `autonomic_postgres`.
- [x] **Cross-adapter tests isolated**:
  - `coding_agent_test.exs` moved to `integration/autonomic_acceptance/test/coding_agent_test.exs`.
  - `class4_horizon_test.exs` moved to `integration/autonomic_acceptance/test/class4_horizon_test.exs`.
- [x] **Automated boundary verification**:
  - `scripts/lint_package_boundaries.py` validates declared dependencies and boundary rules with zero violations.

---

## 4. Release Tooling & Staging Pipeline

- [x] **Release CLI (`scripts/release.py` / `scripts/release`)**:
  - `scripts/release check`: Pre-flight boundary and metadata check across all 4 packages.
  - `scripts/release stage [version]`: Deterministically copies packages to `_release_stage/[version]/` and rewrites local path dependencies to versioned Hex dependencies (`~> 0.1.0`).
  - `scripts/release build [version]`: Runs `mix hex.build` inside staging to generate official Hex package tarballs.
  - `scripts/release inspect [version]`: Unpacks generated tarballs and audits file contents (README, LICENSE, CHANGELOG, source code) and ensures no forbidden build artifacts are bundled (`_build`, `deps`, `.git`, `target`).
  - `scripts/release publish [package] [version]`: Guarded dry-run sequence preventing accidental publication.

---

## 5. Monorepo Orchestration & QC Runner

- [x] **Root QC CLI (`scripts/qc.py` / `scripts/qc`)**:
  - Supports `--strict` (release gate mode) and `--handoff` (records honest environmental gate status).
  - Supports `--package <name>`, `--include <tag>`, and `--exclude <tag>`.
  - Orchestrates:
    1. Static inventory & source contracts
    2. Secret scan
    3. Package boundary linting
    4. Hex release check & tarball inspection
    5. Dependency resolution (`mix deps.get`) across all packages
    6. Code formatting (`mix format --check-formatted`)
    7. Strict compilation (`mix compile --warnings-as-errors`)
    8. Unit & integration test execution (`mix test`)
    9. Strict static analysis (`mix credo --strict`)
    10. Type checking (`mix dialyzer`)
    11. Documentation build (`mix docs --warnings-as-errors`)
    12. Rust launcher formatting, clippy, and unit tests
    13. Real PostgreSQL integration gates & epoch fencing
    14. Ephemeral PostgreSQL database outage gate
    15. Live TypeSafe SDK evaluation gate
    16. Privileged Linux isolation gate
    17. End-to-end coding agent reference gate
    18. Host capability preflight

---

## 6. Helper Scripts & CI Workflows

- [x] `scripts/build_launcher.sh`: Updated for `packages/autonomic_linux/native/autonomic_launcher`.
- [x] `scripts/run_reference.sh`: Updated for `integration/autonomic_acceptance`.
- [x] `scripts/run_db_outage_gate.sh`: Updated for `packages/autonomic_postgres`.
- [x] `scripts/run_live_typesafe.sh`: Updated for `packages/autonomic_typesafe`.
- [x] `.github/workflows/ci.yml`: Updated for poncho monorepo matrix and release dry-run.
- [x] `.github/workflows/live-typesafe.yml`: Updated for `packages/autonomic_typesafe`.
- [x] `.github/workflows/privileged-linux.yml`: Updated for `packages/autonomic_linux` and acceptance suite.

---

## 7. Machine Verification Summary

| Gate / Command | Scope | Status | Notes |
| :--- | :--- | :--- | :--- |
| `scripts/lint_package_boundaries.py` | All packages | **PASS** | 0 boundary violations |
| `scripts/release check` | 4 packages | **PASS** | Metadata, licenses, changelogs verified |
| `scripts/release stage 0.1.0` | 4 packages | **PASS** | Rewrote path deps to `~> 0.1.0` |
| `scripts/release build 0.1.0` | 4 packages | **PASS** | Built 4 Hex `.tar` tarballs |
| `scripts/release inspect 0.1.0` | 4 packages | **PASS** | Unpacked and verified clean file trees |
| `mix compile --warnings-as-errors` | All projects | **PASS** | 0 warnings across monorepo |
| `mix format --check-formatted` | All projects | **PASS** | Fully formatted |
| `mix credo --strict` | 4 packages | **PASS** | 0 credo issues |
| `mix dialyzer` | 4 packages | **PASS** | 0 type errors across all packages |
| `mix docs --warnings-as-errors` | 4 packages | **PASS** | 0 docs warnings |
| `cargo test` | Launcher | **PASS** | 4 Rust tests passed |
| `scripts/run_db_outage_gate.sh` | Postgres | **PASS** | Ephemeral DB outage verified |


## Review corrections and independent verification

The follow-up review found and fixed issues missed by the first handoff:

| Requirement | Changed files | Verification |
| --- | --- | --- |
| Dependency-mode runtime defaults | `packages/autonomic/mix.exs` | Real PostgreSQL integration: 10 tests |
| Native prerequisite failures and bundled resolution | Linux Mix project, launcher, preflight, runtime config | Missing/failing Cargo probes; real containment: 3 tests |
| Current, path-free Hex staging | `scripts/release.py`, `scripts/test_release.py` | Tooling regression tests and fresh tar inspection |
| Outside-checkout installation | `scripts/verify_packages.py`, CI | Temporary signed Hex registry; resolve/compile/test/docs for all four packages |
| Honest QC and moved acceptance coverage | `scripts/qc.py`, `scripts/test_qc.py` | Strict QC; Class-4 acceptance executed separately |
| Clean delivery | `.gitignore`, archive below | Git-based ZIP excludes generated and secret files |
| Package CI and future release rehearsal | `.github/workflows/` | YAML parse; no publish steps |

See `HANDOFF.md` and `artifacts/conformance_report.json` for the final executed results.
