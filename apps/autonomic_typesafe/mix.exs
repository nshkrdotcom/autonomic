defmodule Autonomic.Typesafe.MixProject do
  use Mix.Project
  def project do
    [app: :autonomic_typesafe, version: "0.1.0", elixir: "~> 1.20",
     build_path: "../../_build", config_path: "../../config/config.exs",
     deps_path: "../../deps", lockfile: "../../mix.lock",
     elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
     start_permanent: Mix.env() == :prod, deps: [{:autonomic_kernel, in_umbrella: true}, sdk_dependency()]]
  end
  def application, do: [extra_applications: [:logger, :crypto, :ssl], mod: {Autonomic.Typesafe.Application, []}]

  defp sdk_dependency do
    case System.get_env("TYPESAFE_SDK_PATH") do
      nil -> {:typesafe_sdk, "~> 0.2.0"}
      path -> {:typesafe_sdk, path: Path.expand(path)}
    end
  end
end
