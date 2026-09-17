defmodule Autonomic.Adapters.GitRemote do
  @moduledoc "Trusted Git remote CAS adapter. Remote credentials and URLs come only from trusted target configuration."
  @behaviour Autonomic.EffectAdapter

  alias Autonomic.Canonical

  @impl true
  def validate(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         {:ok, repo} <- repo_path(target),
         {:ok, url} <- remote_url(target),
         :ok <- allowed_remote?(url, target),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, local_oid} <- local_oid(repo, effect, target),
         :ok <- validate_oid(local_oid),
         {:ok, expected} <- expected_remote_oid(effect, target),
         :ok <- validate_expected(expected) do
      _ = ref
      :ok
    end
  end

  @impl true
  def commit(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         :ok <- validate(effect, opts),
         {:ok, repo} <- repo_path(target),
         {:ok, url} <- remote_url(target),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, local_oid} <- local_oid(repo, effect, target),
         {:ok, expected} <- expected_remote_oid(effect, target),
         :ok <- preflight_remote(repo, url, ref, expected, target),
         {:ok, output} <- git(repo, push_args(url, ref, local_oid, expected), target) do
      {:ok,
       %{
         remote: redacted_remote(url),
         ref: ref,
         oid: local_oid,
         expected_previous_oid: expected,
         effect_id: effect.id,
         commit_attempt_id: effect.commit_attempt_id,
         porcelain_digest: Canonical.hash(output)
       }}
    else
      {:error, {:git_failed, _status, output}} = error ->
        if ambiguous_push_failure?(output), do: {:unknown, error}, else: error

      {:error, _} = error ->
        error
    end
  rescue
    error -> {:unknown, {:git_remote_exception, Exception.message(error)}}
  end

  @impl true
  def reconcile(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         {:ok, repo} <- repo_path(target),
         {:ok, url} <- remote_url(target),
         :ok <- allowed_remote?(url, target),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, local_oid} <- local_oid(repo, effect, target),
         {:ok, expected} <- expected_remote_oid(effect, target),
         {:ok, remote_oid} <- remote_oid(repo, url, ref, target) do
      cond do
        remote_oid == local_oid ->
          {:committed,
           %{
             remote: redacted_remote(url),
             ref: ref,
             oid: remote_oid,
             effect_id: effect.id,
             reconciled: true
           }}

        remote_oid == expected or (expected == zero_oid() and is_nil(remote_oid)) ->
          :not_committed

        true ->
          {:unknown, {:remote_ref_changed, remote_oid}}
      end
    else
      {:error, reason} -> {:unknown, reason}
    end
  end

  defp preflight_remote(repo, url, ref, expected, target) do
    with {:ok, actual} <- remote_oid(repo, url, ref, target) do
      cond do
        expected == zero_oid() and is_nil(actual) -> :ok
        actual == expected -> :ok
        true -> {:error, {:remote_compare_and_swap_mismatch, actual, expected}}
      end
    end
  end

  defp remote_oid(repo, url, ref, target) do
    case git(repo, ["ls-remote", "--refs", url, ref], target) do
      {:ok, output} ->
        case String.split(output, "\n", trim: true) do
          [] ->
            {:ok, nil}

          [line] ->
            parse_remote_line(line, ref)

          _ ->
            {:error, :ambiguous_ls_remote_output}
        end

      {:error, _} = error ->
        error
    end
  end

  defp parse_remote_line(line, ref) do
    case String.split(line, ~r/\s+/, parts: 2) do
      [oid, ^ref] -> {:ok, oid}
      [oid, _] -> {:ok, oid}
      _ -> {:error, :invalid_ls_remote_output}
    end
  end

  defp push_args(url, ref, local_oid, expected) do
    lease = "--force-with-lease=#{ref}:#{expected}"
    ["push", "--porcelain", "--no-verify", lease, url, "#{local_oid}:#{ref}"]
  end

  defp expected_remote_oid(effect, target) do
    value =
      Map.get(effect.target, "expected_remote_oid") ||
        Map.get(effect.target, :expected_remote_oid) ||
        Map.get(target, "expected_remote_oid")

    cond do
      value == nil and Map.get(target, "allow_create", false) -> {:ok, zero_oid()}
      is_binary(value) -> {:ok, String.trim(value)}
      true -> {:error, :expected_remote_oid_required}
    end
  end

  defp local_oid(repo, effect, target) do
    value = Map.get(effect.target, "local_oid") || Map.get(effect.target, :local_oid)
    source_ref = Map.get(effect.target, "source_ref") || Map.get(target, "source_ref") || "HEAD"

    if is_binary(value) do
      {:ok, String.trim(value)}
    else
      case git(repo, ["rev-parse", "--verify", "#{source_ref}^{commit}"], target) do
        {:ok, oid} -> {:ok, String.trim(oid)}
        error -> error
      end
    end
  end

  defp selected_ref(effect, target) do
    ref = Map.get(effect.target, "ref") || Map.get(target, "ref", "refs/heads/main")
    allowed = Map.get(target, "allowed_refs", [Map.get(target, "ref", "refs/heads/main")])

    if is_binary(ref) and String.starts_with?(ref, "refs/") and ref in allowed,
      do: {:ok, ref},
      else: {:error, :git_remote_ref_denied}
  end

  defp repo_path(target) do
    case Map.get(target, "repo") do
      path when is_binary(path) ->
        expanded = Path.expand(path)
        if File.dir?(expanded), do: {:ok, expanded}, else: {:error, :git_remote_repo_missing}

      _ ->
        {:error, :git_remote_repo_not_configured}
    end
  end

  defp remote_url(target) do
    case Map.get(target, "url") do
      value when is_binary(value) and byte_size(value) <= 4096 -> {:ok, value}
      _ -> {:error, :git_remote_url_not_configured}
    end
  end

  defp allowed_remote?(url, target) do
    allowed = Map.get(target, "allowed_urls", [url])

    if url in allowed and not credential_in_url?(url),
      do: :ok,
      else: {:error, :git_remote_url_denied}
  end

  defp credential_in_url?(url) do
    case URI.parse(url) do
      %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" -> true
      _ -> false
    end
  end

  defp validate_oid(oid) when is_binary(oid),
    do:
      if(Regex.match?(~r/\A[0-9a-f]{40,64}\z/, oid), do: :ok, else: {:error, :invalid_local_oid})

  defp validate_expected(value) when value == "0000000000000000000000000000000000000000", do: :ok
  defp validate_expected(value), do: validate_oid(value)
  defp zero_oid, do: String.duplicate("0", 40)

  defp git(cwd, args, target) do
    env =
      [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_TERMINAL_PROMPT", "0"}] ++
        trusted_env(target)

    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, scrub(output, target)}}
    end
  rescue
    error -> {:error, {:git_exec_failed, error}}
  end

  defp trusted_env(target) do
    target
    |> Map.get("credential_env", %{})
    |> case do
      names when is_map(names) ->
        Enum.map(names, fn {env_name, source_env_name} ->
          value =
            System.get_env(to_string(source_env_name)) ||
              raise "missing trusted Git credential environment #{source_env_name}"

          {to_string(env_name), value}
        end)

      _ ->
        []
    end
  end

  defp scrub(output, target) do
    Enum.reduce(trusted_env_values(target), output, fn secret, acc ->
      if secret == "", do: acc, else: String.replace(acc, secret, "[REDACTED]")
    end)
  end

  defp trusted_env_values(target) do
    target
    |> Map.get("credential_env", %{})
    |> case do
      names when is_map(names) ->
        names |> Map.values() |> Enum.map(&(System.get_env(to_string(&1)) || ""))

      _ ->
        []
    end
  end

  defp redacted_remote(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https", "ssh"],
      do: URI.to_string(%{uri | userinfo: nil}),
      else: url
  end

  defp ambiguous_push_failure?(output) do
    not Enum.any?(
      ["rejected", "non-fast-forward", "stale info", "fetch first", "invalid refspec"],
      &String.contains?(String.downcase(output), &1)
    )
  end

  defp trusted_target(opts) do
    case Keyword.get(opts, :trusted_target) do
      target when is_map(target) -> {:ok, target}
      _ -> {:error, :trusted_target_required}
    end
  end
end
