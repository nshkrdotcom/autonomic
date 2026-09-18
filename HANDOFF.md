# Autonomic Poncho migration verification

Date: 2026-09-17

> **Historical verification notice (TypeSafe upgrade):** this document records the
> pre-TypeSafeSDK-0.4 Poncho migration verification. The TypeSafe-specific test counts,
> live artifact and release-ready report described below were invalidated by the
> greenfield TypeSafeSDK 0.4.0 integration change. For current source and required
> re-verification steps, use `HANDOFF_TYPESAFE_0.4.0.md`. Do not restore 0.2/0.3
> compatibility.

## Repository state

The umbrella is removed. The four standalone public projects are
`packages/autonomic`, `packages/autonomic_linux`, `packages/autonomic_postgres`,
and `packages/autonomic_typesafe`, each at 0.1.0 with its own lockfile, metadata,
license, README, guides and build state. The private project is
`integration/autonomic_acceptance`.

Each adapter depends on core; adapters have no production dependencies on one
another. PostgreSQL additionally uses Ecto/Postgrex; TypeSafe uses TypeSafeSDK.
Core owns the implementation-independent contracts. Linux owns and compiles its
Rust launcher. No package or release was published.

Hex API checks on this date returned HTTP 404 for all four preferred names.
These are availability observations, not reservations; exact timestamps are in
`artifacts/package_graph.json`.

## Review fixes

- Core defaults now live in OTP application metadata, so installations as a
  dependency receive them; operator configuration still overrides them.
- Native compilation uses Cargo's lockfile, fails clearly on missing tools/build
  errors, and resolves the package-local executable consistently with preflight.
- Standalone Linux gates honor runtime environment variables. The obsolete root
  Elixir config was removed; composed runtime config belongs to acceptance.
- Staging strips the TypeSafe development override, rejects mismatched core
  versions and residual workspace paths, excludes generated files, and rebuilds
  from current source before inspection. Adapter patch versions remain independent.
- QC fails on executed errors even in handoff mode, rejects empty dedicated Mix
  gates, and actually executes the moved Class-4 acceptance test.
- Independent verification installs the unpublished core from a temporary signed
  Hex registry outside the checkout. No user Hex configuration is modified.
- CI has package, acceptance, native, Hex and isolated-installation jobs. Tagged
  release rehearsal validates tags and runs strict QC without publishing.

## Verification

Final results and command/log hashes are recorded in
`artifacts/conformance_report.json`. The complete verification command is:

```bash
AUTONOMIC_LINUX=1 \
AUTONOMIC_TEST_DATABASE_URL=ecto://postgres@127.0.0.1:55439/autonomic_test \
./scripts/qc --strict
```

The database was a real disposable PostgreSQL 18 cluster on localhost. The host
provides sudo, cgroup v2, namespaces, overlayfs and `/opt/autonomic/rootfs`; the
launcher was built from the migrated package. TypeSafe live evaluation used the
existing configured credential, which is not included in deliverables.

All four packages were checked with dependency resolution, formatting,
warnings-as-errors compilation, ExUnit, strict Credo, Dialyzer and
warnings-as-errors ExDoc. Portable Linux/PostgreSQL test invocations exclude
privileged/database tests; the explicit gates below execute them separately.

- Core: 10 tests.
- TypeSafe deterministic SDK seam: 7 tests; live evaluation: 1 test.
- PostgreSQL authority, races, AF_UNIX, reconciliation and load: 10 tests.
- Database outage: 1 real ephemeral-server fault-injection test.
- Linux containment: 3 privileged tests.
- Acceptance: 1 Class-4 horizon test and 2 complete normal/hostile repair scenarios.
- Rust: formatting, strict Clippy and 4 unit tests.
- Release/QC tooling: 3 Python regression tests, boundary checks and fresh Hex builds.
- All four Hex archives inspected for required files and absence of workspace
  dependency paths, umbrella settings and generated artifacts.

Additional independent-installation command:

```bash
uv run --no-project python scripts/verify_packages.py
```

This rebuilds tarballs and resolves, compiles, runs package-local tests and builds
docs outside the source tree. Only a temporary `repo:` override points the core
requirement at the local registry; distribution tarballs are not modified. Real
host-specific integrations are covered by strict QC above.

## Delivery and Git

The complete source archive is `artifacts/autonomic_poncho_monorepo.zip`, generated
from the final Git file inventory. It excludes dependency/build/native output,
release staging, temporary databases, credentials and the Git database. The ZIP is
an ignored delivery artifact; source and verification reports are committed.

The migration and review fixes are committed and pushed together as requested.
The final response records the commit SHA. No tags or public releases were created.
