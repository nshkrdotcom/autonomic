defmodule Autonomic.Umbrella.MixProject do
  use Mix.Project
  def project do
    [apps_path: "apps", version: "0.1.0", elixir: "~> 1.20",
     start_permanent: Mix.env() == :prod,
     deps: [{:credo, "~> 1.7", only: [:dev, :test], runtime: false},
            {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
            {:ex_doc, "~> 0.40", only: :dev, runtime: false}],
     aliases: [qc: &qc/1],
     docs: [main: "readme", extras: ["README.md", "docs/ARCHITECTURE.md",
       "docs/SECURITY.md", "docs/OPERATIONS.md", "docs/DEVELOPMENT.md"]]]
  end
  defp qc(args) do
    {_, status} = System.cmd("python3", ["scripts/qc.py" | args], into: IO.stream())
    if status != 0, do: Mix.raise("QC did not pass; inspect artifacts/conformance_report.json")
  end
end
