defmodule Autonomic.Store.Repo do
  use Ecto.Repo,
    otp_app: :autonomic_store,
    adapter: Ecto.Adapters.Postgres
end
