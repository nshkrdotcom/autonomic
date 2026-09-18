alias Autonomic.EffectBroker
alias Autonomic.Dev.Support

Support.reset!()
Support.install_adapter!("publish", :class_4_irreversible_high_impact, %{"id" => "demo"})
{public, private} = Support.ed25519_keypair!()
{other_public, other_private} = Support.ed25519_keypair!()
Application.put_env(:autonomic, :decision_keys, %{"operator" => Base.encode64(public)})

{spec, runtime} =
  Support.start_episode!(max_class: :class_4_irreversible_high_impact, kinds: ["publish"])

make_effect = fn payload ->
  Support.prepare!(spec, runtime, :publish, payload, reversible?: false)
end

missing = make_effect.("release-a")
missing_result = EffectBroker.evaluate(missing.id)

mismatch = make_effect.("release-b")
wrong_doc = Support.human_approval(mismatch, "operator", private)
wrong_doc = put_in(wrong_doc, [:document, "payload_digest"], String.duplicate("0", 64))

wrong_doc = %{
  wrong_doc
  | signature:
      Autonomic.Policy.sign(wrong_doc.document, "operator", private, "human-approval")[
        "signature"
      ]
}

mismatch_result = EffectBroker.evaluate(mismatch.id, human_approval: wrong_doc)

untrusted = make_effect.("release-c")
untrusted_approval = Support.human_approval(untrusted, "other", other_private)

Application.put_env(:autonomic, :decision_keys, %{
  "operator" => Base.encode64(public),
  "not-used" => Base.encode64(other_public)
})

untrusted_result = EffectBroker.evaluate(untrusted.id, human_approval: untrusted_approval)

exact = make_effect.("release-d")
exact_approval = Support.human_approval(exact, "operator", private)
{:ok, ready} = EffectBroker.evaluate(exact.id, human_approval: exact_approval)
{:ok, committed} = EffectBroker.commit(ready.id)

IO.inspect(missing_result, label: "missing approval")
IO.inspect(mismatch_result, label: "payload-mismatched approval")
IO.inspect(untrusted_result, label: "unlisted key approval")
IO.inspect(committed.state, label: "exact approval")

Support.assert_equal!(
  missing_result,
  {:error, :human_approval_required},
  "missing approval denial"
)

Support.assert_equal!(
  mismatch_result,
  {:error, :invalid_human_approval},
  "mismatched digest denial"
)

Support.assert_equal!(untrusted_result, {:error, :invalid_human_approval}, "untrusted key denial")
Support.assert_equal!(committed.state, :committed, "exact approval commit")

IO.puts(
  "ASSERTION PASSED: Class 4 approval is bound to exact effect/revision/epoch/payload and trusted key"
)
