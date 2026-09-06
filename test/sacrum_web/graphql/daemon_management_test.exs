defmodule SacrumWeb.Graphql.DaemonManagementTest do
  @moduledoc """
  GraphQL daemon management surface: naming policy, safe enrollment
  metadata, unregister semantics, error translation and compatibility.
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

      # Legacy pre-naming rows project the same non-null fallback.
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

    test "terminal identities refuse rename", ctx do
      assert {:ok, _} = Sacrum.Accounts.Daemons.revoke(ctx.owner.id, ctx.id)

      revoked =
        run(ctx.conn, "mutation { renameDaemon(id: \"#{ctx.id}\", name: \"zombie\") { id } }")

      assert error_message(revoked) == "daemon is in a terminal state (revoked or removed)"
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

      # Only safe projection fields exist; no secrets on the wire.
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

  describe "unregisterDaemon" do
    test "removes never-enrolled provisioning and applies tombstone semantics", ctx do
      id =
        run(ctx.conn, "mutation { createDaemon(name: \"retire\") { daemon { id } } }")
        |> get_in(["data", "createDaemon", "daemon", "id"])

      removed =
        run(ctx.conn, "mutation { unregisterDaemon(id: \"#{id}\") { id status name removedAt } }")
        |> get_in(["data", "unregisterDaemon"])

      assert removed["status"] == "removed"
      assert removed["name"] == "retire"
      assert is_binary(removed["removedAt"])

      # Tombstone: gone from the fleet list, still readable directly.
      fleet = run(ctx.conn, "query { daemons { id status removedAt } }")
      assert [] == Enum.filter(fleet["data"]["daemons"], &(&1["id"] == id))

      direct = run(ctx.conn, "query { daemon(id: \"#{id}\") { id status removedAt } }")
      assert direct["data"]["daemon"]["status"] == "removed"

      # Idempotent through GraphQL.
      again = run(ctx.conn, "mutation { unregisterDaemon(id: \"#{id}\") { status } }")
      assert again["data"]["unregisterDaemon"]["status"] == "removed"
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

  describe "lifecycle integration across two owners" do
    test "create, exchange, metadata, rename, rotate, revoke and safe pending unregister", ctx do
      created =
        run(
          ctx.conn,
          "mutation { createDaemon(name: \"orbit\") { daemon { id } enrollmentToken } }"
        )
        |> get_in(["data", "createDaemon"])

      id = created["daemon"]["id"]
      {:ok, _, _reconnect, _} = Daemons.exchange_bootstrap(id, created["enrollmentToken"])

      metadata =
        run(
          ctx.conn,
          "query { daemonEnrollmentMetadata(id: \"#{id}\") { status enrolledAt } }"
        )
        |> get_in(["data", "daemonEnrollmentMetadata"])

      assert metadata["status"] == "active"
      assert is_binary(metadata["enrolledAt"])

      assert run(
               ctx.conn,
               "mutation { renameDaemon(id: \"#{id}\", name: \"orbit two\") { name } }"
             )
             |> get_in(["data", "renameDaemon", "name"]) == "orbit two"

      rotated =
        run(
          ctx.conn,
          "mutation { rotateDaemonCredentials(id: \"#{id}\") { daemon { status } enrollmentToken expiresAt } }"
        )
        |> get_in(["data", "rotateDaemonCredentials"])

      assert rotated["daemon"]["status"] == "active"
      assert is_binary(rotated["enrollmentToken"])

      revoked =
        run(ctx.conn, "mutation { revokeDaemon(id: \"#{id}\") { id status } }")
        |> get_in(["data", "revokeDaemon"])

      assert revoked["status"] == "revoked"

      # Enrolled identities stay listed for both owners; neither can remove them.
      other_conn = authenticate(build_conn(), ctx.other)

      assert error_message(run(other_conn, "mutation { unregisterDaemon(id: \"#{id}\") { id } }")) ==
               "daemon not found"

      assert error_message(run(ctx.conn, "mutation { unregisterDaemon(id: \"#{id}\") { id } }")) ==
               "daemon has enrollment history and cannot be unregistered until work ownership is established"

      fleet = run(ctx.conn, "query { daemons { id status } }")
      assert [%{"id" => ^id, "status" => "revoked"}] = fleet["data"]["daemons"]
    end
  end

  describe "existing client compatibility" do
    test "prior field selections keep working and endpoint fields stay absent", ctx do
      run(ctx.conn, "mutation { createDaemon { daemon { id status insertedAt updatedAt } } }")

      fleet =
        run(
          ctx.conn,
          "query { daemons { id status name displayName enrolledAt removedAt insertedAt updatedAt } }"
        )

      assert [%{"status" => "pending"}] = fleet["data"]["daemons"]

      # The server-advertised endpoint fields were deliberately removed.
      removed = run(ctx.conn, "query { daemons { serverEndpoint } }")
      assert removed["errors"]
      assert removed["data"] == nil

      socket = run(ctx.conn, "query { daemons { socketEndpoint } }")
      assert socket["errors"]
    end
  end
end
