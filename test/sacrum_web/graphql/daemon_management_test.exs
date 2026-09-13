defmodule SacrumWeb.Graphql.DaemonManagementTest do
  @moduledoc """
  GraphQL daemon management surface: naming policy, safe enrollment
  metadata, deletion semantics, error translation and compatibility.
  """

  use SacrumWeb.ConnCase, async: false

  alias Sacrum.Repo
  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.Schemas.Daemon

  setup do
    owner = create_user()

    other =
      create_user(%{
        email: "mgmt-other@example.com",
        username: "mgmtother",
        password: "password123"
      })

    conn = authenticate(build_conn(), owner)
    %{owner: owner, other: other, conn: conn}
  end

  defp run(conn, query) do
    conn |> post("/graphql", %{query: query}) |> json_response(200)
  end

  defp error_message(%{"errors" => [error | _]}), do: error["message"]
  defp error_message(_), do: nil

  describe "createDaemon naming policy and compatibility" do
    test "accepts a documented name and preserves existing bootstrap fields", ctx do
      result =
        run(
          ctx.conn,
          "mutation { createDaemon(name: \"  Farm bot \") { daemon { id name displayName } enrollmentToken expiresAt } }"
        )

      payload = result["data"]["createDaemon"]
      daemon = payload["daemon"]
      assert daemon["name"] == "Farm bot"
      assert daemon["displayName"] == "Farm bot"
      assert is_binary(payload["enrollmentToken"])
      assert is_binary(payload["expiresAt"])

      assert Repo.get_by(Daemon, id: daemon["id"]).name == "Farm bot"
    end

    test "omitted name stays compatible and legacy rows fall back to a stable display name",
         ctx do
      result = run(ctx.conn, "mutation { createDaemon { daemon { id name displayName } } }")
      daemon = result["data"]["createDaemon"]["daemon"]
      assert daemon["name"] == nil
      assert daemon["displayName"] == String.slice(daemon["id"], 0, 8)

      legacy = Repo.get!(Daemon, daemon["id"])
      assert is_binary(Sacrum.Repo.Schemas.Daemon.display_name(legacy))
    end

    test "rejects policy violations through the changeset middleware without secrets", ctx do
      result =
        run(
          ctx.conn,
          "mutation { createDaemon(name: \"   \") { daemon { id } enrollmentToken } }"
        )

      assert result["data"]["createDaemon"] == nil
      [error] = result["errors"]
      assert error["field"] == "name"
      assert error["message"] =~ "name"
      assert Enum.empty?(Repo.all(Daemon))
    end

    test "duplicate names for one owner are rejected; other owners may reuse them", ctx do
      run(ctx.conn, "mutation { createDaemon(name: \"dupe\") { daemon { id } } }")

      dup = run(ctx.conn, "mutation { createDaemon(name: \"dupe\") { daemon { id } } }")
      assert dup["data"]["createDaemon"] == nil
      assert error_message(dup) =~ "name"

      other_conn = authenticate(build_conn(), ctx.other)
      ok = run(other_conn, "mutation { createDaemon(name: \"dupe\") { daemon { id } } }")
      assert ok["data"]["createDaemon"]["daemon"]["id"]
    end
  end

  describe "renameDaemon" do
    setup ctx do
      id =
        run(ctx.conn, "mutation { createDaemon(name: \"stable\") { daemon { id } } }")
        |> get_in(["data", "createDaemon", "daemon", "id"])

      Map.put(ctx, :id, id)
    end

    test "renames through the shared policy and clears with null", ctx do
      renamed =
        run(
          ctx.conn,
          "mutation { renameDaemon(id: \"#{ctx.id}\", name: \"  Renamed \") { id name displayName } }"
        )

      assert renamed["data"]["renameDaemon"]["name"] == "Renamed"

      cleared =
        run(
          ctx.conn,
          "mutation { renameDaemon(id: \"#{ctx.id}\", name: null) { id name displayName } }"
        )

      cleared = cleared["data"]["renameDaemon"]
      assert cleared["name"] == nil
      assert cleared["displayName"] == String.slice(ctx.id, 0, 8)
    end

    test "rejects invalid names with a field error", ctx do
      result =
        run(ctx.conn, "mutation { renameDaemon(id: \"#{ctx.id}\", name: \"   \") { id } }")

      assert result["data"]["renameDaemon"] == nil
      assert [%{"field" => "name"}] = result["errors"]
      assert Repo.get!(Daemon, ctx.id).name == "stable"
    end

    test "never discloses foreign or unknown identities", ctx do
      {:ok, foreigner} =
        Users.insert(%{
          email: "mgmt-foreign@example.com",
          username: "mgmtforeign",
          password: "password123"
        })

      {:ok, foreign, _} = Daemons.create(foreigner.id)

      foreign_result =
        run(ctx.conn, "mutation { renameDaemon(id: \"#{foreign.id}\", name: \"stolen\") { id } }")

      unknown_result =
        run(
          ctx.conn,
          "mutation { renameDaemon(id: \"#{Ecto.UUID.generate()}\", name: \"x\") { id } }"
        )

      assert error_message(foreign_result) == "daemon not found"
      assert error_message(unknown_result) == "daemon not found"
      assert Repo.get!(Daemon, foreign.id).name == nil
    end

    test "deleted identities cannot be renamed", ctx do
      assert {:ok, deleted} = Sacrum.Accounts.Daemons.delete(ctx.owner.id, ctx.id)

      result =
        run(ctx.conn, "mutation { renameDaemon(id: \"#{ctx.id}\", name: \"zombie\") { id } }")

      assert deleted.id == ctx.id
      assert error_message(result) == "daemon not found"
      assert Repo.get(Daemon, ctx.id) == nil
    end

    test "omitted name leaves the current name unchanged", ctx do
      result = run(ctx.conn, "mutation { renameDaemon(id: \"#{ctx.id}\") { id name } }")
      assert result["data"]["renameDaemon"]["name"] == "stable"
      assert Repo.get!(Daemon, ctx.id).name == "stable"
    end
  end

  describe "daemonEnrollmentMetadata" do
    test "projects safe summaries for enrolled identities without token material", ctx do
      created =
        run(
          ctx.conn,
          "mutation { createDaemon(name: \"meta\") { daemon { id } enrollmentToken } }"
        )
        |> get_in(["data", "createDaemon"])

      {:ok, _, reconnect, _} =
        Daemons.exchange_bootstrap(created["daemon"]["id"], created["enrollmentToken"])

      result =
        run(
          ctx.conn,
          "query { daemonEnrollmentMetadata(id: \"#{created["daemon"]["id"]}\") { daemonId status enrolledAt credentials { id credentialKind status expiresAt consumedAt revokedAt } } }"
        )

      metadata = result["data"]["daemonEnrollmentMetadata"]
      assert metadata["status"] == "active"
      assert is_binary(metadata["enrolledAt"])

      kinds = metadata["credentials"] |> Enum.map(& &1["credentialKind"]) |> Enum.sort()
      assert kinds == ["bootstrap", "reconnect"]

      body = inspect(result)
      refute body =~ "tokenHash"
      refute body =~ "token_hash"
      refute body =~ reconnect
      refute body =~ created["enrollmentToken"]
    end

    test "never-enrolled metadata stays explicit null rather than invented state", ctx do
      {:ok, daemon, _} = Daemons.create(ctx.owner.id)

      result =
        run(
          ctx.conn,
          "query { daemonEnrollmentMetadata(id: \"#{daemon.id}\") { enrolledAt credentials { credentialKind } } }"
        )

      metadata = result["data"]["daemonEnrollmentMetadata"]
      assert metadata["enrolledAt"] == nil
      assert [%{"credentialKind" => "bootstrap"}] = metadata["credentials"]
    end

    test "foreign identities return null without disclosure", ctx do
      {:ok, daemon, _} = Daemons.create(ctx.other.id)

      result =
        run(ctx.conn, "query { daemonEnrollmentMetadata(id: \"#{daemon.id}\") { daemonId } }")

      assert result["data"]["daemonEnrollmentMetadata"] == nil
    end
  end

  describe "deleteDaemon" do
    test "hard-deletes the identity and makes reads and authentication fail", ctx do
      created =
        run(
          ctx.conn,
          "mutation { createDaemon(name: \"delete-me\") { daemon { id status name } enrollmentToken } }"
        )
        |> get_in(["data", "createDaemon"])

      assert {:ok, _, reconnect, _} =
               Daemons.exchange_bootstrap(created["daemon"]["id"], created["enrollmentToken"])

      deleted =
        run(
          ctx.conn,
          "mutation { deleteDaemon(id: \"#{created["daemon"]["id"]}\") { id status name } }"
        )
        |> get_in(["data", "deleteDaemon"])

      assert deleted["id"] == created["daemon"]["id"]
      assert deleted["status"] == "active"
      assert deleted["name"] == "delete-me"
      assert Repo.get(Daemon, deleted["id"]) == nil
      assert {:error, :invalid_credentials} = Daemons.verify_token(deleted["id"], reconnect)

      daemon_read = run(ctx.conn, "query { daemon(id: \"#{deleted["id"]}\") { id } }")

      metadata_read =
        run(ctx.conn, "query { daemonEnrollmentMetadata(id: \"#{deleted["id"]}\") { daemonId } }")

      assert daemon_read["data"]["daemon"] == nil
      assert metadata_read["data"]["daemonEnrollmentMetadata"] == nil

      repeated = run(ctx.conn, "mutation { deleteDaemon(id: \"#{deleted["id"]}\") { id } }")
      assert error_message(repeated) == "daemon not found"
    end

    test "does not disclose foreign or unknown identities", ctx do
      {:ok, foreign, _} = Daemons.create(ctx.other.id)

      foreign_result = run(ctx.conn, "mutation { deleteDaemon(id: \"#{foreign.id}\") { id } }")

      unknown_result =
        run(ctx.conn, "mutation { deleteDaemon(id: \"#{Ecto.UUID.generate()}\") { id } }")

      assert error_message(foreign_result) == "daemon not found"
      assert error_message(unknown_result) == "daemon not found"
      assert Repo.get(Daemon, foreign.id)
    end
  end

  describe "unregisterDaemon" do
    test "hard-deletes never-enrolled provisioning", ctx do
      id =
        run(ctx.conn, "mutation { createDaemon(name: \"retire\") { daemon { id } } }")
        |> get_in(["data", "createDaemon", "daemon", "id"])

      deleted = run(ctx.conn, "mutation { unregisterDaemon(id: \"#{id}\") { id status name } }")
      deleted = deleted["data"]["unregisterDaemon"]

      assert deleted["id"] == id
      assert deleted["status"] == "pending"
      assert deleted["name"] == "retire"
      assert Repo.get(Daemon, id) == nil

      fleet = run(ctx.conn, "query { daemons { id status } }")
      assert [] == Enum.filter(fleet["data"]["daemons"], &(&1["id"] == id))

      direct = run(ctx.conn, "query { daemon(id: \"#{id}\") { id status } }")
      assert direct["data"]["daemon"] == nil

      again = run(ctx.conn, "mutation { unregisterDaemon(id: \"#{id}\") { status } }")
      assert error_message(again) == "daemon not found"
    end

    test "refuses enrolled identities and keeps the row visible", ctx do
      {:ok, daemon, bootstrap} = Daemons.create(ctx.owner.id)
      {:ok, _, _, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

      result = run(ctx.conn, "mutation { unregisterDaemon(id: \"#{daemon.id}\") { id } }")

      assert error_message(result) ==
               "daemon has enrollment history and cannot be unregistered until work ownership is established"

      fleet = run(ctx.conn, "query { daemons { id } }")
      assert Enum.any?(fleet["data"]["daemons"], &(&1["id"] == daemon.id))
      assert Repo.get!(Daemon, daemon.id).status == "active"
    end

    test "refuses removal while a session is connected", ctx do
      {:ok, daemon, _} = Daemons.create(ctx.owner.id)

      :ok =
        Sacrum.DaemonConnectionRegistry.register(daemon.id, %{
          user_id: ctx.owner.id,
          credential_id: Ecto.UUID.generate()
        })

      result = run(ctx.conn, "mutation { unregisterDaemon(id: \"#{daemon.id}\") { id } }")
      :ok = Sacrum.DaemonConnectionRegistry.unregister(daemon.id)

      assert error_message(result) ==
               "daemon has an active session; disconnect it before unregistering"

      assert Repo.get!(Daemon, daemon.id).status == "pending"
    end

    test "never discloses foreign rows and failed removals leave them listed", ctx do
      {:ok, daemon, bootstrap} = Daemons.create(ctx.other.id)
      {:ok, _, _, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

      result = run(ctx.conn, "mutation { unregisterDaemon(id: \"#{daemon.id}\") { id } }")
      assert error_message(result) == "daemon not found"
      assert Repo.get!(Daemon, daemon.id).status == "active"
    end
  end

  describe "rotateDaemonCredentials errors" do
    test "unknown and foreign identities share the non-disclosing not-found message", ctx do
      {:ok, foreign, _} = Daemons.create(ctx.other.id)

      unknown =
        run(
          ctx.conn,
          "mutation { rotateDaemonCredentials(id: \"#{Ecto.UUID.generate()}\") { enrollmentToken } }"
        )

      foreign =
        run(
          ctx.conn,
          "mutation { rotateDaemonCredentials(id: \"#{foreign.id}\") { enrollmentToken } }"
        )

      assert error_message(unknown) == "daemon not found"
      assert error_message(foreign) == "daemon not found"
    end

    test "deleted identities refuse rotation as not found", ctx do
      id =
        run(ctx.conn, "mutation { createDaemon { daemon { id } } }")
        |> get_in(["data", "createDaemon", "daemon", "id"])

      assert {:ok, deleted} = Sacrum.Accounts.Daemons.delete(ctx.owner.id, id)

      result =
        run(ctx.conn, "mutation { rotateDaemonCredentials(id: \"#{id}\") { enrollmentToken } }")

      assert deleted.id == id
      assert error_message(result) == "daemon not found"
    end
  end

  describe "existing client compatibility" do
    test "prior field selections keep working and endpoint fields stay absent", ctx do
      run(ctx.conn, "mutation { createDaemon { daemon { id status insertedAt updatedAt } } }")

      fleet =
        run(
          ctx.conn,
          "query { daemons { id status name displayName enrolledAt insertedAt updatedAt } }"
        )

      assert [%{"status" => "pending"}] = fleet["data"]["daemons"]

      removed = run(ctx.conn, "query { daemons { serverEndpoint } }")
      assert removed["errors"]
      assert removed["data"] == nil

      socket = run(ctx.conn, "query { daemons { socketEndpoint } }")
      assert socket["errors"]
    end
  end
end
