defmodule Autonomic.Linux.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nshkrdotcom/autonomic"
  @homepage_url "https://hex.pm/packages/autonomic_linux"
  @docs_url "https://hexdocs.pm/autonomic_linux"

  def project do
    [
      app: :autonomic_linux,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Autonomic Linux",
      source_url: @source_url,
      homepage_url: @homepage_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Autonomic.Linux.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:autonomic, path: "../autonomic"},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "compile.native": &compile_native/1,
      compile: ["compile.native", "compile"]
    ]
  end

  defp compile_native(_) do
    manifest = Path.expand("native/autonomic_launcher/Cargo.toml", __DIR__)
    priv_dir = Path.expand("priv", __DIR__)
    File.mkdir_p!(priv_dir)

    cargo =
      System.find_executable("cargo") ||
        Mix.raise("Rust/Cargo is required to build autonomic_linux")

    target_dir = Path.expand("native/autonomic_launcher/target", __DIR__)

    unless File.regular?(manifest), do: Mix.raise("Missing native launcher sources: #{manifest}")

    case System.cmd(
           cargo,
           [
             "build",
             "--locked",
             "--release",
             "--manifest-path",
             manifest,
             "--target-dir",
             target_dir
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        built_binary = Path.join(target_dir, "release/autonomic_launcher")
        dest = Path.join(priv_dir, "autonomic_launcher")
        File.cp!(built_binary, dest)
        File.chmod!(dest, 0o755)

      {output, status} ->
        Mix.raise("Native launcher build failed (exit #{status}):\n#{output}")
    end
  end

  defp description do
    """
    Linux isolation execution domain backend for the Autonomic Kernel architecture,
    providing cgroup v2, namespaces, seccomp filtering, and overlayfs sandboxing.
    """
  end

  defp package do
    [
      name: "autonomic_linux",
      description: description(),
      readme: "README.md",
      files: ~w(
        lib
        native/autonomic_launcher/src
        native/autonomic_launcher/Cargo.toml
        native/autonomic_launcher/Cargo.lock
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
        "Changelog" => "#{@source_url}/blob/main/packages/autonomic_linux/CHANGELOG.md",
        "License" => "#{@source_url}/blob/main/LICENSE"
      },
      maintainers: ["nshkrdotcom"]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Autonomic Linux",
      source_ref: "autonomic_linux-v#{@version}",
      source_url: @source_url,
      homepage_url: @docs_url,
      assets: %{"assets" => "assets"},
      logo: "assets/autonomic.svg",
      extras: [
        "README.md": [filename: "readme", title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"],
        LICENSE: [title: "License"],
        "guides/01-linux-isolation.md": [title: "Linux Isolation"],
        "guides/02-launcher-protocol.md": [title: "Launcher Protocol"],
        "guides/03-host-provisioning.md": [title: "Host Provisioning"]
      ],
      groups_for_extras: [
        Overview: ["README.md", "CHANGELOG.md", "LICENSE"],
        Guides: [
          "guides/01-linux-isolation.md",
          "guides/02-launcher-protocol.md",
          "guides/03-host-provisioning.md"
        ]
      ],
      groups_for_modules: [
        "Linux Backend": [
          Autonomic.Linux.Application,
          Autonomic.Linux.Backend,
          Autonomic.Linux.Launcher,
          Autonomic.Linux.Preflight
        ]
      ]
    ]
  end
end
