defmodule SacrumWeb.Graphql.DaemonBootstrapTest do
  use SacrumWeb.ConnCase, async: false

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.DaemonCredential

  setup do
    original = Application.fetch_env(:sacrum, :daemon_external_url)
    Application.put_env(:sacrum, :daemon_external_url, "https://fleet.example:8443/proxy")

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:sacrum, :daemon_external_url, value)
        :error -> Application.delete_env(:sacrum, :daemon_external_url)
      end
    end)

    %{user: create_user()}
  end

  test "create and rotate expose exact issued expiry and trusted complete endpoint", ctx do
    query = "mutation { createDaemon { daemon { id } enrollmentToken expiresAt serverEndpoint } }"

    conn =
      ctx.conn |> authenticate(ctx.user) |> put_req_header("x-forwarded-host", "attacker.example")

    created = conn |> post("/graphql", %{query: query}) |> json_response(200)
    payload = created["data"]["createDaemon"]
    assert_metadata(payload)
    id = payload["daemon"]["id"]

    query =
      "mutation { rotateDaemonCredentials(id: \"#{id}\") { daemon { id } enrollmentToken expiresAt serverEndpoint } }"

    rotated =
      build_conn()
      |> authenticate(ctx.user)
      |> post("/graphql", %{query: query})
      |> json_response(200)

    payload = rotated["data"]["rotateDaemonCredentials"]
    assert payload["daemon"]["id"] == id
    assert_metadata(payload)
  end

  test "invalid endpoint configuration creates no daemon or bootstrap", ctx do
    Application.put_env(:sacrum, :daemon_external_url, "https://private:secret@fleet.example")
    query = "mutation { createDaemon { daemon { id } enrollmentToken expiresAt serverEndpoint } }"

    result =
      ctx.conn
      |> authenticate(ctx.user)
      |> post("/graphql", %{query: query})
      |> json_response(200)

    assert [%{"message" => "Daemon endpoint is not configured correctly"}] =
             Enum.map(result["errors"], &Map.take(&1, ["message"]))

    assert Sacrum.Accounts.Daemons.list_by(ctx.user.id) == []
  end

  defp assert_metadata(payload) do
    assert payload["serverEndpoint"] == "https://fleet.example:8443/proxy"

    credential =
      Repo.one!(
        from c in DaemonCredential,
          where: c.daemon_id == ^payload["daemon"]["id"] and c.status == "active"
      )

    assert payload["expiresAt"] == DateTime.to_iso8601(credential.expires_at)
    assert credential.credential_kind == "bootstrap"
    assert Argon2.verify_pass(payload["enrollmentToken"], credential.token_hash)
  end
end
