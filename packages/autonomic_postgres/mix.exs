defmodule Autonomic.Postgres.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/autonomic"
  @homepage_url "https://hex.pm/packages/autonomic_postgres"
  @docs_url "https://hexdocs.pm/autonomic_postgres"

  def project do
    [
      app: :autonomic_postgres,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Autonomic Postgres",
      source_url: @source_url,
      homepage_url: @homepage_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Autonomic.Postgres.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      autonomic_dependency(),
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp autonomic_dependency do
    case System.get_env("AUTONOMIC_PATH") do
      nil ->
        if Mix.env() == :prod or System.get_env("HEX_BUILD") == "true" do
          {:autonomic, "~> 0.1.0"}
        else
          {:autonomic, "~> 0.1.0", path: "../autonomic"}
        end

      path ->
        {:autonomic, "~> 0.1.0", path: Path.expand(path)}
    end
  end

  defp description do
    """
    PostgreSQL durable authority store, Ecto repository, transactional ledger,
    and epoch fencing backend for the Autonomic Kernel architecture.
    """
  end

  defp package do
    [
      name: "autonomic_postgres",
      description: description(),
      readme: "README.md",
      files: ~w(
        lib
        priv
        config
        assets
        guides
        .formatter.exs
        CHANGELOG.md
        LICENSE
        README.md
        mix.exs
      ),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "HexDocs" => @docs_url,
        "Changelog" => "#{@source_url}/blob/main/packages/autonomic_postgres/CHANGELOG.md",
        "License" => "#{@source_url}/blob/main/packages/autonomic_postgres/LICENSE"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Autonomic Postgres",
      source_ref: "autonomic_postgres-v#{@version}",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/autonomic_postgres.svg",
      extras: [
        "README.md": [filename: "readme", title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "guides/01-postgres-authority.md": [title: "PostgreSQL Authority"],
        "guides/02-schema-model.md": [title: "Schema Model"],
        "guides/03-epoch-fencing-and-recovery.md": [title: "Epoch Fencing & Recovery"]
      ],
      groups_for_extras: [
        Overview: ["README.md", "CHANGELOG.md", "LICENSE"],
        Guides: [
          "guides/01-postgres-authority.md",
          "guides/02-schema-model.md",
          "guides/03-epoch-fencing-and-recovery.md"
        ]
      ],
      groups_for_modules: [
        "Store Implementation": [
          Autonomic.Postgres.Application,
          Autonomic.Store.Postgres,
          Autonomic.Store.Repo
        ],
        Schemas: [
          Autonomic.Store.Schema.Episode,
          Autonomic.Store.Schema.CapabilityLease,
          Autonomic.Store.Schema.Checkpoint,
          Autonomic.Store.Schema.Effect,
          Autonomic.Store.Schema.EffectDecision,
          Autonomic.Store.Schema.EpisodeEvent,
          Autonomic.Store.Schema.ObservationFrame,
          Autonomic.Store.Schema.RecoveryRecord
        ]
      ]
    ]
  end
end
