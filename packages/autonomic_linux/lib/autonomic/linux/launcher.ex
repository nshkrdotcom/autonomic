defmodule Autonomic.Linux.Launcher do
  @moduledoc """
  Bounded versioned OTP Port client for the privileged external isolation launcher.

  Each request uses an independent launcher daemon process. Domain state is persisted
  by the launcher and revalidated on every lifecycle request, so a blocked `exec`
  can never serialize or delay a concurrent cgroup `destroy`/freeze operation.
  """
  use GenServer

  alias Autonomic.Canonical

  @protocol 1
  @max_request 1_048_576
  @max_reply 4_194_304

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def request(action, fields \\ %{}, timeout \\ 60_000)
      when is_binary(action) and is_map(fields) do
    with true <- enabled?(),
         request_id = Canonical.id(),
         request =
           Map.merge(fields, %{
             "protocol" => @protocol,
             "request_id" => request_id,
             "action" => action
           }),
         encoded when byte_size(encoded) <= @max_request <- Jason.encode!(request),
         {:ok, port} <- open_port(),
         result <- exchange(port, encoded, request_id, timeout) do
      result
    else
      false -> {:error, :linux_backend_disabled_or_request_too_large}
      {:error, _} = error -> error
      other -> {:error, {:launcher_protocol_error, other}}
    end
  rescue
    error -> {:error, {:launcher_request_failed, error}}
  end

  def available?, do: GenServer.call(__MODULE__, :available?)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:available?, _from, state) do
    path = executable()
    {:reply, enabled?() and File.exists?(path), state}
  end

  defp exchange(port, encoded, request_id, timeout) do
    true = Port.command(port, encoded)

    case await(port, request_id, timeout) do
      {:ok, response} -> normalize_response(response)
      {:error, _} = error -> error
    end
  after
    if Port.info(port) != nil, do: Port.close(port)
  end

  defp open_port do
    executable = executable()

    cond do
      not File.exists?(executable) ->
        {:error, {:launcher_not_found, executable}}

      Application.get_env(:autonomic_linux, :sudo, true) ->
        spawn_port("/usr/bin/sudo", ["-n", "--", executable, "daemon"])

      true ->
        spawn_port(executable, ["daemon"])
    end
  end

  defp spawn_port(program, args) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(program)},
        [
          :binary,
          {:packet, 4},
          :exit_status,
          :use_stdio,
          args: Enum.map(args, &String.to_charlist/1)
        ]
      )

    {:ok, port}
  rescue
    error -> {:error, {:launcher_start_failed, error}}
  end

  defp await(port, request_id, timeout) do
    receive do
      {^port, {:data, data}} when byte_size(data) <= @max_reply ->
        case Jason.decode(data) do
          {:ok, %{"request_id" => ^request_id} = response} -> {:ok, response}
          {:ok, _} -> {:error, :launcher_request_id_mismatch}
          {:error, _} -> {:error, {:invalid_launcher_json, String.slice(data, 0, 1024)}}
        end

      {^port, {:data, _oversize}} ->
        {:error, :launcher_reply_too_large}

      {^port, {:exit_status, status}} ->
        {:error, {:launcher_exited, status}}
    after
      timeout -> {:error, :launcher_timeout}
    end
  end

  defp normalize_response(%{"ok" => true, "result" => result}), do: {:ok, result}

  defp normalize_response(%{"ok" => false, "error" => error}),
    do: {:error, {:launcher_error, error}}

  defp normalize_response(_), do: {:error, :invalid_launcher_response}

  @doc "Resolves the configured launcher or the executable installed with this package."
  def executable do
    System.get_env("AUTONOMIC_LAUNCHER") ||
      Application.get_env(:autonomic_linux, :executable) ||
      default_executable()
  end

  defp default_executable do
    priv_binary =
      case :code.priv_dir(:autonomic_linux) do
        {:error, _} -> Path.expand("priv/autonomic_launcher")
        dir -> Path.join(dir, "autonomic_launcher")
      end

    if File.exists?(priv_binary) do
      priv_binary
    else
      "/usr/local/libexec/autonomic_launcher"
    end
  end

  defp enabled?, do: Application.get_env(:autonomic_linux, :enabled, false)
end
