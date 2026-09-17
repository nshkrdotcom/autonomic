defmodule Autonomic.Umbrella.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/autonomic"
  @homepage_url "https://hex.pm/packages/autonomic"
  @docs_url "https://hexdocs.pm/autonomic"

  def project do
    [
      apps_path: "apps",
      name: "Autonomic Kernel",
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @homepage_url
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      qc: &qc/1
    ]
  end

  defp description do
    """
    Production-oriented BEAM/OTP autonomy kernel for running an untrusted coding
    worker inside a disposable Linux execution domain while keeping durable authority,
    policy, effects, verification, recovery, and audit state in a trusted control plane.
    """
  end

  defp package do
    [
      name: "autonomic",
      description: description(),
      readme: "README.md",
      files: ~w(
        apps
        assets
        config
        docs
        native
        scripts
        .formatter.exs
        CHANGELOG.md
        DELIVERY.json
        HANDOFF.md
        LICENSE
        README.md
        mix.exs
        mix.lock
      ),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Hex" => @homepage_url,
        "HexDocs" => @docs_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "License" => "#{@source_url}/blob/main/LICENSE"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Autonomic Kernel",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/autonomic.svg",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules()
    ]
  end

  defp extras do
    [
      "README.md": [filename: "readme", title: "Overview"],
      "CHANGELOG.md": [title: "Changelog"],
      LICENSE: [title: "License"],
      "HANDOFF.md": [title: "Handoff & Gates"],
      "docs/ARCHITECTURE.md": [title: "Architecture"],
      "docs/SECURITY.md": [title: "Security Model"],
      "docs/OPERATIONS.md": [title: "Operations Guide"],
      "docs/DEVELOPMENT.md": [title: "Development Guide"],
      "docs/PERSISTENCE_RECOVERY.md": [title: "Persistence & Recovery"],
      "docs/IMPLEMENTATION_CHECKLIST.md": [title: "Implementation Checklist"],
      "docs/EFFECT_ADAPTERS.md": [title: "Effect Adapters"],
      "docs/HOST_PROVISIONING.md": [title: "Host Provisioning"],
      "docs/TYPESAFE_SENSORS.md": [title: "TypeSafe Sensors"],
      "docs/runbooks/COMMIT_UNKNOWN.md": [title: "Runbook: Commit Unknown"],
      "docs/runbooks/DB_OUTAGE.md": [title: "Runbook: DB Outage"],
      "docs/runbooks/SANDBOX_ESCAPE.md": [title: "Runbook: Sandbox Escape"],
      "docs/runbooks/SEMANTIC_OUTAGE.md": [title: "Runbook: Semantic Outage"],
      "docs/spec/README.md": [filename: "spec-overview", title: "Spec: Overview"],
      "docs/spec/01_SYSTEM_ARCHITECTURE.md": [title: "Spec: System Architecture"],
      "docs/spec/02_SUBSYSTEM_SPECIFICATIONS.md": [title: "Spec: Subsystems"],
      "docs/spec/04_EFFECT_TRANSACTION_PROTOCOL.md": [title: "Spec: Effect Transactions"],
      "docs/spec/05_ECOSYSTEM_AND_DEPENDENCIES.md": [title: "Spec: Ecosystem"],
      "docs/spec/06_REFERENCE_IMPLEMENTATION_AND_SCENARIO.md": [title: "Spec: Reference Scenario"],
      "docs/spec/07_THREAT_MODEL_AND_SECURITY.md": [title: "Spec: Threat Model"],
      "docs/spec/08_DURABILITY_LEDGER_AND_RECOVERY.md": [title: "Spec: Durability & Recovery"],
      "docs/spec/09_TESTING_AND_CONFORMANCE.md": [title: "Spec: Testing & Conformance"],
      "docs/spec/10_IMPLEMENTATION_PLAN.md": [title: "Spec: Implementation Plan"],
      "docs/spec/11_ACCEPTANCE_GATES.md": [title: "Spec: Acceptance Gates"],
      "docs/spec/12_TYPESAFE_SDK_INTEGRATION.md": [title: "Spec: TypeSafe Integration"],
      "docs/spec/REVISION_NOTES_2026-09-17.md": [title: "Spec: Revision Notes"],
      "docs/spec/SOURCES_AND_VERSION_BASELINE.md": [title: "Spec: Sources & Baseline"]
    ]
  end

  defp groups_for_extras do
    [
      "Project Overview": [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "HANDOFF.md"
      ],
      "Architecture & Security": [
        "docs/ARCHITECTURE.md",
        "docs/SECURITY.md",
        "docs/PERSISTENCE_RECOVERY.md",
        "docs/IMPLEMENTATION_CHECKLIST.md"
      ],
      "Operations & Guides": [
        "docs/OPERATIONS.md",
        "docs/DEVELOPMENT.md",
        "docs/HOST_PROVISIONING.md",
        "docs/EFFECT_ADAPTERS.md",
        "docs/TYPESAFE_SENSORS.md"
      ],
      Runbooks: [
        "docs/runbooks/COMMIT_UNKNOWN.md",
        "docs/runbooks/DB_OUTAGE.md",
        "docs/runbooks/SANDBOX_ESCAPE.md",
        "docs/runbooks/SEMANTIC_OUTAGE.md"
      ],
      Specification: [
        "docs/spec/README.md",
        "docs/spec/01_SYSTEM_ARCHITECTURE.md",
        "docs/spec/02_SUBSYSTEM_SPECIFICATIONS.md",
        "docs/spec/04_EFFECT_TRANSACTION_PROTOCOL.md",
        "docs/spec/05_ECOSYSTEM_AND_DEPENDENCIES.md",
        "docs/spec/06_REFERENCE_IMPLEMENTATION_AND_SCENARIO.md",
        "docs/spec/07_THREAT_MODEL_AND_SECURITY.md",
        "docs/spec/08_DURABILITY_LEDGER_AND_RECOVERY.md",
        "docs/spec/09_TESTING_AND_CONFORMANCE.md",
        "docs/spec/10_IMPLEMENTATION_PLAN.md",
        "docs/spec/11_ACCEPTANCE_GATES.md",
        "docs/spec/12_TYPESAFE_SDK_INTEGRATION.md",
        "docs/spec/REVISION_NOTES_2026-09-17.md",
        "docs/spec/SOURCES_AND_VERSION_BASELINE.md"
      ]
    ]
  end

  defp groups_for_modules do
    [
      "Kernel & Lifecycle": [
        Autonomic.Application,
        Autonomic.EpisodeSupervisor,
        Autonomic.EpisodeController,
        Autonomic.EpisodeSpec,
        Autonomic.EpisodeCheckpoint,
        Autonomic.Runtime,
        Autonomic.SystemRegulator
      ],
      "Policy & Authority": [
        Autonomic.AuthorityGovernor,
        Autonomic.Policy,
        Autonomic.Capability,
        Autonomic.CapabilityLease,
        Autonomic.HumanApproval,
        Autonomic.VersionVector
      ],
      "Effect Broker & Adapters": [
        Autonomic.EffectBroker,
        Autonomic.EffectSocket,
        Autonomic.EffectState,
        Autonomic.EffectAdapter,
        Autonomic.ProposedEffect,
        Autonomic.Adapters.Artifact,
        Autonomic.Adapters.Git,
        Autonomic.Adapters.GitRemote,
        Autonomic.Adapters.HTTP,
        Autonomic.BoundedHTTP,
        Autonomic.RateLimiter
      ],
      "Homeostasis & Sensors": [
        Autonomic.Homeostat,
        Autonomic.HomeostaticState,
        Autonomic.SensorArray,
        Autonomic.SensorConsumer,
        Autonomic.SemanticSensor,
        Autonomic.SemanticObservation,
        Autonomic.ObservationFrame,
        Autonomic.Trajectory,
        Autonomic.TrajectoryAlert
      ],
      "Verification & Repair": [
        Autonomic.Verifier,
        Autonomic.VerificationRunner,
        Autonomic.RepairManager,
        Autonomic.SnapshotManager
      ],
      "Execution Domain": [
        Autonomic.ExecutionDomain,
        Autonomic.ExecutionDomain.Domain,
        Autonomic.ExecutionDomain.Spec,
        Autonomic.ExecutionDomain.Command,
        Autonomic.ExecutionDomain.Execution,
        Autonomic.ExecutionDomain.CheckpointRef
      ],
      "Linux Containment": [
        Autonomic.Linux.Application,
        Autonomic.Linux.Backend,
        Autonomic.Linux.Launcher,
        Autonomic.Linux.Preflight
      ],
      "TypeSafe Sensors": [
        Autonomic.Typesafe.Application,
        Autonomic.Typesafe.Bank,
        Autonomic.Typesafe.Evidence,
        Autonomic.Typesafe.Sensor,
        Autonomic.Typesafe.SensorBank
      ],
      "Store & Persistence": [
        Autonomic.Store,
        Autonomic.Store.Application,
        Autonomic.Store.Postgres,
        Autonomic.Store.Repo,
        Autonomic.Store.Schema.Episode,
        Autonomic.Store.Schema.EpisodeEvent,
        Autonomic.Store.Schema.CapabilityLease,
        Autonomic.Store.Schema.Checkpoint,
        Autonomic.Store.Schema.Effect,
        Autonomic.Store.Schema.EffectDecision,
        Autonomic.Store.Schema.ObservationFrame,
        Autonomic.Store.Schema.RecoveryRecord
      ],
      "Contracts & Serialization": [
        Autonomic.Contracts,
        Autonomic.Canonical,
        Autonomic.Payloads
      ]
    ]
  end

  defp qc(args) do
    {_, status} = System.cmd("python3", ["scripts/qc.py" | args], into: IO.stream())
    if status != 0, do: Mix.raise("QC did not pass; inspect artifacts/conformance_report.json")
  end
end
