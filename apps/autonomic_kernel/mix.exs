defmodule Autonomic.Kernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :autonomic_kernel,
      version: "0.1.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      start_permanent: Mix.env() == :prod,
      deps: [
        {:finch, "~> 0.23"},
        {:jason, "~> 1.4"},
        {:gen_stage, "~> 1.3"},
        {:telemetry, "~> 1.3"}
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl, :inets], mod: {Autonomic.Application, []}]
end
