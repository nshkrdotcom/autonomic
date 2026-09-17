defmodule Autonomic.Linux.ContainmentTest do
  use ExUnit.Case, async: false

  alias Autonomic.Linux.{Launcher, Preflight}

  @moduletag :linux
  @moduletag timeout: 180_000

  setup do
    assert {:ok, _} = Preflight.verify()

    root = Path.join(System.tmp_dir!(), "autonomic-linux-#{System.unique_integer([:positive])}")
    lower = Path.join(root, "lower")
    state_root = Path.join(root, "state")
    socket_path = Path.join(root, "effect.sock")
    File.mkdir_p!(lower)
    File.mkdir_p!(state_root)
    File.write!(Path.join(lower, "README"), "immutable base\n")

    {:ok, listener} =
      :gen_tcp.listen(0,
        binary: true,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ifaddr: {:local, String.to_charlist(socket_path)}
      )

    episode_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    fields = %{
      "episode_id" => episode_id,
      "epoch" => 1,
      "workspace" => %{"lower" => lower, "base_ref" => "fixture-base"},
      "hard_envelope" => %{"max_effect_class" => 3, "capabilities" => []},
      "resource_limits" => %{"memory_mb" => 128, "pids" => 48, "cpu_quota" => 1},
      "environment" => %{},
      "effect_socket" => socket_path,
      "rootfs" => Application.fetch_env!(:autonomic_linux, :rootfs),
      "state_root" => state_root
    }

    assert {:ok, domain} = Launcher.request("create_domain", fields, 90_000)

    on_exit(fn ->
      _ =
        Launcher.request(
          "destroy_domain",
          identity(domain, episode_id, 1, state_root),
          15_000
        )

      :gen_tcp.close(listener)
      File.rm_rf(root)
    end)

    {:ok,
     root: root,
     lower: lower,
     state_root: state_root,
     socket_path: socket_path,
     listener: listener,
     episode_id: episode_id,
     domain: domain}
  end

  test "namespaces, cgroup limits, no_new_privs, AF_UNIX and direct-network denial are real", ctx do
    domain = ctx.domain

    python = """
    import json, os, socket
    u = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    u.settimeout(2)
    u.connect('/run/autonomic/effect.sock')
    u.close()
    status = open('/proc/self/status').read()
    print(json.dumps({
      'pid': os.getpid(),
      'net': os.readlink('/proc/self/ns/net'),
      'mnt': os.readlink('/proc/self/ns/mnt'),
      'user': os.readlink('/proc/self/ns/user'),
      'pidns': os.readlink('/proc/self/ns/pid'),
      'no_new_privs': [line for line in status.splitlines() if line.startswith('NoNewPrivs:')][0],
      'docker_socket_present': os.path.exists('/var/run/docker.sock')
    }))
    """

    assert {:ok, result} = exec(ctx, ["/usr/bin/python3", "-c", python])
    assert result["exit_status"] == 0
    payload = result["stdout"] |> String.trim() |> Jason.decode!()
    assert payload["no_new_privs"] =~ "1"
    refute payload["docker_socket_present"]

    host_net = System.cmd("/usr/bin/readlink", ["/proc/self/ns/net"]) |> elem(0) |> String.trim()
    host_mnt = System.cmd("/usr/bin/readlink", ["/proc/self/ns/mnt"]) |> elem(0) |> String.trim()
    refute payload["net"] == host_net
    refute payload["mnt"] == host_mnt

    cgroup = domain["cgroup"]
    assert String.trim(File.read!(Path.join(cgroup, "memory.max"))) == Integer.to_string(128 * 1024 * 1024)
    assert String.trim(File.read!(Path.join(cgroup, "pids.max"))) == "48"
    assert File.read!(Path.join(cgroup, "cpu.max")) |> String.trim() == "100000 100000"

    inet = "import socket; socket.socket(socket.AF_INET, socket.SOCK_STREAM)"
    assert {:ok, denied} = exec(ctx, ["/usr/bin/python3", "-c", inet])
    assert denied["seccomp_violation"] == true
    assert denied["termination_signal"] == 31
    assert denied["exit_status"] != 0
  end

  test "cgroup-wide destroy interrupts a fork tree and proves the old domain empty", ctx do
    task =
      Task.async(fn ->
        exec(ctx, ["/bin/sh", "-c", "sleep 300 & sleep 300 & wait"], 180_000)
      end)

    Process.sleep(300)

    assert {:ok, before} =
             Launcher.request(
               "inspect_domain",
               identity(ctx.domain, ctx.episode_id, 1, ctx.state_root)
             )

    assert length(before["pids"]) >= 2

    assert {:ok, destroyed} =
             Launcher.request(
               "destroy_domain",
               identity(ctx.domain, ctx.episode_id, 1, ctx.state_root),
               30_000
             )

    assert destroyed["empty"] == true
    assert destroyed["cgroup_removed"] == true
    assert destroyed["killed"] != []

    _ = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
  end

  test "checkpoint restore discards mutations from the old upperdir", ctx do
    assert {:ok, checkpoint} =
             Launcher.request(
               "checkpoint_fs",
               identity(ctx.domain, ctx.episode_id, 1, ctx.state_root),
               30_000
             )

    assert {:ok, mutation} = exec(ctx, ["/bin/sh", "-c", "printf tainted > /workspace/tainted.txt"])
    assert mutation["exit_status"] == 0

    assert {:ok, _} =
             Launcher.request(
               "destroy_domain",
               identity(ctx.domain, ctx.episode_id, 1, ctx.state_root),
               30_000
             )

    restore = %{
      "episode_id" => ctx.episode_id,
      "epoch" => 2,
      "checkpoint_ref" => checkpoint["checkpoint_ref"],
      "checkpoint_digest" => checkpoint["digest"],
      "rootfs" => Application.fetch_env!(:autonomic_linux, :rootfs),
      "workspace_lower" => ctx.lower,
      "effect_socket" => ctx.socket_path,
      "resource_limits" => %{"memory_mb" => 128, "pids" => 48, "cpu_quota" => 1},
      "state_root" => ctx.state_root
    }

    assert {:ok, restored} = Launcher.request("restore_domain", restore, 90_000)

    restored_ctx = %{ctx | domain: restored}
    assert {:ok, clean} = exec(restored_ctx, ["/bin/sh", "-c", "test ! -e /workspace/tainted.txt"])
    assert clean["exit_status"] == 0

    assert {:ok, proof} =
             Launcher.request(
               "destroy_domain",
               identity(restored, ctx.episode_id, 2, ctx.state_root),
               30_000
             )

    assert proof["empty"] == true
  end

  defp exec(ctx, argv, timeout \\ 30_000) do
    fields =
      identity(ctx.domain, ctx.episode_id, ctx.domain["epoch"] || 1, ctx.state_root)
      |> Map.merge(%{
        "argv" => argv,
        "cwd" => "/workspace",
        "env" => %{},
        "stdin_b64" => nil,
        "timeout_ms" => timeout
      })

    Launcher.request("exec", fields, timeout + 10_000)
  end

  defp identity(domain, episode_id, epoch, state_root) do
    %{
      "domain_id" => domain["domain_id"],
      "episode_id" => episode_id,
      "epoch" => epoch,
      "state_root" => state_root
    }
  end
end
