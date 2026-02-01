defmodule SacrumWeb.SessionLogControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.SessionLogs

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    %{conn: conn, user: user, project: project}
  end

  defp setup_with_execution(%{project: project} = context) do
    {:ok, workflow} = Workflows.insert(project, %{name: "Test WF"})
    {:ok, step} = WorkflowSteps.insert(workflow, %{name: "start", step_order: 1})
    {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: step.id})
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

    # Get the execution created by assign_workflow
    [execution | _] =
      StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

    Map.merge(context, %{task: task, execution: execution})
  end

  describe "GET /api/executions/:execution_id/logs" do
    setup [:setup_authenticated, :setup_with_execution]

    test "returns chronological list of session logs", ctx do
      {:ok, _} =
        SessionLogs.insert(ctx.execution.user_id, %{
          step_execution_id: ctx.execution.id,
          content: "Log line 1"
        })

      {:ok, _} =
        SessionLogs.insert(ctx.execution.user_id, %{
          step_execution_id: ctx.execution.id,
          content: "Log line 2"
        })

      conn = get(ctx.conn, ~p"/api/executions/#{ctx.execution.id}/logs")

      assert %{"data" => logs} = json_response(conn, 200)
      assert length(logs) == 2
      assert hd(logs)["content"] == "Log line 1"
    end

    test "returns empty list for execution with no logs", ctx do
      conn = get(ctx.conn, ~p"/api/executions/#{ctx.execution.id}/logs")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "authentication" do
    test "returns 401 without auth token", %{conn: conn} do
      execution_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/api/executions/#{execution_id}/logs")

      assert json_response(conn, 401)
    end
  end
end
