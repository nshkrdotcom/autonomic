defmodule Autonomic.Acceptance.MixProject do
  use Mix.Project

  def project do
    [
      app: :autonomic_acceptance,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:autonomic, path: "../../packages/autonomic"},
      {:autonomic_linux, path: "../../packages/autonomic_linux"},
      {:autonomic_postgres, path: "../../packages/autonomic_postgres"},
      {:autonomic_typesafe, path: "../../packages/autonomic_typesafe"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"}
    ]
  end
end
