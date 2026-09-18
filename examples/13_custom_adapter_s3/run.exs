alias Autonomic.{Canonical, ProposedEffect, VersionVector}
alias Autonomic.Dev.{AdapterCase, Support}

Support.reset!()

defmodule ExampleS3Adapter do
  @behaviour Autonomic.EffectAdapter
  alias Autonomic.Dev.TargetStore

  def validate(effect, opts) do
    target = Keyword.fetch!(opts, :trusted_target)
    bucket = Map.get(effect.target, "bucket")
    key = Map.get(effect.target, "key", "")

    if bucket == target["bucket"] and String.starts_with?(key, target["key_prefix"] || ""),
      do: :ok,
      else: {:error, :object_scope_denied}
  end

  def commit(effect, opts) do
    with :ok <- validate(effect, opts) do
      target = Keyword.fetch!(opts, :trusted_target)
      object = {target["bucket"], effect.target["key"]}

      case TargetStore.get(object) do
        nil ->
          TargetStore.put(object, effect.payload_digest)

          {:ok,
           %{
             receipt_ref: "s3://#{elem(object, 0)}/#{elem(object, 1)}",
             etag: effect.payload_digest,
             mode: :created
           }}

        digest when digest == effect.payload_digest ->
          {:ok,
           %{
             receipt_ref: "s3://#{elem(object, 0)}/#{elem(object, 1)}",
             etag: digest,
             mode: :idempotent
           }}

        _ ->
          {:error, :precondition_failed}
      end
    end
  end

  def reconcile(effect, opts) do
    target = Keyword.fetch!(opts, :trusted_target)
    object = {target["bucket"], effect.target["key"]}

    case TargetStore.get(object) do
      digest when digest == effect.payload_digest ->
        {:committed, %{receipt_ref: "s3://#{elem(object, 0)}/#{elem(object, 1)}", etag: digest}}

      nil ->
        :not_committed

      _ ->
        {:unknown, :object_has_different_etag}
    end
  end
end

now = Canonical.now()
episode_id = Canonical.id()
lease_id = Canonical.id()

effect = %ProposedEffect{
  id: Canonical.id(),
  episode_id: episode_id,
  epoch: 1,
  lease_id: lease_id,
  class: :class_2_external_observable_or_compensatable,
  kind: :publish,
  target: %{"bucket" => "example-bucket", "key" => "releases/v1.tar"},
  payload_ref: "sha256:payload",
  payload_digest: Canonical.hash("payload"),
  revision: 1,
  reversible?: true,
  state: :ready,
  version_vector: %VersionVector{
    episode_id: episode_id,
    epoch: 1,
    policy_version: 1,
    snapshot_ancestry: [],
    trajectory_version: 0,
    trajectory_regime: :stable,
    lease_id: lease_id,
    effect_revision: 1
  },
  created_at: now
}

opts = [trusted_target: %{"bucket" => "example-bucket", "key_prefix" => "releases/"}]
:ok = AdapterCase.verify!(ExampleS3Adapter, effect, opts)

Support.assert_equal!(
  ExampleS3Adapter.validate(
    %{effect | target: %{"bucket" => "example-bucket", "key" => "private/secret"}},
    opts
  ),
  {:error, :object_scope_denied},
  "prefix scope denial"
)

IO.puts(
  "ASSERTION PASSED: object adapter validates scope, commits conditionally, replays idempotently, and reconciles by authoritative HEAD-equivalent state"
)
