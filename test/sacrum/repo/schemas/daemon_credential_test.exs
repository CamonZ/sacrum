defmodule Sacrum.Repo.Schemas.DaemonCredentialTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.DaemonCredential

  test "requires daemon, hash, and expiry" do
    assert %{
             daemon_id: ["can't be blank"],
             token_hash: ["can't be blank"],
             expires_at: ["can't be blank"]
           } =
             errors_on(DaemonCredential.create_changeset(%DaemonCredential{}, %{}))
  end

  test "rejects invalid status and short hashes" do
    changeset =
      DaemonCredential.create_changeset(
        %DaemonCredential{daemon_id: Ecto.UUID.generate()},
        %{token_hash: "short", expires_at: DateTime.utc_now(), status: "unknown"}
      )

    errors = errors_on(changeset)
    assert %{token_hash: [_], status: [_]} = errors
  end
end
