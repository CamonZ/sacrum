defmodule SacrumWeb.Graphql.ProjectRunHistoryTest do
  use SacrumWeb.ConnCase, async: true

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskRun}

  @history """
  query History(
    $projectId: Uuid4!
    $afterUpdatedAt: Datetime
    $afterId: Uuid4
    $limit: Int
    $includeCompleted: Boolean
    $search: String
  ) {
    projectRunHistory(
      projectId: $projectId
      afterUpdatedAt: $afterUpdatedAt
      afterId: $afterId
      limit: $limit
      includeCompleted: $includeCompleted
      search: $search
    ) {
      hasMore
      hiddenCompletedCount
      entries {
        taskRun { id taskId projectId status updatedAt }
        task { id title level parentId workflowId workflowName completedAt }
      }
    }
  }
  """

  setup %{conn: conn} do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "History API"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Delivery"})
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "History task"})
    Repo.update_all(where(Task, [t], t.id == ^task.id), set: [workflow_id: workflow.id])
    %{conn: conn, user: user, project: project, task: task}
  end

  defp run(ctx, status, seconds) do
    {:ok, run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: status})

    at = DateTime.add(~U[2026-11-15 06:00:00.000000Z], seconds, :second)
    Repo.update_all(where(TaskRun, [tr], tr.id == ^run.id), set: [updated_at: at])
    run
  end

  defp history(ctx, variables) do
    ctx.conn
    |> authenticate(ctx.user)
    |> post("/graphql", %{
      "query" => @history,
      "variables" => Map.put(variables, "projectId", ctx.project.id)
    })
    |> json_response(200)
  end

  test "pages project history with task labels", ctx do
    newest = run(ctx, :executing, 3)
    middle = run(ctx, :failed, 2)
    _done = run(ctx, :completed, 1)

    %{"data" => %{"projectRunHistory" => first}} = history(ctx, %{"limit" => 1})

    assert first["hasMore"]
    assert first["hiddenCompletedCount"] == 1
    assert [%{"taskRun" => %{"id" => id} = run, "task" => task}] = first["entries"]
    assert id == newest.id
    assert run["status"] == "executing"

    assert task == %{
             "id" => ctx.task.id,
             "title" => "History task",
             "level" => "task",
             "parentId" => nil,
             "workflowId" => run_workflow_id(ctx),
             "workflowName" => "Delivery",
             "completedAt" => nil
           }

    %{"data" => %{"projectRunHistory" => second}} =
      history(ctx, %{"afterUpdatedAt" => run["updatedAt"], "afterId" => id})

    assert Enum.map(second["entries"], & &1["taskRun"]["id"]) == [middle.id]
    refute second["hasMore"]
  end

  test "includes completed history and searches on request", ctx do
    run(ctx, :completed, 1)

    %{"data" => %{"projectRunHistory" => page}} =
      history(ctx, %{"includeCompleted" => true, "search" => "HISTORY"})

    assert length(page["entries"]) == 1
    assert page["hiddenCompletedCount"] == 0
  end

  test "explicit null cursor values request the first page", ctx do
    run = run(ctx, :executing, 1)

    for variables <- [%{"afterUpdatedAt" => nil, "afterId" => nil}, %{"afterUpdatedAt" => nil}] do
      assert %{"data" => %{"projectRunHistory" => %{"entries" => [entry]}}} =
               history(ctx, variables)

      assert entry["taskRun"]["id"] == run.id
    end

    assert %{"errors" => [%{"message" => "afterUpdatedAt and afterId must be provided together"}]} =
             history(ctx, %{"afterUpdatedAt" => nil, "afterId" => Ecto.UUID.generate()})
  end

  test "rejects half a cursor and out-of-range limits", ctx do
    assert %{"errors" => [%{"message" => "afterUpdatedAt and afterId must be provided together"}]} =
             history(ctx, %{"afterId" => Ecto.UUID.generate()})

    assert %{"errors" => [%{"message" => "limit must be between 1 and 200"}]} =
             history(ctx, %{"limit" => 0})
  end

  test "another user's project is not found", ctx do
    suffix = System.unique_integer([:positive])

    stranger =
      create_user(%{email: "stranger-#{suffix}@example.com", username: "stranger#{suffix}"})

    result =
      ctx.conn
      |> authenticate(stranger)
      |> post("/graphql", %{"query" => @history, "variables" => %{"projectId" => ctx.project.id}})
      |> json_response(200)

    assert result["data"]["projectRunHistory"] == nil
    assert [%{"message" => "not_found"}] = result["errors"]
  end

  defp run_workflow_id(ctx), do: Repo.get!(Task, ctx.task.id).workflow_id
end
