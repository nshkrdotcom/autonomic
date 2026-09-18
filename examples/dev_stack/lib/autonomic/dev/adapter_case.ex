defmodule Autonomic.Dev.AdapterCase do
  @moduledoc "Runnable contract checks for example `Autonomic.EffectAdapter` implementations."

  alias Autonomic.Dev.Support

  def verify!(adapter, effect, opts, expected_receipt_key \\ :receipt_ref) do
    Support.assert_equal!(
      adapter.validate(effect, opts),
      :ok,
      "adapter validates an in-scope effect"
    )

    first = adapter.commit(effect, opts)
    Support.assert!(match?({:ok, _}, first), "adapter commit must return an explicit receipt")
    {:ok, receipt} = first

    Support.assert!(
      Map.has_key?(receipt, expected_receipt_key) or
        Map.has_key?(receipt, to_string(expected_receipt_key)),
      "receipt must be auditable"
    )

    replay = adapter.commit(effect, opts)
    Support.assert!(match?({:ok, _}, replay), "idempotent replay must not duplicate/fail")

    Support.assert!(
      match?({:committed, _}, adapter.reconcile(effect, opts)),
      "reconcile must prove the committed mutation"
    )

    :ok
  end
end
