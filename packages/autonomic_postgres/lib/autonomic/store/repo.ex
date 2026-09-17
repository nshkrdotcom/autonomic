defmodule Autonomic.Store.Repo do
  use Ecto.Repo,
    otp_app: :autonomic_postgres,
    adapter: Ecto.Adapters.Postgres
end
