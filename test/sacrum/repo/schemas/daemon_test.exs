defmodule Sacrum.Repo.Schemas.DaemonTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.Daemon

  test "requires a user and accepts supported lifecycle states" do
    assert %{user_id: ["can't be blank"]} = errors_on(Daemon.create_changeset(%Daemon{}, %{}))

    assert Daemon.create_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{status: "active"}).valid?
  end

  test "rejects unknown lifecycle states" do
    changeset =
      Daemon.create_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{status: "unknown"})

    assert %{status: [_]} = errors_on(changeset)
  end
end
