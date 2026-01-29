defmodule SacrumWeb.StepExecutionControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Auth

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user do
    {:ok, user} = Users.insert(@valid_user_attrs)
    user
  end

  defp authenticate(conn, user) do
    {:ok, token, _api_token} = Auth.create_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

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

    Map.merge(context, %{task: task, workflow: workflow, step: step})
  end

  describe "GET /api/projects/:project_id/tasks/:task_id/executions" do
    setup [:setup_authenticated, :setup_with_execution]

    test "returns chronological list of step executions", ctx do
      conn =
        get(ctx.conn, ~p"/api/projects/#{ctx.project.id}/tasks/#{ctx.task.id}/executions")

      assert %{"data" => executions} = json_response(conn, 200)
      assert length(executions) >= 1
      assert hd(executions)["step_name"] == "start"
    end

    test "returns empty list for task with no executions", ctx do
      {:ok, task2} = Tasks.insert(ctx.project, %{title: "No Executions"})

      conn =
        get(ctx.conn, ~p"/api/projects/#{ctx.project.id}/tasks/#{task2.id}/executions")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/projects/:project_id/executions/:id" do
    setup [:setup_authenticated, :setup_with_execution]

    test "returns single execution with full details", ctx do
      # Get the execution created during workflow assignment
      conn =
        get(ctx.conn, ~p"/api/projects/#{ctx.project.id}/tasks/#{ctx.task.id}/executions")

      %{"data" => [execution | _]} = json_response(conn, 200)

      conn =
        get(ctx.conn, ~p"/api/projects/#{ctx.project.id}/executions/#{execution["id"]}")

      assert %{"data" => %{"id" => _, "step_name" => "start", "status" => "entered"}} =
               json_response(conn, 200)
    end

    test "returns 404 for nonexistent execution", ctx do
      conn =
        get(
          ctx.conn,
          ~p"/api/projects/#{ctx.project.id}/executions/#{Ecto.UUID.generate()}"
        )

      assert json_response(conn, 404)
    end
  end

  describe "authentication" do
    test "returns 401 without auth token", %{conn: conn} do
      project_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      conn =
        get(conn, ~p"/api/projects/#{project_id}/tasks/#{task_id}/executions")

      assert json_response(conn, 401)
    end
  end
end
