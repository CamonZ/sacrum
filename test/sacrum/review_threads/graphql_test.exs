defmodule Sacrum.ReviewThreads.GraphqlTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Accounts.{ChatCatalog, Projects}

  @entry_fields "threadId projectId installationId revision updatedAt payload"
  @mutation """
  mutation($p: Uuid4!, $m: Uuid4!, $id: Uuid4!, $r: Int!, $key: Uuid4!, $payload: Json!) {
    putReviewThread(projectId: $p, installationId: $m, threadId: $id,
      expectedRevision: $r, mutationId: $key, payload: $payload) {
      status entry { #{@entry_fields} }
    }
  }
  """
  @query """
  query($p: Uuid4!, $m: Uuid4!, $after: Uuid4, $limit: Int = 1) {
    reviewThreads(projectId: $p, installationId: $m, after: $after, limit: $limit) {
      nextCursor entries { #{@entry_fields} }
    }
  }
  """

  setup %{conn: conn} do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Review threads"})
    installation = Ecto.UUID.generate()
    {:ok, _} = ChatCatalog.register(user.id, installation)

    {:ok, _} =
      ChatCatalog.put(user.id, project.id, installation, "parent", 0, Ecto.UUID.generate(), %{})

    payload = %{
      "parent_chat_id" => "parent",
      "path" => "lib/example.ex",
      "side" => "RIGHT",
      "home_kind" => "worktree",
      "original_commit_id" => String.duplicate("a", 40),
      "original_blob_id" => String.duplicate("b", 40),
      "original_start_line" => 2,
      "original_line" => 4,
      "start_line" => 3,
      "line" => 5
    }

    args = %{
      p: project.id,
      m: installation,
      id: Ecto.UUID.generate(),
      key: Ecto.UUID.generate(),
      r: 0
    }

    %{conn: authenticate(conn, user), args: args, payload: payload}
  end

  test "CAS, durable replay, terminal tombstones and pagination use the same projection", c do
    assert %{"status" => "conflict", "entry" => nil} =
             write(c.conn, %{c.args | r: 1}, c.payload)

    assert %{"status" => "accepted", "entry" => %{"revision" => 1} = original} =
             write(c.conn, c.args, c.payload)

    assert %{"status" => "conflict", "entry" => ^original} =
             write(c.conn, %{c.args | key: Ecto.UUID.generate()}, %{})

    assert %{"status" => "accepted", "entry" => %{"revision" => 2} = updated} =
             write(c.conn, %{c.args | key: Ecto.UUID.generate(), r: 1}, %{"line" => 7})

    assert updated["payload"]["line"] == 7
    assert %{"status" => "accepted", "entry" => ^updated} = write(c.conn, c.args, c.payload)

    delete_args = %{c.args | key: Ecto.UUID.generate(), r: 2}

    assert %{"status" => "accepted", "entry" => %{"revision" => 3} = deleted} =
             write(c.conn, delete_args, %{"deleted" => true})

    assert deleted["payload"]["deleted"]

    assert %{"status" => "accepted", "entry" => ^deleted} =
             write(c.conn, delete_args, %{"deleted" => true})

    assert %{"status" => "conflict", "entry" => ^deleted} =
             write(c.conn, %{c.args | key: Ecto.UUID.generate(), r: 3}, %{"deleted" => false})

    assert %{"entry" => second} =
             write(c.conn, %{c.args | id: Ecto.UUID.generate()}, c.payload)

    [first, last] = Enum.sort_by([deleted, second], & &1["threadId"])
    assert %{"entries" => [^first], "nextCursor" => cursor} = page(c.conn, c.args)
    assert cursor == first["threadId"]
    assert %{"entries" => [^last], "nextCursor" => nil} = page(c.conn, c.args, cursor)
  end

  test "invalid writes are atomic and foreign accounts cannot read or write entries", c do
    assert %{"entry" => original} = write(c.conn, c.args, c.payload)
    update = %{c.args | key: Ecto.UUID.generate(), r: 1}

    for payload <- [
          %{"line" => 8, "user_id" => Ecto.UUID.generate()},
          %{"line" => "8"},
          %{"line" => 2_147_483_648},
          %{"line" => nil},
          %{"path" => "different.ex"}
        ] do
      assert_error(c.conn, update, payload, "invalid_payload")
    end

    assert %{"entries" => [^original]} = page(c.conn, c.args)

    assert_error(
      c.conn,
      %{c.args | id: Ecto.UUID.generate()},
      %{c.payload | "parent_chat_id" => "missing"},
      "not_found"
    )

    other = create_user(%{email: "other-review@example.com", username: "otherreview"})
    other_conn = authenticate(Phoenix.ConnTest.build_conn(), other)
    assert %{"entries" => []} = page(other_conn, c.args)
    assert_error(other_conn, c.args, c.payload, "not_found")
    assert_error(other_conn, update, %{}, "not_found")
  end

  test "an unchanged write advances the revision once", c do
    assert %{"status" => "accepted", "entry" => %{"revision" => 1}} =
             write(c.conn, c.args, c.payload)

    args = %{c.args | key: Ecto.UUID.generate(), r: 1}

    assert %{"status" => "accepted", "entry" => %{"revision" => 2} = entry} =
             write(c.conn, args, %{})

    assert %{"status" => "accepted", "entry" => ^entry} = write(c.conn, args, %{})
  end

  test "out-of-range page limits return an invalid_payload error", c do
    for limit <- [0, 201] do
      assert %{"errors" => [%{"code" => "invalid_payload"}]} =
               run(c.conn, @query, %{p: c.args.p, m: c.args.m, limit: limit})
    end
  end

  defp assert_error(conn, args, payload, code) do
    assert %{"errors" => [%{"code" => ^code}]} =
             run(conn, @mutation, Map.put(args, :payload, Jason.encode!(payload)))
  end

  defp write(conn, args, payload) do
    assert %{"data" => %{"putReviewThread" => result}} =
             run(conn, @mutation, Map.put(args, :payload, Jason.encode!(payload)))

    result
  end

  defp page(conn, args, cursor \\ nil) do
    assert %{"data" => %{"reviewThreads" => result}} =
             run(conn, @query, %{p: args.p, m: args.m, after: cursor})

    result
  end

  defp run(conn, query, variables),
    do: post(conn, "/graphql", %{query: query, variables: variables}) |> json_response(200)
end
