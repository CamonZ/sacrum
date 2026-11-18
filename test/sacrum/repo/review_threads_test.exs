defmodule Sacrum.Repo.ReviewThreadsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{ChatCatalog, Projects}
  alias Sacrum.Repo.{ReviewThreads, Users}
  alias Sacrum.Repo.Schemas.ReviewThread

  setup do
    user = create_owner()
    {:ok, project} = Projects.insert(user.id, %{name: "Threads"})
    installation_id = Ecto.UUID.generate()
    {:ok, _} = ChatCatalog.register(user.id, installation_id)

    {:ok, %{status: "accepted"}} =
      ChatCatalog.put(
        user.id,
        project.id,
        installation_id,
        "parent",
        0,
        Ecto.UUID.generate(),
        %{}
      )

    scope = %ReviewThread{
      user_id: user.id,
      project_id: project.id,
      installation_id: installation_id
    }

    attrs = %{
      id: Ecto.UUID.generate(),
      parent_chat_id: "parent",
      path: "lib/example.ex",
      side: "RIGHT",
      home_kind: :worktree,
      original_commit_id: String.duplicate("a", 40),
      original_blob_id: String.duplicate("b", 64),
      original_start_line: 2,
      original_line: 4,
      start_line: 3,
      line: 5
    }

    %{scope: scope, attrs: attrs}
  end

  test "queries and parent references require the entire trusted scope", %{
    scope: scope,
    attrs: attrs
  } do
    {:ok, other_project} = Projects.insert(scope.user_id, %{name: "Other"})
    other_installation = Ecto.UUID.generate()
    {:ok, _} = ChatCatalog.register(scope.user_id, other_installation)
    other_user = create_owner()
    {:ok, foreign_project} = Projects.insert(other_user.id, %{name: "Foreign"})
    {:ok, _} = ChatCatalog.register(other_user.id, scope.installation_id)

    forged = Map.put(attrs, :project_id, other_project.id)
    {:ok, thread} = Repo.insert(ReviewThread.changeset(scope, forged))
    assert thread.project_id == scope.project_id

    assert Repo.one(scoped_query(scope)) == thread

    for other_scope <- [
          %{scope | project_id: other_project.id},
          %{scope | installation_id: other_installation},
          %{scope | user_id: other_user.id, project_id: foreign_project.id}
        ] do
      assert Repo.all(scoped_query(other_scope)) == []
      assert {0, _} = Repo.update_all(scoped_query(other_scope), set: [deleted: true])

      assert {:error, changeset} =
               other_scope
               |> ReviewThread.changeset(%{attrs | id: Ecto.UUID.generate()})
               |> Repo.insert(mode: :savepoint)

      assert %{parent_chat_id: [_]} = errors_on(changeset)
    end
  end

  test "validates coordinates, Git object IDs, enums and tool anchors", %{
    scope: scope,
    attrs: attrs
  } do
    for {field, value, error_field} <- [
          {:path, "/absolute", :path},
          {:path, "../outside", :path},
          {:path, "lib/../outside", :path},
          {:path, String.duplicate("a", 4097), :path},
          {:original_commit_id, String.duplicate("A", 40), :original_commit_id},
          {:original_blob_id, "123", :original_blob_id},
          {:side, "UP", :side},
          {:home_kind, :tool_call, :tool_use_id},
          {:status, :outdated, :line},
          {:origin_kind, :github, :origin_kind},
          {:original_start_line, 0, :original_start_line},
          {:original_line, 1, :original_line},
          {:line, nil, :line},
          {:line, 2, :line}
        ] do
      changeset = ReviewThread.changeset(scope, Map.put(attrs, field, value))
      assert Map.has_key?(errors_on(changeset), error_field)
    end

    attrs = Map.merge(attrs, %{home_kind: :tool_call, tool_use_id: "tool-1"})

    assert {:ok, %ReviewThread{home_kind: :tool_call}} =
             Repo.insert(ReviewThread.changeset(scope, attrs))
  end

  test "database enforces coordinates even when writes bypass changesets", %{
    scope: scope,
    attrs: attrs
  } do
    thread = Repo.insert!(ReviewThread.changeset(scope, attrs))
    query = scoped_query(scope)

    for {changes, constraint} <- [
          {[line: nil], "review_threads_current_range_valid"},
          {[start_line: 0], "review_threads_current_range_valid"},
          {[start_line: 6], "review_threads_current_range_valid"},
          {[status: :outdated], "review_threads_current_range_valid"},
          {[path: "another.ex"], "review_threads_anchor_immutable"}
        ] do
      assert_db_constraint(constraint, fn -> Repo.update_all(query, set: changes) end)
    end

    assert Repo.one!(query) == thread
  end

  test "updates preserve the original anchor, advance revision and make tombstones terminal", %{
    scope: scope,
    attrs: attrs
  } do
    thread = Repo.insert!(ReviewThread.changeset(scope, attrs))
    query = scoped_query(scope)

    for {field, value} <- [
          {:path, "another.ex"},
          {:side, :left},
          {:home_kind, :tool_call},
          {:tool_use_id, "tool-1"},
          {:original_commit_id, String.duplicate("c", 40)},
          {:original_blob_id, String.duplicate("d", 64)},
          {:original_start_line, 1},
          {:original_line, 6}
        ] do
      assert "cannot change after insertion" in errors_on(
               ReviewThread.changeset(thread, %{field => value})
             )[field]
    end

    assert thread.revision == 1

    outdated =
      thread
      |> ReviewThread.changeset(%{status: :outdated, start_line: nil, line: nil})
      |> Repo.update!()

    assert outdated.revision == 2
    assert {1, _} = Repo.update_all(query, set: [outdated_noted: true, revision: 1])
    assert Repo.one!(query).revision == 3
    assert {1, _} = Repo.update_all(query, set: [deleted: true])
    assert %{deleted: true, revision: 4} = tombstone = Repo.one!(query)
    refute ReviewThread.changeset(tombstone, %{deleted: false}).valid?

    assert_db_constraint("review_threads_tombstone_terminal", fn ->
      Repo.update_all(query, set: [deleted: false])
    end)
  end

  test "database checks original coordinates and anchor format on insert", %{
    scope: scope,
    attrs: attrs
  } do
    now = DateTime.utc_now()

    row =
      Map.merge(attrs, %{
        user_id: scope.user_id,
        project_id: scope.project_id,
        installation_id: scope.installation_id,
        side: :right,
        inserted_at: now,
        updated_at: now
      })

    for {changes, constraint} <- [
          {%{path: "lib/../outside"}, "review_threads_path_valid"},
          {%{original_blob_id: String.duplicate("B", 64)}, "review_threads_object_ids_valid"},
          {%{original_line: 1}, "review_threads_original_range_valid"},
          {%{home_kind: :tool_call}, "review_threads_home_valid"},
          {%{revision: 0}, "review_threads_revision_positive"}
        ] do
      assert_db_constraint(constraint, fn ->
        Repo.insert_all(ReviewThread, [Map.merge(row, changes)])
      end)
    end

    assert {1, _} = Repo.insert_all(ReviewThread, [row])
    assert %{side: :right, revision: 1} = Repo.one!(scoped_query(scope))
  end

  defp scoped_query(scope) do
    ReviewThreads.scope(scope.user_id, scope.project_id, scope.installation_id)
  end

  defp assert_db_constraint(constraint, operation) do
    error = assert_raise Postgrex.Error, fn -> Repo.transaction(operation, mode: :savepoint) end
    assert error.postgres.constraint == constraint
  end

  defp create_owner do
    name = "review#{System.unique_integer([:positive])}"

    {:ok, user} =
      Users.insert(%{email: "#{name}@example.com", username: name, password: "password123"})

    user
  end
end
