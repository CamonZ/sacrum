defmodule Sacrum.Repo.DaemonCredentialsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.{DaemonCredentials, Daemons, Users}
  alias Sacrum.Repo.Schemas.DaemonCredential

  test "lists multiple active credentials without a multiple-results error" do
    {:ok, user} =
      Users.insert(%{
        email: "credentials@example.com",
        username: "credentials",
        password: "password123"
      })

    {:ok, daemon, _token} = Daemons.create(user.id)

    {:ok, second} =
      %DaemonCredential{daemon_id: daemon.id}
      |> DaemonCredential.create_changeset(%{
        token_hash: String.duplicate("hash", 8),
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Sacrum.Repo.insert()

    credentials = DaemonCredentials.list_active_for_daemon(daemon.id)
    assert length(credentials) == 2
    assert second.id in Enum.map(credentials, & &1.id)
  end
end
