defmodule SacrumWeb.StepExecutionControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.TaskWorkflows

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

  describe "GET /api/tasks/:task_id/executions" do
    setup [:setup_authenticated, :setup_with_execution]

    test "returns chronological list of step executions", ctx do
      conn = get(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/executions")

      assert %{"data" => executions} = json_response(conn, 200)
      assert length(executions) >= 1
      assert hd(executions)["step_name"] == "start"
    end

    test "returns empty list for task with no executions", ctx do
      {:ok, task2} = Tasks.insert(ctx.project, %{title: "No Executions"})

      conn = get(ctx.conn, ~p"/api/tasks/#{task2.id}/executions")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/executions/:id" do
    setup [:setup_authenticated, :setup_with_execution]

    test "returns single execution with full details", ctx do
      # Get the execution created during workflow assignment
      conn = get(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/executions")

      %{"data" => [execution | _]} = json_response(conn, 200)

      conn = get(ctx.conn, ~p"/api/executions/#{execution["id"]}")

      assert %{"data" => %{"id" => _, "step_name" => "start", "status" => "entered"}} =
               json_response(conn, 200)
    end

    test "returns 404 for nonexistent execution", ctx do
      conn = get(ctx.conn, ~p"/api/executions/#{Ecto.UUID.generate()}")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/tasks/:task_id/executions" do
    setup [:setup_authenticated, :setup_with_execution]

    test "creates a new step execution with valid params", ctx do
      params = %{
        "step_name" => "process",
        "status" => "running",
        "prompt" => "Test prompt",
        "output" => "Test output"
      }

      conn = post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/executions", params)

      assert %{"data" => execution} = json_response(conn, 201)
      assert execution["step_name"] == "process"
      assert execution["status"] == "running"
      assert execution["prompt"] == "Test prompt"
      assert execution["output"] == "Test output"
      assert execution["task_id"] == ctx.task.id
    end

    test "returns 422 when missing required fields", ctx do
      params = %{
        "status" => "running"
      }

      conn = post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/executions", params)

      assert json_response(conn, 422)
    end

    test "returns 401 without auth token", %{task: task} do
      conn = build_conn()
      params = %{"step_name" => "test", "status" => "running"}

      conn = post(conn, ~p"/api/tasks/#{task.id}/executions", params)

      assert json_response(conn, 401)
    end
  end

  describe "PATCH /api/executions/:id" do
    setup [:setup_authenticated, :setup_with_execution]

    test "updates an existing step execution", ctx do
      # Get the execution created during workflow assignment
      conn = get(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/executions")

      %{"data" => [execution | _]} = json_response(conn, 200)

      params = %{
        "status" => "completed",
        "output" => "Updated output",
        "output_tokens" => 100
      }

      conn = patch(ctx.conn, ~p"/api/executions/#{execution["id"]}", params)

      assert %{"data" => updated} = json_response(conn, 200)
      assert updated["status"] == "completed"
      assert updated["output"] == "Updated output"
      assert updated["output_tokens"] == 100
    end

    test "returns 404 for nonexistent execution", ctx do
      params = %{"status" => "completed"}

      conn = patch(ctx.conn, ~p"/api/executions/#{Ecto.UUID.generate()}", params)

      assert json_response(conn, 404)
    end

    test "returns 401 without auth token" do
      execution_id = Ecto.UUID.generate()
      params = %{"status" => "completed"}

      conn = build_conn()
      conn = patch(conn, ~p"/api/executions/#{execution_id}", params)

      assert json_response(conn, 401)
    end
  end

  describe "authentication" do
    test "returns 401 without auth token", %{conn: conn} do
      task_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/api/tasks/#{task_id}/executions")

      assert json_response(conn, 401)
    end
  end
end
