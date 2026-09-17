defmodule Autonomic.Adapters.Artifact do
  @moduledoc "Content-addressed artifact publisher. Target directory is trusted configuration, never worker input."
  @behaviour Autonomic.EffectAdapter

  alias Autonomic.{Canonical, Payloads}

  @impl true
  def validate(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         dir when is_binary(dir) <- Map.get(target, "directory"),
         name when is_binary(name) <- Map.get(effect.target, "name"),
         true <- safe_name?(name),
         {:ok, bytes} <- Payloads.get(effect.episode_id, effect.payload_ref),
         true <- byte_size(bytes) <= Map.get(target, "max_bytes", 16_777_216) do
      :ok
    else
      false -> {:error, :artifact_denied}
      _ -> {:error, :invalid_artifact_target}
    end
  end

  @impl true
  def commit(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         :ok <- validate(effect, opts),
         {:ok, bytes} <- Payloads.get(effect.episode_id, effect.payload_ref) do
      dir = Path.expand(Map.fetch!(target, "directory"))
      name = Map.fetch!(effect.target, "name")
      File.mkdir_p!(dir)
      final = Path.join(dir, name)
      digest = Canonical.hash(bytes)

      publish(effect, bytes, dir, final, digest)
    end
  rescue
    error -> {:error, {:artifact_publish_failed, error}}
  end

  defp publish(effect, bytes, dir, final, digest) do
    case File.read(final) do
      {:ok, existing} -> existing_receipt(effect, final, digest, existing)
      {:error, :enoent} -> create_artifact(effect, bytes, dir, final, digest)
      {:error, reason} -> {:error, {:artifact_target_unreadable, reason}}
    end
  end

  defp existing_receipt(effect, final, digest, existing) do
    if Canonical.hash(existing) == digest do
      {:ok,
       %{
         path: final,
         digest: digest,
         bytes: byte_size(existing),
         effect_id: effect.id,
         idempotent: true
       }}
    else
      {:error, :artifact_exists_with_different_digest}
    end
  end

  defp create_artifact(effect, bytes, dir, final, digest) do
    tmp = final <> "." <> Canonical.id() <> ".tmp"

    try do
      with {:ok, :ok} <-
             File.open(tmp, [:write, :binary, :exclusive], fn io ->
               with :ok <- IO.binwrite(io, bytes), do: :file.sync(io)
             end),
           :ok <- File.ln(tmp, final),
           :ok <- Payloads.sync_directory(dir) do
        {:ok, %{path: final, digest: digest, bytes: byte_size(bytes), effect_id: effect.id}}
      else
        {:error, :eexist} -> publish(effect, bytes, dir, final, digest)
        {:error, reason} -> {:error, {:artifact_publish_failed, reason}}
      end
    after
      File.rm(tmp)
    end
  end

  @impl true
  def reconcile(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         dir when is_binary(dir) <- Map.get(target, "directory"),
         name when is_binary(name) <- Map.get(effect.target, "name"),
         path = Path.join(Path.expand(dir), name),
         {:ok, bytes} <- File.read(path) do
      if Canonical.hash(bytes) == effect.payload_digest,
        do: {:committed, %{path: path, digest: effect.payload_digest, reconciled: true}},
        else: {:unknown, :artifact_digest_mismatch}
    else
      {:error, :enoent} -> :not_committed
      _ -> {:unknown, :artifact_reconciliation_failed}
    end
  end

  defp safe_name?(name),
    do:
      Path.basename(name) == name and name not in ["", ".", ".."] and
        not String.contains?(name, <<0>>)

  defp trusted_target(opts) do
    case Keyword.get(opts, :trusted_target) do
      target when is_map(target) -> {:ok, target}
      _ -> {:error, :trusted_target_required}
    end
  end
end
