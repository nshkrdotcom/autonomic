defmodule Autonomic.Adapters.Git do
  @moduledoc "Authoritative local Git commit adapter using an isolated trusted staging worktree and atomic update-ref CAS."
  @behaviour Autonomic.EffectAdapter

  alias Autonomic.{Canonical, Payloads, Runtime}

  @impl true
  def validate(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         {:ok, repo} <- repo_path(target),
         true <- File.dir?(Path.join(repo, ".git")) or File.exists?(Path.join(repo, "HEAD")),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, current} <- git(repo, ["rev-parse", "--verify", ref]),
         base when is_binary(base) <- effect_base(effect),
         true <- String.trim(current) == base,
         {:ok, payload} <- Payloads.get(effect.episode_id, effect.payload_ref),
         true <- Canonical.hash(payload) == effect.payload_digest do
      :ok
    else
      false -> {:error, :git_target_or_base_mismatch}
      nil -> {:error, :base_ref_required}
      {:error, _} = error -> error
      _ -> {:error, :invalid_git_target}
    end
  end

  @impl true
  def commit(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         :ok <- validate(effect, opts),
         {:ok, payload} <- Payloads.get(effect.episode_id, effect.payload_ref),
         {:ok, repo} <- repo_path(target),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, oid} <- create_commit(repo, effect, target, payload),
         {:ok, _} <- git(repo, ["update-ref", ref, oid, effect_base(effect)]),
         {:ok, tree} <- git(repo, ["rev-parse", "#{oid}^{tree}"]) do
      {:ok,
       %{
         oid: String.trim(oid),
         tree: String.trim(tree),
         ref: ref,
         base: effect_base(effect),
         effect_id: effect.id,
         commit_attempt_id: effect.commit_attempt_id
       }}
    else
      {:error, {:git_failed, _status, output}} = error ->
        if String.contains?(output, "cannot lock ref") or String.contains?(output, "is at") do
          {:unknown, {:cas_or_concurrent_update, error}}
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  @impl true
  def reconcile(effect, opts) do
    with {:ok, target} <- trusted_target(opts),
         {:ok, repo} <- repo_path(target),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, current} <- git(repo, ["rev-parse", "--verify", ref]) do
      current = String.trim(current)
      base = effect_base(effect)

      cond do
        current == base ->
          :not_committed

        authored_effect?(repo, current, effect) ->
          {:ok, tree} = git(repo, ["rev-parse", "#{current}^{tree}"])

          {:committed,
           %{
             oid: current,
             tree: String.trim(tree),
             ref: ref,
             base: base,
             effect_id: effect.id,
             reconciled: true
           }}

        true ->
          {:unknown, {:ref_advanced_by_other_actor, current}}
      end
    else
      {:error, reason} -> {:unknown, reason}
    end
  end

  def verify_patch(effect, target, payload) do
    with {:ok, repo} <- repo_path(target),
         {:ok, ref} <- selected_ref(effect, target),
         {:ok, current} <- git(repo, ["rev-parse", "--verify", ref]),
         true <- String.trim(current) == effect_base(effect),
         {:ok, paths} <- patch_paths(repo, effect_base(effect), payload),
         :ok <- verify_paths(paths, target) do
      :ok
    else
      false -> {:error, :authoritative_base_changed}
      {:error, _} = error -> error
    end
  end

  defp create_commit(repo, effect, target, payload) do
    root = Path.join([Runtime.root(), "git-staging"])
    File.mkdir_p!(root)
    stage = Path.join(root, effect.id <> "-" <> (effect.commit_attempt_id || Canonical.id()))
    patch = stage <> ".patch"
    File.write!(patch, payload, [:binary])
    base = effect_base(effect)

    try do
      with {:ok, _} <- git(repo, ["worktree", "add", "--detach", "--force", stage, base]),
           {:ok, _} <- git(stage, ["apply", "--index", "--whitespace=error", patch]),
           :ok <- verify_index_paths(stage, target),
           message <- commit_message(effect),
           {:ok, _} <-
             git(stage, [
               "-c",
               "user.name=Autonomic Kernel",
               "-c",
               "user.email=autonomic@localhost",
               "commit",
               "--no-gpg-sign",
               "-m",
               message
             ]),
           {:ok, oid} <- git(stage, ["rev-parse", "HEAD"]) do
        {:ok, String.trim(oid)}
      end
    after
      _ = git(repo, ["worktree", "remove", "--force", stage])
      File.rm_rf(stage)
      File.rm(patch)
    end
  end

  defp patch_paths(repo, base, payload) do
    root = Path.join([Runtime.root(), "git-verify"])
    File.mkdir_p!(root)
    id = Canonical.id()
    stage = Path.join(root, id)
    patch = Path.join(root, id <> ".patch")
    File.write!(patch, payload, [:binary])

    try do
      with {:ok, _} <- git(repo, ["worktree", "add", "--detach", "--force", stage, base]),
           {:ok, _} <- git(stage, ["apply", "--check", "--whitespace=error", patch]),
           {:ok, output} <- git(stage, ["apply", "--numstat", patch]) do
        paths = output |> String.split("\n", trim: true) |> Enum.map(&numstat_path/1)
        {:ok, paths}
      end
    after
      _ = git(repo, ["worktree", "remove", "--force", stage])
      File.rm_rf(stage)
      File.rm(patch)
    end
  end

  defp verify_index_paths(stage, target) do
    with {:ok, output} <- git(stage, ["diff", "--cached", "--name-only", "-z"]) do
      output |> String.split(<<0>>, trim: true) |> verify_paths(target)
    end
  end

  defp verify_paths(paths, target) do
    allowed = Map.get(target, "allowed_paths", ["**"])

    forbidden =
      Map.get(target, "forbidden_paths", ["test/fixtures/**", ".env", "**/.env", "**/*secret*"])

    bad =
      Enum.filter(paths, fn path ->
        not Enum.any?(allowed, &glob_match?(&1, path)) or
          Enum.any?(forbidden, &glob_match?(&1, path))
      end)

    if bad == [], do: :ok, else: {:error, {:forbidden_patch_paths, bad}}
  end

  defp glob_match?("**", _), do: true

  defp glob_match?(pattern, path) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")

    Regex.match?(Regex.compile!("^" <> regex <> "$"), path)
  end

  defp numstat_path(line) do
    case String.split(line, "\t") do
      [_a, _d, path] -> path
      parts -> List.last(parts)
    end
  end

  defp authored_effect?(repo, oid, effect) do
    with {:ok, body} <- git(repo, ["show", "-s", "--format=%B", oid]),
         {:ok, parent} <- git(repo, ["rev-parse", "#{oid}^"]) do
      String.contains?(body, "Autonomic-Effect: #{effect.id}") and
        String.trim(parent) == effect_base(effect)
    else
      _ -> false
    end
  end

  defp commit_message(effect) do
    requested = Map.get(effect.target, "message", "apply verified autonomous repair")
    requested = requested |> to_string() |> String.slice(0, 2_000)

    requested <>
      "\n\nAutonomic-Effect: #{effect.id}\nAutonomic-Attempt: #{effect.commit_attempt_id}\nAutonomic-Payload: #{effect.payload_digest}"
  end

  defp effect_base(effect),
    do: Map.get(effect.target, "base_ref") || Map.get(effect.target, :base_ref)

  defp selected_ref(effect, target) do
    requested = Map.get(effect.target, "ref") || Map.get(target, "ref", "refs/heads/main")
    allowed = Map.get(target, "allowed_refs", [Map.get(target, "ref", "refs/heads/main")])
    if requested in allowed, do: {:ok, requested}, else: {:error, :git_ref_not_allowed}
  end

  defp repo_path(target) do
    case Map.get(target, "repo") do
      path when is_binary(path) -> {:ok, Path.expand(path)}
      _ -> {:error, :git_repo_not_configured}
    end
  end

  defp trusted_target(opts) do
    case Keyword.get(opts, :trusted_target) do
      target when is_map(target) -> {:ok, target}
      _ -> {:error, :trusted_target_required}
    end
  end

  defp git(cwd, args) do
    case System.cmd("git", args,
           cd: cwd,
           stderr_to_stdout: true,
           env: [{"GIT_CONFIG_NOSYSTEM", "1"}]
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, status, output}}
    end
  rescue
    error -> {:error, {:git_exec_failed, error}}
  end
end
