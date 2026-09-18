alias Autonomic.EffectBroker
alias Autonomic.Dev.{MemoryStore, Support}

Support.reset!()
secret = "EXAMPLE_SECRET_#{System.unique_integer([:positive])}"
System.put_env("AUTONOMIC_EXAMPLE_TOKEN", secret)

target = %{
  "id" => "demo",
  "base_url" => "http://example.invalid",
  "host" => "example.invalid",
  "allow_http" => true,
  "path_prefix" => "/",
  "methods" => ["GET"],
  "credential_env" => "AUTONOMIC_EXAMPLE_TOKEN",
  "credential_required" => true
}

Application.put_env(:autonomic, :targets, %{"demo" => target})

{spec, runtime} =
  Support.start_episode!(
    max_class: :class_2_external_observable_or_compensatable,
    kinds: ["http_read"]
  )

{:ok, effect} =
  EffectBroker.prepare(%{
    episode_id: spec.id,
    lease_id: runtime.lease.id,
    kind: :http_read,
    target_id: "demo",
    target: %{"path" => "/resource", "api_key" => secret, "token" => secret},
    payload: "read"
  })

artifacts = MemoryStore.all_artifacts()
serialized = inspect(artifacts, limit: :infinity, printable_limit: :infinity)
IO.inspect(effect.target, label: "persisted public target")

Support.assert!(
  not Map.has_key?(effect.target, "api_key") and not Map.has_key?(effect.target, "token"),
  "credential fields must be stripped from the public target"
)

Support.assert!(
  not String.contains?(serialized, secret),
  "secret must not appear in persisted episode/effect/event artifacts"
)

Support.assert_equal!(
  target["credential_env"],
  "AUTONOMIC_EXAMPLE_TOKEN",
  "trusted side stores only credential environment name"
)

System.delete_env("AUTONOMIC_EXAMPLE_TOKEN")

IO.puts(
  "ASSERTION PASSED: the broker-owned credential value never enters worker-visible or persisted effect data"
)
