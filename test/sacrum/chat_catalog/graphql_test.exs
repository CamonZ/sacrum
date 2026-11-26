defmodule Sacrum.ChatCatalog.GraphqlTest do
  use SacrumWeb.ConnCase, async: true
  alias Sacrum.Accounts.{ChatCatalog, Projects, ReviewThreads, Tasks}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatCatalogEntry, StepExecution, TaskRun}

  @put_catalog """
  mutation($p: Uuid4!, $m: Uuid4!, $id: String!, $mutation: Uuid4!, $revision: Int!, $payload: Json!) {
    putChatCatalog(projectId: $p, installationId: $m, chatId: $id, mutationId: $mutation,
      expectedRevision: $revision, payload: $payload) {
      status entry { chatId revision payload updatedAt }
    }
  }
  """

  @history """
  query($p: Uuid4!, $m: Uuid4!, $after: String, $limit: Int = 100, $completed: Boolean = false) {
    chatCatalogHistory(projectId: $p, installationId: $m, after: $after,
      limit: $limit, includeCompleted: $completed) {
      entries { chatId updatedAt }
      nextCursor
    }
  }
  """

  setup %{conn: conn} do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "GraphQL catalog"})
    %{conn: authenticate(conn, user), user: user, project: project, machine: Ecto.UUID.generate()}
  end

  defp run(conn, query, variables \\ %{}),
    do: post(conn, "/graphql", %{query: query, variables: variables}) |> json_response(200)

  test "completed tasks are excluded by default and includeCompleted explicitly opts in", c do
    {:ok, task} = Tasks.insert(c.user.id, c.project.id, %{title: "Done"})
    Repo.update!(Ecto.Changeset.change(task, completed_at: DateTime.utc_now()))
    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    {:ok, _} =
      ChatCatalog.put(c.user.id, c.project.id, c.machine, "a-done", 0, Ecto.UUID.generate(), %{
        "task_id" => task.id
      })

    {:ok, _} =
      ChatCatalog.put(
        c.user.id,
        c.project.id,
        c.machine,
        "b-unassociated",
        0,
        Ecto.UUID.generate(),
        %{}
      )

    query =
      "query($p: Uuid4!, $m: Uuid4!) { chatCatalog(projectId: $p, installationId: $m) { entries { chatId } nextCursor } }"

    args = %{p: c.project.id, m: c.machine}
    default = run(c.conn, query, args)
    refute default["errors"]
    assert [%{"chatId" => "b-unassociated"}] = default["data"]["chatCatalog"]["entries"]
    assert default["data"]["chatCatalog"]["nextCursor"] == nil

    inclusive =
      run(
        c.conn,
        String.replace(
          query,
          "installationId: $m)",
          "installationId: $m, includeCompleted: true)"
        ),
        args
      )

    refute inclusive["errors"]

    assert Enum.map(inclusive["data"]["chatCatalog"]["entries"], & &1["chatId"]) == [
             "a-done",
             "b-unassociated"
           ]

    {:ok, _} =
      ChatCatalog.put(
        c.user.id,
        c.project.id,
        c.machine,
        "b-unassociated",
        1,
        Ecto.UUID.generate(),
        %{"task_id" => task.id}
      )

    empty = run(c.conn, query, args)
    assert empty["data"]["chatCatalog"] == %{"entries" => [], "nextCursor" => nil}
    refute empty["errors"]
  end

  test "chat activity is exposed in the GraphQL entry and payload", c do
    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    {:ok, _} =
      ChatCatalog.put(
        c.user.id,
        c.project.id,
        c.machine,
        "working-chat",
        0,
        Ecto.UUID.generate(),
        %{"status" => "working"}
      )

    response =
      run(
        c.conn,
        "{ chatCatalog(projectId: \"#{c.project.id}\", installationId: \"#{c.machine}\") { entries { status payload } } }"
      )

    assert [%{"status" => "working", "payload" => %{"status" => "working"}}] =
             response["data"]["chatCatalog"]["entries"]

    refute response["errors"]
  end

  test "linked GitHub PR metadata roundtrips verbatim in putChatCatalog, chatCatalog and chatCatalogHistory",
       c do
    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    pr_metadata = %{
      "title" => "PR chat",
      "pr_host" => "github.com",
      "pr_owner" => "CamonZ",
      "pr_repo" => "sacrum",
      "pr_number" => 42
    }

    null_pr_metadata = %{
      "title" => "No PR chat",
      "pr_host" => nil,
      "pr_owner" => nil,
      "pr_repo" => nil,
      "pr_number" => nil
    }

    assert %{
             "data" => %{
               "putChatCatalog" => %{
                 "status" => "accepted",
                 "entry" => %{"payload" => %{"metadata" => ^pr_metadata}}
               }
             }
           } = put_catalog(c, "pr-chat", 0, %{"metadata" => pr_metadata})

    assert %{
             "data" => %{
               "putChatCatalog" => %{
                 "status" => "accepted",
                 "entry" => %{"payload" => %{"metadata" => ^null_pr_metadata}}
               }
             }
           } = put_catalog(c, "null-pr-chat", 0, %{"metadata" => null_pr_metadata})

    snapshot =
      run(
        c.conn,
        "query($p: Uuid4!, $m: Uuid4!) { chatCatalog(projectId: $p, installationId: $m) { entries { chatId payload } } }",
        %{p: c.project.id, m: c.machine}
      )

    refute snapshot["errors"]

    assert Map.new(snapshot["data"]["chatCatalog"]["entries"], fn entry ->
             {entry["chatId"], entry["payload"]["metadata"]}
           end) == %{
             "pr-chat" => pr_metadata,
             "null-pr-chat" => null_pr_metadata
           }

    history =
      run(
        c.conn,
        "query($p: Uuid4!, $m: Uuid4!) { chatCatalogHistory(projectId: $p, installationId: $m) { entries { chatId payload } } }",
        %{p: c.project.id, m: c.machine}
      )

    refute history["errors"]

    assert Map.new(history["data"]["chatCatalogHistory"]["entries"], fn entry ->
             {entry["chatId"], entry["payload"]["metadata"]}
           end) == %{
             "pr-chat" => pr_metadata,
             "null-pr-chat" => null_pr_metadata
           }
  end

  test "legacy deleteTask mutation clears catalog associations without deleting the chat", c do
    {:ok, task} = Tasks.insert(c.user.id, c.project.id, %{title: "Delete me"})
    history = %{user_id: c.user.id, project_id: c.project.id, task_id: task.id}

    task_run =
      Repo.insert!(
        struct(TaskRun, Map.merge(history, %{status: :completed, started_at: DateTime.utc_now()}))
      )

    execution =
      Repo.insert!(
        struct(
          StepExecution,
          Map.merge(history, %{task_run_id: task_run.id, step_name: "gate", status: "completed"})
        )
      )

    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    {:ok, %{entry: entry}} =
      ChatCatalog.put(c.user.id, c.project.id, c.machine, "preserved", 0, Ecto.UUID.generate(), %{
        "task_id" => task.id,
        "gate_execution_id" => execution.id,
        "gate_task_run_id" => task_run.id,
        "metadata" => %{"title" => "Chat history"}
      })

    response = run(c.conn, "mutation($id: Uuid4!) { deleteTask(id: $id) { id } }", %{id: task.id})
    refute response["errors"]
    assert response["data"]["deleteTask"]["id"] == task.id

    preserved = Repo.get!(ChatCatalogEntry, entry.id)
    assert preserved.task_id == nil
    assert preserved.gate_execution_id == nil
    assert preserved.gate_task_run_id == nil
    assert preserved.metadata == entry.metadata
    assert preserved.revision > entry.revision
    assert preserved.user_id == c.user.id
    assert preserved.project_id == c.project.id
    refute preserved.deleted
  end

  test "authenticated wire contract imports, paginates, acknowledges duplicate delivery and returns conflicts",
       c do
    {:ok, task} =
      Tasks.insert(c.user.id, c.project.id, %{title: "Referenced epic", level: "epic"})

    registered =
      run(
        c.conn,
        "mutation($id: Uuid4!) { registerChatInstallation(installationId:$id) { id } }",
        %{id: c.machine}
      )

    assert registered["data"]["registerChatInstallation"]["id"] == c.machine

    args = %{
      p: c.project.id,
      m: c.machine,
      id: "original-provider-id",
      mutation: Ecto.UUID.generate(),
      revision: 0,
      payload:
        Jason.encode!(%{
          metadata: %{title: "Persistent", harness: "codex"},
          task_id: task.id,
          classifications: []
        })
    }

    first = run(c.conn, @put_catalog, args)["data"]["putChatCatalog"]
    assert first["status"] == "accepted"
    assert first["entry"]["revision"] == 1
    assert first["entry"]["payload"]["metadata"]["title"] == "Persistent"
    assert first["entry"]["payload"]["task_id"] == task.id
    assert run(c.conn, @put_catalog, args)["data"]["putChatCatalog"] == first

    conflict =
      run(c.conn, @put_catalog, %{args | mutation: Ecto.UUID.generate()})["data"][
        "putChatCatalog"
      ]

    assert conflict["status"] == "conflict"
    assert conflict["entry"] == first["entry"]

    result =
      run(
        c.conn,
        "query($p: Uuid4!, $m: Uuid4!) { chatCatalog(projectId:$p,installationId:$m,limit:1) { entries { chatId revision payload } nextCursor } }",
        %{p: c.project.id, m: c.machine}
      )

    assert [%{"chatId" => "original-provider-id"}] = result["data"]["chatCatalog"]["entries"]
    assert result["data"]["chatCatalog"]["nextCursor"] == nil
    assert [%ChatCatalogEntry{}] = Sacrum.Repo.all(ChatCatalogEntry)

    invalid =
      run(c.conn, @put_catalog, %{
        args
        | id: "old-field",
          mutation: Ecto.UUID.generate(),
          payload: Jason.encode!(%{entity_id: task.id})
      })

    assert_rejection(invalid, "invalid_payload")
    assert [%ChatCatalogEntry{}] = Sacrum.Repo.all(ChatCatalogEntry)
  end

  test "catalog write preconditions return coded errors and a tombstone still conflicts", c do
    assert_rejection(put_catalog(c, "chat", 0, %{}), "not_found")
    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    for {id, revision, payload, code} <- [
          {"chat", -1, %{}, "invalid_payload"},
          {"", 0, %{}, "invalid_payload"},
          {"missing", 1, %{}, "not_found"},
          {"child", 0, %{"parent_chat_id" => "missing"}, "not_found"}
        ] do
      assert_rejection(put_catalog(c, id, revision, payload), code)
    end

    assert %{"data" => %{"putChatCatalog" => %{"status" => "accepted", "entry" => tombstone}}} =
             put_catalog(c, "chat", 0, %{"deleted" => true})

    result = put_catalog(c, "chat", tombstone["revision"], %{})
    refute result["errors"]
    assert result["data"]["putChatCatalog"] == %{"status" => "conflict", "entry" => tombstone}
  end

  test "discussion writes distinguish invalid links from missing, mismatched, tombstoned and duplicate threads",
       c do
    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    for id <- ["parent", "other-parent"] do
      {:ok, _} =
        ChatCatalog.put(c.user.id, c.project.id, c.machine, id, 0, Ecto.UUID.generate(), %{})
    end

    thread = Ecto.UUID.generate()

    discussion = %{
      "metadata" => %{"kind" => "discussion"},
      "parent_chat_id" => "parent",
      "review_thread_id" => thread
    }

    assert_rejection(put_catalog(c, "discussion", 0, discussion), "not_found")

    assert_rejection(
      put_catalog(c, "discussion", 0, Map.delete(discussion, "review_thread_id")),
      "invalid_payload"
    )

    create_thread(c, thread, "parent")

    assert_rejection(
      put_catalog(c, "discussion", 0, %{discussion | "parent_chat_id" => "other-parent"}),
      "not_found"
    )

    assert %{"data" => %{"putChatCatalog" => %{"status" => "accepted"}}} =
             put_catalog(c, "discussion", 0, discussion)

    assert_rejection(put_catalog(c, "duplicate", 0, discussion), "not_found")

    {:ok, %{status: :accepted}} =
      ReviewThreads.put(c.user.id, c.project.id, c.machine, thread, 1, Ecto.UUID.generate(), %{
        "deleted" => true
      })

    assert_rejection(put_catalog(c, "after-delete", 0, discussion), "not_found")
  end

  test "foreign account reads and writes reveal no protected catalog", c do
    {:ok, _} = ChatCatalog.register(c.user.id, c.machine)

    {:ok, _} =
      ChatCatalog.put(c.user.id, c.project.id, c.machine, "private", 0, Ecto.UUID.generate(), %{
        "metadata" => %{"title" => "SECRET"}
      })

    other =
      create_user(%{
        email: "other-#{Ecto.UUID.generate()}@example.com",
        username: "other#{System.unique_integer([:positive])}",
        password: "password123"
      })

    conn = Phoenix.ConnTest.build_conn() |> authenticate(other)

    result =
      run(
        conn,
        "{ chatCatalog(projectId:\"#{c.project.id}\",installationId:\"#{c.machine}\") { entries { chatId payload } } }"
      )

    refute result["errors"]
    assert result["data"]["chatCatalog"]["entries"] == []
    refute inspect(result) =~ "SECRET"
    {:ok, _} = ChatCatalog.register(other.id, c.machine)

    result =
      run(
        conn,
        "mutation($payload: Json!) { putChatCatalog(projectId:\"#{c.project.id}\",installationId:\"#{c.machine}\",chatId:\"private\",expectedRevision:0,mutationId:\"#{Ecto.UUID.generate()}\",payload:$payload) { status entry { payload } } }",
        %{payload: "{}"}
      )

    assert_rejection(result, "not_found")
    refute inspect(result) =~ "SECRET"
  end

  describe "chatCatalogHistory" do
    setup c do
      {:ok, _} = ChatCatalog.register(c.user.id, c.machine)
      :ok
    end

    test "returns bounded pages with microsecond activity ordering and stable ties", c do
      older = ~U[2026-11-22 10:00:00.000001Z]
      newer = ~U[2026-11-22 10:00:00.000002Z]
      fixtures = [{"b", newer}, {"z", older}, {"a", newer}, {"m", newer}]

      for {id, time} <- fixtures do
        c |> insert_chat(id) |> Ecto.Changeset.change(updated_at: time) |> Repo.update!()
      end

      expected =
        fixtures
        |> Enum.sort_by(fn {id, time} -> {DateTime.to_unix(time, :microsecond), id} end, :desc)
        |> Enum.map(&elem(&1, 0))

      for size <- [1, 2, 3, 4, 200] do
        assert history_ids(c, size) == expected, "incorrect history for page size #{size}"
      end

      for size <- [0, 201, nil] do
        result = history(c, %{limit: size})
        assert [%{"message" => "limit must be between 1 and 200"}] = result["errors"]
      end

      for cursor <- ["", "b", String.duplicate("A", 2049) | encoded_invalid_cursors()] do
        result = history(c, %{after: cursor})
        assert [%{"message" => "invalid chat history cursor"}] = result["errors"]
      end
    end

    test "filters tombstones and direct or inherited completion before paginating", c do
      insert_completion_fixtures(c)

      assert Enum.sort(history_ids(c, 1)) == ["child-of-done", "open", "open-discussion"]

      assert Enum.sort(history_ids(c, 2, true)) == [
               "child-of-done",
               "done",
               "done-discussion",
               "open",
               "open-discussion"
             ]
    end

    test "leaves snapshot ordering, cursors, tombstones and direct-only completion unchanged",
         c do
      insert_completion_fixtures(c)

      snapshot = fn args ->
        run(c.conn, """
        { chatCatalog(projectId: "#{c.project.id}", installationId: "#{c.machine}", #{args})
          { entries { chatId } nextCursor } }
        """)["data"]["chatCatalog"]
      end

      assert snapshot.("limit: 10") == %{
               "entries" =>
                 Enum.map(
                   ["child-of-done", "deleted", "done-discussion", "open", "open-discussion"],
                   &%{"chatId" => &1}
                 ),
               "nextCursor" => nil
             }

      assert snapshot.(~s(after: "deleted", limit: 2)) == %{
               "entries" => [%{"chatId" => "done-discussion"}, %{"chatId" => "open"}],
               "nextCursor" => "open"
             }
    end

    test "isolates authenticated user, project and installation even when including completed",
         c do
      insert_chat(c, "in-scope")

      {:ok, other_project} = Projects.insert(c.user.id, %{name: "Other project"})
      insert_chat(%{c | project: other_project}, "other-project")

      installation = Ecto.UUID.generate()
      {:ok, _} = ChatCatalog.register(c.user.id, installation)
      insert_chat(%{c | machine: installation}, "other-installation")

      other =
        create_user(%{
          email: "history-other@example.com",
          username: "history_other",
          password: "password123"
        })

      assert history_ids(c, 1, true) == ["in-scope"]
      foreign = %{c | conn: Phoenix.ConnTest.build_conn() |> authenticate(other)}
      assert history_ids(foreign, 1, true) == []
    end
  end

  defp history(c, args) do
    run(c.conn, @history, Map.merge(%{p: c.project.id, m: c.machine}, args))
  end

  defp history_ids(c, size, completed \\ false) do
    pages =
      Stream.unfold({:page, nil}, fn
        :done ->
          nil

        {:page, cursor} ->
          result = history(c, %{limit: size, completed: completed, after: cursor})
          refute result["errors"]

          %{"entries" => entries, "nextCursor" => next_cursor} =
            result["data"]["chatCatalogHistory"]

          assert length(entries) <= size
          assert next_cursor == nil or length(entries) == size
          assert next_cursor == nil or next_cursor != cursor

          {Enum.map(entries, & &1["chatId"]),
           if(next_cursor, do: {:page, next_cursor}, else: :done)}
      end)
      |> Enum.take(20)

    assert length(pages) < 20, "history did not terminate"
    Enum.concat(pages)
  end

  defp encoded_invalid_cursors do
    for value <- [[2, 0, "b"], [1, "bad timestamp", "b"], [1, 0, ""], [1, 0, <<0>>]] do
      value |> Jason.encode!() |> Base.url_encode64(padding: false)
    end
  end

  defp insert_completion_fixtures(c) do
    {:ok, done} = Tasks.insert(c.user.id, c.project.id, %{title: "Done"})
    Repo.update!(Ecto.Changeset.change(done, completed_at: DateTime.utc_now()))
    {:ok, open} = Tasks.insert(c.user.id, c.project.id, %{title: "Open"})

    insert_chat(c, "done", %{"task_id" => done.id})
    insert_chat(c, "open", %{"task_id" => open.id})
    # A non-discussion child does not inherit its parent's task completion.
    insert_chat(c, "child-of-done", %{"parent_chat_id" => "done"})
    insert_chat(c, "deleted", %{"deleted" => true})

    for parent <- ["done", "open"] do
      thread = Ecto.UUID.generate()
      create_thread(c, thread, parent)

      insert_chat(c, "#{parent}-discussion", %{
        "metadata" => %{"kind" => "discussion"},
        "parent_chat_id" => parent,
        "review_thread_id" => thread
      })
    end
  end

  defp insert_chat(c, id, payload \\ %{}) do
    {:ok, %{status: "accepted", entry: entry}} =
      ChatCatalog.put(c.user.id, c.project.id, c.machine, id, 0, Ecto.UUID.generate(), payload)

    entry
  end

  defp create_thread(c, thread, parent) do
    {:ok, %{status: :accepted}} =
      ReviewThreads.put(c.user.id, c.project.id, c.machine, thread, 0, Ecto.UUID.generate(), %{
        "parent_chat_id" => parent,
        "path" => "lib/example.ex",
        "side" => "RIGHT",
        "home_kind" => "worktree",
        "original_commit_id" => String.duplicate("a", 40),
        "original_blob_id" => String.duplicate("b", 40),
        "original_start_line" => 2,
        "original_line" => 2,
        "start_line" => 2,
        "line" => 2
      })
  end

  defp put_catalog(c, id, revision, payload) do
    run(c.conn, @put_catalog, %{
      p: c.project.id,
      m: c.machine,
      id: id,
      revision: revision,
      mutation: Ecto.UUID.generate(),
      payload: Jason.encode!(payload)
    })
  end

  defp assert_rejection(result, code) do
    assert result["data"]["putChatCatalog"] == nil

    assert [%{"code" => ^code, "message" => message, "path" => ["putChatCatalog"]}] =
             result["errors"]

    assert is_binary(message)
  end
end
