defmodule Autonomic.Typesafe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/autonomic"
  @homepage_url "https://hex.pm/packages/autonomic_typesafe"
  @docs_url "https://hexdocs.pm/autonomic_typesafe"

  def project do
    [
      app: :autonomic_typesafe,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Autonomic TypeSafe",
      source_url: @source_url,
      homepage_url: @homepage_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Autonomic.Typesafe.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:autonomic, path: "../autonomic"},
      sdk_dependency(),
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp sdk_dependency do
    case System.get_env("TYPESAFE_SDK_PATH") do
      nil -> {:typesafe_sdk, "~> 0.4.0"}
      path -> {:typesafe_sdk, path: Path.expand(path)}
    end
  end

  defp description do
    """
    TypeSafe/Jev semantic sensor bank backend for the Autonomic Kernel architecture,
    providing evidence redaction, drift monitoring, and anomaly detection.
    """
  end

  defp package do
    [
      name: "autonomic_typesafe",
      description: description(),
      readme: "README.md",
      files: ~w(
        lib
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
        "Changelog" => "#{@source_url}/blob/main/packages/autonomic_typesafe/CHANGELOG.md",
        "License" => "#{@source_url}/blob/main/LICENSE"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Autonomic TypeSafe",
      source_ref: "autonomic_typesafe-v#{@version}",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/autonomic.svg",
      extras: [
        "README.md": [filename: "readme", title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "guides/01-semantic-sensors.md": [title: "Semantic Sensors"],
        "guides/02-typesafe-sdk-integration.md": [title: "TypeSafeSDK Integration"],
        "guides/03-evidence-budgeting-and-drift.md": [title: "Evidence Budgeting & Drift"]
      ],
      groups_for_extras: [
        Overview: ["README.md", "CHANGELOG.md", "LICENSE"],
        Guides: [
          "guides/01-semantic-sensors.md",
          "guides/02-typesafe-sdk-integration.md",
          "guides/03-evidence-budgeting-and-drift.md"
        ]
      ],
      groups_for_modules: [
        "Sensor Bank": [
          Autonomic.Typesafe.Application,
          Autonomic.Typesafe.Bank,
          Autonomic.Typesafe.Evidence,
          Autonomic.Typesafe.Sensor,
          Autonomic.Typesafe.SensorBank
        ]
      ]
    ]
  end
end
