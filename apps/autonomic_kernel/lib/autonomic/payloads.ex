defmodule Autonomic.Payloads do
  @moduledoc "Episode-scoped content-addressed bytes in a trusted, non-mounted object directory."
  alias Autonomic.{Canonical, Runtime}

  @id ~r/\A[0-9a-f]{32}\z/
  @digest ~r/\A[0-9a-f]{64}\z/

  @spec put(String.t(), binary(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def put(episode, bytes, limit \\ 1_048_576)
      when is_binary(bytes) and is_integer(limit) and limit > 0 do
    cond do
      not Regex.match?(@id, episode) ->
        {:error, :invalid_episode_id}

      byte_size(bytes) > limit ->
        {:error, :payload_too_large}

      true ->
        digest = Canonical.hash(bytes)
        dir = Path.join([Runtime.root(), "payloads", episode])
        File.mkdir_p!(dir)
        File.chmod!(dir, 0o700)
        path = Path.join(dir, digest)

        if File.exists?(path) do
          verify_existing(path, digest)
        else
          write_new(path, dir, bytes, digest)
        end
    end
  end

  @spec get(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get(episode, digest) do
    with true <- Regex.match?(@id, episode) and Regex.match?(@digest, digest),
         {:ok, bytes} <- File.read(Path.join([Runtime.root(), "payloads", episode, digest])),
         true <- Canonical.hash(bytes) == digest do
      {:ok, bytes}
    else
      _ -> {:error, :payload_missing_or_corrupt}
    end
  end

  defp verify_existing(path, digest) do
    with {:ok, bytes} <- File.read(path),
         true <- Canonical.hash(bytes) == digest do
      {:ok, digest}
    else
      _ -> {:error, :payload_collision_or_corruption}
    end
  end

  defp write_new(path, dir, bytes, digest) do
    tmp = path <> "." <> Canonical.id()

    result =
      with {:ok, io} <- :file.open(String.to_charlist(tmp), [:write, :binary, :exclusive]),
           :ok <- :file.write(io, bytes),
           :ok <- :file.sync(io),
           :ok <- :file.close(io),
           :ok <- File.rename(tmp, path),
           :ok <- sync_directory(dir) do
        {:ok, digest}
      end

    if match?({:error, _}, result), do: File.rm(tmp)
    result
  end

  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  def sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, fd} ->
        result = :file.sync(fd)
        :file.close(fd)
        result

      error ->
        error
    end
  end
end
