defmodule Autonomic.Verifier do
  @moduledoc "Slow deterministic verifier. It consumes trusted evidence and never executes repository code on the host."

  alias Autonomic.{Canonical, Payloads, Runtime}

  def verify(effect, opts) do
    with {:ok, target} <- trusted_target(effect),
         {:ok, payload} <- Payloads.get(effect.episode_id, effect.payload_ref),
         true <- Canonical.hash(payload) == effect.payload_digest,
         :ok <- verify_kind(effect, target, payload, opts),
         {:ok, verification_evidence} <- verify_test_evidence(effect, target, opts) do
      {:ok,
       %{
         verified_at: Canonical.now(),
         effect_id: effect.id,
         revision: effect.revision,
         payload_digest: effect.payload_digest,
         target_id: Map.get(effect.target, "id"),
         verification: :deterministic_slow,
         test_evidence: verification_evidence
       }}
    else
      false -> {:error, :payload_digest_mismatch}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp verify_kind(%{kind: :git_commit} = effect, target, payload, _opts),
    do: Autonomic.Adapters.Git.verify_patch(effect, target, payload)

  defp verify_kind(%{kind: kind}, _target, payload, _opts)
       when kind in [:http_mutation, :publish] do
    if byte_size(payload) <= 4_194_304, do: :ok, else: {:error, :payload_too_large}
  end

  defp verify_kind(_effect, _target, _payload, _opts), do: :ok

  defp verify_test_evidence(%{kind: :git_commit} = effect, target, opts) do
    case Keyword.get(opts, :test_evidence) do
      evidence when is_map(evidence) ->
        cond do
          Map.get(evidence, :payload_digest, Map.get(evidence, "payload_digest")) !=
              effect.payload_digest ->
            {:error, :test_evidence_payload_mismatch}

          Map.get(evidence, :passed, Map.get(evidence, "passed")) != true ->
            {:error, :verification_tests_failed}

          true ->
            {:ok, Map.take(evidence, [:payload_digest, :passed, :source, :run_id])}
        end

      nil ->
        Autonomic.VerificationRunner.verify_git(effect, target)

      _ ->
        {:error, :invalid_trusted_test_evidence}
    end
  end

  defp verify_test_evidence(_, _target, _opts), do: {:ok, %{not_required: true}}

  defp trusted_target(effect) do
    id = Map.get(effect.target, "id") || Map.get(effect.target, :id)
    Runtime.target(id)
  end
end
