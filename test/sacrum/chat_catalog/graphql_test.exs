defmodule Sacrum.ChatCatalog.GraphqlTest do
  use SacrumWeb.ConnCase, async: true
  alias Sacrum.Accounts.{ChatCatalog, Projects, Tasks}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatCatalogEntry, StepExecution, TaskRun}

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

    mutation =
      "mutation($p: Uuid4!, $m: Uuid4!, $id: String!, $mutation: Uuid4!, $revision: Int!, $payload: Json!) { putChatCatalog(projectId:$p,installationId:$m,chatId:$id,mutationId:$mutation,expectedRevision:$revision,payload:$payload) { status entry { chatId revision payload updatedAt } } }"

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

    first = run(c.conn, mutation, args)["data"]["putChatCatalog"]
    assert first["status"] == "accepted"
    assert first["entry"]["revision"] == 1
    assert first["entry"]["payload"]["metadata"]["title"] == "Persistent"
    assert first["entry"]["payload"]["task_id"] == task.id
    assert run(c.conn, mutation, args)["data"]["putChatCatalog"] == first

    conflict =
      run(c.conn, mutation, %{args | mutation: Ecto.UUID.generate()})["data"]["putChatCatalog"]

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
      run(c.conn, mutation, %{
        args
        | id: "old-field",
          mutation: Ecto.UUID.generate(),
          payload: Jason.encode!(%{entity_id: task.id})
      })

    assert invalid["errors"]
    assert [%ChatCatalogEntry{}] = Sacrum.Repo.all(ChatCatalogEntry)
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

    assert result["errors"]
    refute inspect(result) =~ "SECRET"
  end
end
