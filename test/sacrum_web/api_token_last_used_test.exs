defmodule SacrumWeb.ApiTokenLastUsedTest do
  use SacrumWeb.ConnCase, async: true

  import Ecto.Query

  alias Sacrum.Auth
  alias Sacrum.QueryCounter
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ApiToken

  @query %{"query" => "{ __typename }"}

  setup do
    user = create_user()
    {:ok, token, api_token} = Auth.create_api_token(user)
    %{token: token, api_token: api_token}
  end

  defp request(conn, token) do
    conn
    |> recycle()
    |> put_req_header("authorization", "Bearer #{token}")
    |> post("/graphql", @query)
  end

  defp last_used_at(api_token), do: Repo.get!(ApiToken, api_token.id).last_used_at

  defp set_last_used_at(api_token, value) do
    Repo.update_all(where(ApiToken, [t], t.id == ^api_token.id), set: [last_used_at: value])
  end

  defp token_writes(statements),
    do: Enum.filter(statements, &String.starts_with?(&1, ~s(UPDATE "api_tokens")))

  test "repeated requests inside the interval write last_used_at once", ctx do
    {conns, statements} =
      QueryCounter.capture(fn -> for _ <- 1..5, do: request(ctx.conn, ctx.token) end)

    assert Enum.all?(conns, &(&1.status == 200))
    assert length(token_writes(statements)) == 1
    # One authentication lookup per request, user joined into it.
    assert Enum.count(statements, &String.contains?(&1, ~s(FROM "api_tokens"))) == 5
    assert %DateTime{} = last_used_at(ctx.api_token)
  end

  test "last_used_at advances once the interval has passed", ctx do
    stale =
      DateTime.add(DateTime.utc_now(), -(Auth.last_used_interval_seconds() + 1), :second)

    set_last_used_at(ctx.api_token, stale)

    {conn, statements} = QueryCounter.capture(fn -> request(ctx.conn, ctx.token) end)

    assert conn.status == 200
    assert length(token_writes(statements)) == 1
    assert DateTime.compare(last_used_at(ctx.api_token), stale) == :gt
  end

  test "a recent last_used_at is left untouched", ctx do
    recent = DateTime.add(DateTime.utc_now(), -10, :second)
    set_last_used_at(ctx.api_token, recent)

    {conn, statements} = QueryCounter.capture(fn -> request(ctx.conn, ctx.token) end)

    assert conn.status == 200
    assert token_writes(statements) == []
    assert last_used_at(ctx.api_token) == recent
  end

  test "expired tokens are rejected on every request, even inside the interval", ctx do
    set_last_used_at(ctx.api_token, DateTime.utc_now())

    Repo.update_all(where(ApiToken, [t], t.id == ^ctx.api_token.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    for _ <- 1..3 do
      conn = request(ctx.conn, ctx.token)
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "API token has expired"}
    end
  end

  test "invalid and revoked tokens are rejected on every request", ctx do
    assert request(ctx.conn, ctx.token).status == 200

    for _ <- 1..2 do
      assert json_response(request(ctx.conn, "sac_not_a_token"), 401) == %{
               "error" => "Invalid API token"
             }
    end

    Repo.delete!(ctx.api_token)

    assert json_response(request(ctx.conn, ctx.token), 401) == %{"error" => "Invalid API token"}
  end

  test "sequential touches with a stale struct update the row once", ctx do
    {:ok, token} = Auth.verify_api_token(ctx.token)
    now = DateTime.utc_now()

    {_, statements} =
      QueryCounter.capture(fn ->
        Auth.touch_token_last_used(token, now)
        # A second request verified before the first write still holds the
        # old timestamp; the conditional update keeps it from writing again.
        Auth.touch_token_last_used(token, DateTime.add(now, 1, :second))
      end)

    assert length(token_writes(statements)) == 2
    assert last_used_at(ctx.api_token) == now
  end
end
