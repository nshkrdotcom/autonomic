defmodule Autonomic.AuthorityGovernor do
  @moduledoc "Issues short-lived epoch-fenced leases within the signed hard envelope."
  use GenServer

  alias Autonomic.{Canonical, Capability, CapabilityLease, Policy, Runtime}

  def start_link(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    GenServer.start_link(__MODULE__, opts, name: Runtime.via(episode_id, :authority))
  end

  def issue(episode_id, attrs),
    do: GenServer.call(Runtime.via(episode_id, :authority), {:issue, attrs})

  def validate(episode_id, lease_id, kind, target, class),
    do:
      GenServer.call(
        Runtime.via(episode_id, :authority),
        {:validate, lease_id, kind, target, class}
      )

  def revoke(episode_id, lease_id, reason),
    do: GenServer.call(Runtime.via(episode_id, :authority), {:revoke, lease_id, reason})

  def advance_epoch(episode_id, reason),
    do: GenServer.call(Runtime.via(episode_id, :authority), {:advance_epoch, reason}, 30_000)

  @impl true
  def init(opts) do
    episode_id = Keyword.fetch!(opts, :episode_id)
    policy = Keyword.fetch!(opts, :policy)
    hard_envelope = Keyword.fetch!(opts, :hard_envelope)

    case Runtime.store().current_epoch(episode_id) do
      {:ok, epoch} ->
        {:ok,
         %{episode_id: episode_id, epoch: epoch, policy: policy, hard_envelope: hard_envelope}}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:issue, attrs}, _from, state) do
    authority_source = Map.fetch!(attrs, :authority_source)

    requested_capabilities =
      Map.get(attrs, :capabilities, []) |> Enum.map(&normalize_capability/1)

    requested_class = Map.get(attrs, :max_effect_class, :class_1_isolated_mutable)

    with :ok <- expansion_source_allowed(authority_source),
         true <-
           within_hard_envelope?(state.hard_envelope, requested_capabilities, requested_class),
         {:ok, epoch} <- Runtime.store().current_epoch(state.episode_id),
         true <- epoch == state.epoch do
      now = Canonical.now()
      ttl = Map.get(attrs, :ttl_ms, 30_000)

      lease = %CapabilityLease{
        id: Canonical.id(),
        episode_id: state.episode_id,
        epoch: epoch,
        policy_version: Map.fetch!(state.policy, "version"),
        capabilities: requested_capabilities,
        max_effect_class: requested_class,
        issued_at: now,
        expires_at: now + ttl,
        authority_source: authority_source,
        authority_ref: Map.get(attrs, :authority_ref),
        reason: Map.get(attrs, :reason),
        metadata: Map.get(attrs, :metadata, %{})
      }

      case Runtime.store().put_lease(lease) do
        :ok -> {:reply, {:ok, lease}, state}
        error -> {:reply, error, state}
      end
    else
      false -> {:reply, {:error, :outside_hard_envelope}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :stale_governor_epoch}, state}
    end
  end

  def handle_call({:validate, lease_id, kind, target, class}, _from, state) do
    result =
      with {:ok, current_epoch} <- Runtime.store().current_epoch(state.episode_id),
           true <- current_epoch == state.epoch,
           {:ok, lease} <- Runtime.store().fetch_lease(lease_id),
           true <- lease.episode_id == state.episode_id and lease.epoch == current_epoch,
           true <- is_nil(lease.revoked_at) and lease.expires_at > Canonical.now(),
           true <- Policy.class_rank(class) <= Policy.class_rank(lease.max_effect_class),
           true <- capability_allows?(lease.capabilities, kind, target, class) do
        :ok
      else
        :not_found -> {:error, :lease_not_found}
        false -> {:error, :lease_denied}
        {:error, _} = error -> error
        _ -> {:error, :lease_denied}
      end

    {:reply, result, state}
  end

  def handle_call({:revoke, lease_id, reason}, _from, state) do
    result = Runtime.store().revoke_lease(lease_id, reason)
    {:reply, result, state}
  end

  def handle_call({:advance_epoch, reason}, _from, state) do
    case Runtime.store().advance_epoch(state.episode_id, %{reason: audit_reason(reason)}) do
      {:ok, new_epoch} -> {:reply, {:ok, new_epoch}, %{state | epoch: new_epoch}}
      error -> {:reply, error, state}
    end
  end

  defp audit_reason(reason) when is_binary(reason), do: reason
  defp audit_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp audit_reason(reason), do: inspect(reason)

  defp expansion_source_allowed(source)
       when source in [:signed_policy, :slow_verifier, :human, :parent_capability], do: :ok

  defp expansion_source_allowed(:semantic), do: {:error, :semantic_cannot_expand_authority}
  defp expansion_source_allowed(_), do: {:error, :invalid_authority_source}

  def normalize_capability(%Capability{} = capability), do: capability

  def normalize_capability(capability) when is_map(capability) do
    kind = Map.get(capability, :kind, Map.get(capability, "kind"))
    scope = Map.get(capability, :scope, Map.get(capability, "scope", %{}))
    constraints = Map.get(capability, :constraints, Map.get(capability, "constraints", %{}))
    %Capability{kind: normalize_kind(kind), scope: scope, constraints: constraints}
  end

  defp within_hard_envelope?(hard, capabilities, class) do
    max_class = Map.get(hard, "max_effect_class", Map.get(hard, :max_effect_class, 1))

    allowed =
      Map.get(hard, "capabilities", Map.get(hard, :capabilities, []))
      |> Enum.map(&normalize_capability/1)

    Policy.class_rank(class) <= Policy.class_rank(max_class) and
      Enum.all?(capabilities, fn requested ->
        Enum.any?(allowed, fn envelope ->
          requested.kind == envelope.kind and scope_within?(requested.scope, envelope.scope) and
            Policy.class_rank(
              Map.get(
                requested.constraints,
                :max_effect_class,
                Map.get(requested.constraints, "max_effect_class", class)
              )
            ) <=
              Policy.class_rank(
                Map.get(
                  envelope.constraints,
                  :max_effect_class,
                  Map.get(envelope.constraints, "max_effect_class", max_class)
                )
              )
        end)
      end)
  end

  defp scope_within?(requested, envelope) when is_map(requested) and is_map(envelope),
    do:
      Enum.all?(envelope, fn {k, v} ->
        Map.get(requested, k, Map.get(requested, to_string(k))) == v
      end)

  defp scope_within?(requested, envelope), do: requested == envelope

  defp normalize_kind(kind) when is_atom(kind), do: kind

  defp normalize_kind("workspace_read"), do: :workspace_read
  defp normalize_kind("workspace_write"), do: :workspace_write
  defp normalize_kind("workspace_write_allowed_paths"), do: :workspace_write_allowed_paths
  defp normalize_kind("shell_bounded"), do: :shell_bounded
  defp normalize_kind("git_commit"), do: :git_commit
  defp normalize_kind("git_remote"), do: :git_remote
  defp normalize_kind("http_read"), do: :http_read
  defp normalize_kind("http_mutation"), do: :http_mutation
  defp normalize_kind("publish"), do: :publish

  defp normalize_kind(kind) when is_binary(kind),
    do: raise(ArgumentError, "unknown capability kind: #{kind}")

  defp capability_allows?(capabilities, kind, target, class) do
    Enum.any?(capabilities, fn capability ->
      capability.kind == kind and
        scope_match?(capability.scope, target) and
        Policy.class_rank(class) <=
          Policy.class_rank(
            Map.get(
              capability.constraints,
              :max_effect_class,
              Map.get(capability.constraints, "max_effect_class", class)
            )
          )
    end)
  end

  defp scope_match?(scope, target) when is_map(scope) and is_map(target),
    do:
      Enum.all?(scope, fn {k, v} ->
        Map.get(target, k) == v or Map.get(target, to_string(k)) == v
      end)

  defp scope_match?(scope, target), do: scope == target
end
