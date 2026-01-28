defmodule Sacrum.Repo do
  use Ecto.Repo,
    otp_app: :sacrum,
    adapter: Ecto.Adapters.Postgres
end
