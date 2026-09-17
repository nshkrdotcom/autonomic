defmodule AutonomicExamplesDev.MixProject do
  use Mix.Project

  def project do
    [
      app: :autonomic_examples_dev,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Autonomic.Dev.Application, []}
    ]
  end

  defp deps do
    [
      {:autonomic, path: "../../packages/autonomic"}
    ]
  end
end
