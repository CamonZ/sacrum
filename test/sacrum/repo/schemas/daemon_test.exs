defmodule Sacrum.Repo.Schemas.DaemonTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.Daemon

  test "requires a user and keeps lifecycle status a trusted input" do
    assert %{user_id: ["can't be blank"]} = errors_on(Daemon.create_changeset(%Daemon{}, %{}))

    changeset =
      Daemon.create_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{status: "active"})

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :status)
    assert changeset.data.status == "pending"
  end

  test "rejects unknown lifecycle states in trusted lifecycle changesets" do
    changeset =
      Daemon.update_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{status: "unknown"})

    assert %{status: [_]} = errors_on(changeset)
  end

  describe "name policy shared by create and rename" do
    test "trims surrounding whitespace" do
      changeset =
        Daemon.create_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{name: "  box-7  "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :name) == "box-7"
    end

    test "rejects blank names and enforces the 1..100 bound" do
      for name <- ["", "   ", String.duplicate("a", 101)] do
        changeset = Daemon.create_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{name: name})
        assert %{name: [_]} = errors_on(changeset)
      end

      changeset =
        Daemon.create_changeset(%Daemon{user_id: Ecto.UUID.generate()}, %{
          name: String.duplicate("a", 100)
        })

      assert changeset.valid?
    end

    test "null rename clears the name and omitted leaves it unchanged" do
      daemon = %Daemon{user_id: Ecto.UUID.generate(), name: "box-7"}

      cleared = Daemon.name_changeset(daemon, %{"name" => nil})
      assert Ecto.Changeset.get_change(cleared, :name) == nil

      unchanged = Daemon.name_changeset(daemon, %{})
      refute Map.has_key?(unchanged.changes, :name)
    end

    test "unique name collisions surface as field errors from the database constraint" do
      {:ok, user} =
        Sacrum.Repo.Users.insert(%{
          email: "daemon-name-policy@example.com",
          username: "daemon_name_policy",
          password: "password123"
        })

      assert {:ok, _, _} = Sacrum.Repo.Daemons.create(user.id, %{name: "Alpha"})

      assert {:error, changeset} = Sacrum.Repo.Daemons.create(user.id, %{name: "alpha"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)

      {:ok, other} =
        Sacrum.Repo.Users.insert(%{
          email: "daemon-name-other@example.com",
          username: "daemon_name_other",
          password: "password123"
        })

      assert {:ok, _, _} = Sacrum.Repo.Daemons.create(other.id, %{name: "alpha"})
    end
  end

  describe "display_name/1" do
    test "prefers the stored name" do
      assert Daemon.display_name(%Daemon{id: Ecto.UUID.generate(), name: "box-7"}) == "box-7"
    end

    test "falls back to a stable short ID for unnamed rows" do
      id = Ecto.UUID.generate()
      assert Daemon.display_name(%Daemon{id: id, name: nil}) == binary_part(id, 0, 8)
      assert Daemon.display_name(%Daemon{id: id, name: ""}) == binary_part(id, 0, 8)
    end
  end

  test "enroll_changeset stamps first enrollment and activates pending daemons" do
    now = DateTime.utc_now()
    daemon = %Daemon{user_id: Ecto.UUID.generate(), status: "pending"}

    changeset = Daemon.enroll_changeset(daemon, now)
    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :enrolled_at) == now
    assert Ecto.Changeset.get_change(changeset, :status) == "active"

    active = Daemon.enroll_changeset(%{daemon | status: "active"}, now)
    assert Ecto.Changeset.get_change(active, :enrolled_at) == now
    refute Map.has_key?(active.changes, :status)

    revoked = Daemon.enroll_changeset(%{daemon | status: "revoked"}, now)
    assert revoked.valid?
    refute Map.has_key?(revoked.changes, :status)
  end
end
