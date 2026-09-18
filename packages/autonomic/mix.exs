defmodule Autonomic.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/autonomic"
  @homepage_url "https://hex.pm/packages/autonomic"
  @docs_url "https://hexdocs.pm/autonomic"

  def project do
    [
      app: :autonomic,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Autonomic",
      source_url: @source_url,
      homepage_url: @homepage_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets],
      mod: {Autonomic.Application, []},
      env: [
        state_dir: "var",
        effect_adapters: %{
          "git_commit" => {Autonomic.Adapters.Git, :class_3_authoritative_external_mutation},
          "git_remote" =>
            {Autonomic.Adapters.GitRemote, :class_3_authoritative_external_mutation},
          "http_read" => {Autonomic.Adapters.HTTP, :class_2_external_observable_or_compensatable},
          "http_mutation" => {Autonomic.Adapters.HTTP, :class_3_authoritative_external_mutation},
          "publish" => {Autonomic.Adapters.Artifact, :class_4_irreversible_high_impact}
        },
        targets: %{},
        policy_keys: %{},
        decision_keys: %{},
        effect_concurrency: 8,
        sensor_queue: 64,
        speculation_ms: 15_000,
        max_repairs: 3,
        owner_ttl_ms: 15_000,
        automatic_verification: true
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:finch, "~> 0.23"},
      {:jason, "~> 1.4"},
      {:gen_stage, "~> 1.3"},
      {:telemetry, "~> 1.3"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Production-oriented BEAM/OTP control plane and kernel for untrusted coding workers
    inside disposable execution domains with durable authority, effect brokering,
    homeostatic regulation, and verification recovery.
    """
  end

  defp package do
    [
      name: "autonomic",
      description: description(),
      readme: "README.md",
      files: ~w(lib config assets guides .formatter.exs CHANGELOG.md LICENSE README.md mix.exs),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "HexDocs" => @docs_url,
        "Changelog" => "#{@source_url}/blob/main/packages/autonomic/CHANGELOG.md",
        "License" => "#{@source_url}/blob/main/packages/autonomic/LICENSE"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Autonomic",
      source_ref: "v#{@version}-autonomic",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/autonomic.svg",
      extras: [
        "README.md": [filename: "readme", title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "guides/01-architecture.md": [title: "Architecture"],
        "guides/02-invariants.md": [title: "Non-Negotiable Invariants"],
        "guides/03-effect-broker.md": [title: "EffectBroker & Horizons"],
        "guides/04-adapter-authoring.md": [title: "Effect Adapter Authoring"],
        "guides/05-typesafe-control-loop.md": [title: "TypeSafe Control Loop"]
      ],
      groups_for_extras: [
        Overview: ["README.md", "CHANGELOG.md", "LICENSE"],
        Guides: [
          "guides/01-architecture.md",
          "guides/02-invariants.md",
          "guides/03-effect-broker.md",
          "guides/04-adapter-authoring.md",
          "guides/05-typesafe-control-loop.md"
        ]
      ],
      groups_for_modules: [
        "Core & Lifecycle": [
          Autonomic.Application,
          Autonomic.EpisodeSupervisor,
          Autonomic.EpisodeController,
          Autonomic.EpisodeSpec,
          Autonomic.EpisodeCheckpoint,
          Autonomic.Runtime,
          Autonomic.SystemRegulator
        ],
        "Authority & Policy": [
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
        "Contracts & Extension Behaviours": [
          Autonomic.Contracts,
          Autonomic.Canonical,
          Autonomic.Payloads,
          Autonomic.Store,
          Autonomic.ExecutionDomain
        ]
      ]
    ]
  end
end
