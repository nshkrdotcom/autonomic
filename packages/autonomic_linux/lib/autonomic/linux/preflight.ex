defmodule Autonomic.Linux.Preflight do
  @moduledoc "Host prerequisite checks for the namespace backend."

  def report do
    cgroup = "/sys/fs/cgroup/cgroup.controllers"

    %{
      linux: match?({:unix, :linux}, :os.type()),
      cgroup_v2: File.exists?(cgroup),
      cgroup_controllers: read(cgroup),
      user_namespaces: read("/proc/sys/user/max_user_namespaces"),
      unshare: System.find_executable("unshare"),
      nsenter: System.find_executable("nsenter"),
      mount: System.find_executable("mount"),
      launcher: Autonomic.Linux.Launcher.executable(),
      rootfs: Application.get_env(:autonomic_linux, :rootfs),
      enabled: Application.get_env(:autonomic_linux, :enabled, false)
    }
  end

  def verify do
    r = report()
    required = [:linux, :cgroup_v2, :unshare, :nsenter, :mount, :launcher, :rootfs]
    missing = Enum.filter(required, fn key -> r[key] in [false, nil, ""] end)
    if missing == [], do: {:ok, r}, else: {:error, {:missing_prerequisites, missing, r}}
  end

  defp read(path) do
    case File.read(path) do
      {:ok, data} -> String.trim(data)
      _ -> nil
    end
  end
end
