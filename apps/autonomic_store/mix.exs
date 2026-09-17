defmodule Autonomic.Store.MixProject do
  use Mix.Project

  def project do
    [
      app: :autonomic_store,
      version: "0.1.0",
      elixir: "~> 1.20",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      start_permanent: Mix.env() == :prod,
      deps: [
        {:autonomic_kernel, in_umbrella: true},
        {:autonomic_linux, in_umbrella: true, only: :test},
        {:autonomic_typesafe, in_umbrella: true, only: :test},
        {:ecto_sql, "~> 3.13"},
        {:postgrex, "~> 0.21"}
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl], mod: {Autonomic.Store.Application, []}]
end
