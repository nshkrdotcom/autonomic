defmodule Autonomic.ArtifactPublicationTest do
  use ExUnit.Case, async: false
  alias Autonomic.Adapters.Artifact
  alias Autonomic.{Canonical, Payloads}

  test "concurrent publishers cannot replace an artifact created by another effect" do
    episode_id = Canonical.id()
    directory = Path.join(System.tmp_dir!(), "autonomic-publish-#{episode_id}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    effects =
      for index <- 1..16 do
        bytes = String.duplicate("#{index}\n", 100_000)
        {:ok, ref} = Payloads.put(episode_id, bytes)

        %{
          id: Canonical.id(),
          episode_id: episode_id,
          payload_ref: ref,
          payload_digest: ref,
          target: %{"name" => "release"}
        }
      end

    results =
      effects
      |> Task.async_stream(
        fn effect ->
          Artifact.commit(effect, trusted_target: %{"directory" => directory})
        end,
        max_concurrency: 16
      )
      |> Enum.map(fn {:ok, result} -> result end)

    successes = for {:ok, receipt} <- results, do: receipt
    assert length(successes) == 1
    assert Canonical.hash(File.read!(Path.join(directory, "release"))) == hd(successes).digest
  end
end
