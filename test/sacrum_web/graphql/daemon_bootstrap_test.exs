defmodule SacrumWeb.Graphql.DaemonBootstrapTest do
  use SacrumWeb.ConnCase, async: false

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.DaemonCredential

  setup do
    %{user: create_user()}
  end

  test "create and rotate expose exact issued expiry", ctx do
    query = "mutation { createDaemon { daemon { id } enrollmentToken expiresAt } }"

    conn =
      ctx.conn |> authenticate(ctx.user) |> put_req_header("x-forwarded-host", "attacker.example")

    created = conn |> post("/graphql", %{query: query}) |> json_response(200)
    payload = created["data"]["createDaemon"]
    assert_metadata(payload)
    id = payload["daemon"]["id"]

    query =
      "mutation { rotateDaemonCredentials(id: \"#{id}\") { daemon { id } enrollmentToken expiresAt } }"

    rotated =
      build_conn()
      |> authenticate(ctx.user)
      |> post("/graphql", %{query: query})
      |> json_response(200)

    payload = rotated["data"]["rotateDaemonCredentials"]
    assert payload["daemon"]["id"] == id
    assert_metadata(payload)
  end

  defp assert_metadata(payload) do
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
