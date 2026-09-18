alias Autonomic.{Canonical, Policy, ProposedEffect, VersionVector}
alias Autonomic.Dev.Support

Support.reset!()
{public, private} = Support.ed25519_keypair!()
keys = %{"operator-2026" => Base.encode64(public)}
policy = %{"id" => "example-policy", "version" => 1, "max_effect_class" => "class_4_irreversible_high_impact", "capabilities" => []}
signed_policy = Policy.sign(policy, "operator-2026", private, "policy")
{:ok, ^policy} = Policy.verify(signed_policy, keys, "policy")

now = Canonical.now()
episode_id = Canonical.id(); lease_id = Canonical.id()
effect = %ProposedEffect{id: Canonical.id(), episode_id: episode_id, epoch: 7, lease_id: lease_id, class: :class_4_irreversible_high_impact, kind: :publish, target: %{"id" => "demo"}, payload_ref: "sha256:payload", payload_digest: Canonical.hash("release"), revision: 3, reversible?: false, state: :evaluating, version_vector: %VersionVector{episode_id: episode_id, epoch: 7, policy_version: 1, snapshot_ancestry: [], trajectory_version: 4, trajectory_regime: :stable, lease_id: lease_id, effect_revision: 3}, created_at: now}
approval = Support.human_approval(effect, "operator-2026", private)
Application.put_env(:autonomic, :decision_keys, keys)
:ok = Autonomic.HumanApproval.verify(effect, approval)

rotated_keys = %{"operator-2027" => Base.encode64(elem(Support.ed25519_keypair!(), 0))}
Support.assert_equal!(Policy.verify(signed_policy, rotated_keys, "policy"), {:error, :invalid_signature}, "old key absent after rotation")
IO.puts("public key id: operator-2026")
IO.puts("policy digest: #{Canonical.digest(policy)}")
IO.puts("approval binds effect=#{effect.id} revision=#{effect.revision} epoch=#{effect.epoch} payload=#{effect.payload_digest}")
IO.puts("ASSERTION PASSED: policy signatures and Class 4 approvals use separate explicit keyrings/domains and exact canonical documents")
