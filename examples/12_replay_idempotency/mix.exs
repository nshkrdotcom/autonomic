defmodule AutonomicExample12.MixProject do
  use Mix.Project

  def project do
    [
      app: :autonomic_example_12,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :autonomic, :autonomic_examples_dev]]
  end

  defp aliases, do: [run: ["deps.get", "run run.exs"]]

  defp deps do
    [
      {:autonomic, path: "../../packages/autonomic"},
      {:autonomic_examples_dev, path: "../dev_stack"}
    ]
  end
end
