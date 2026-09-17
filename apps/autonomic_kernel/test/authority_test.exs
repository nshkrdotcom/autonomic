defmodule Autonomic.AuthorityTest do
  use ExUnit.Case, async: true
  alias Autonomic.{Canonical, EffectState, Policy}
  test "canonical identity is stable but preserves list order" do
    assert Canonical.digest(%{"a" => 1, "b" => 2}) == Canonical.digest(%{"b" => 2, "a" => 1})
    refute Canonical.digest([1, 2]) == Canonical.digest([2, 1])
  end
  test "every irreversible state forbids cancellation and replay" do
    for state <- [:commit_intent, :committing, :commit_unknown, :committed] do
      refute EffectState.allowed?(state, :aborted)
      refute EffectState.allowed?(state, :prepared)
    end
    assert EffectState.allowed?(:committing, :commit_unknown)
    assert EffectState.allowed?(:commit_unknown, :committed)
  end
  test "signed policy cannot be forged or mutated" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    doc = %{"id" => "p", "version" => 1, "max_effect_class" => 3,
      "capabilities" => [%{"kind" => "git_commit", "scope" => "fixture"}]}
    signed = Policy.sign(doc, "operator", private, "policy")
    keys = %{"operator" => Base.encode64(public)}
    assert {:ok, ^doc} = Policy.verify(signed, keys, "policy")
    refute match?({:ok, _}, Policy.verify(put_in(signed, ["document", "max_effect_class"], 4), keys, "policy"))
    refute match?({:ok, _}, Policy.verify(signed, keys, "human"))
  end
  test "denial dominance is not weighted voting" do
    assert {:deny, "kernel_denial"} = Policy.precedence([
      %{"source" => "semantic", "decision" => "allow"},
      %{"source" => "human", "decision" => "allow"},
      %{"source" => "kernel_denial", "decision" => "deny"}])
  end
  test "capability contraction cannot add a kind, scope or effect class" do
    cap = %{"kind" => "git_commit", "scope" => "fixture"}
    assert Policy.contraction?([cap], [cap], 3, 2)
    refute Policy.contraction?([cap], [cap], 3, 4)
    refute Policy.contraction?([cap], [%{"kind" => "publish", "scope" => "fixture"}], 3, 3)
  end
end
