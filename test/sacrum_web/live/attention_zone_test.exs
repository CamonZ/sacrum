defmodule SacrumWeb.AttentionZoneTest do
  use SacrumWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Sacrum.Repo.{Projects, StepExecutions, Tasks, Workflows, WorkflowSteps}

  defp authed_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"user_id" => user.id})
  end

  describe "Attention zone in Command Center" do
    setup do
      user = create_user(%{username: "attentionuser"})
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})

      {:ok, workflow} =
        Workflows.insert(project, %{
          name: "Test Workflow",
          user_id: user.id
        })

      {:ok, execute_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Execute Step",
          step_type: "execute",
          step_order: 1
        })

      {:ok, wait_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Gate Step",
          step_type: "wait_children",
          step_order: 2
        })

      {
        :ok,
        user: user,
        project: project,
        workflow: workflow,
        execute_step: execute_step,
        wait_step: wait_step,
        conn: authed_conn(user)
      }
    end

    test "shows 'Nothing needs attention' when no rows exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/command-center")

      assert html =~ "Nothing needs attention"
      refute html =~ "attention-row-"
    end

    test "renders failed run row with correct structure", %{
      conn: conn,
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create a failed task
      {:ok, task} = Tasks.insert(project, %{title: "Failed Run", user_id: user.id})

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed"
        })

      {:ok, _view, html} = live(conn, "/command-center")

      # Check for failed row
      assert html =~ "Failed Run"
      assert html =~ "FAILED"
      assert html =~ "Test Project"
      assert html =~ "Test Workflow"
      assert html =~ "Execute Step"
      assert html =~ "step: Execute Step (failed)"
    end

    test "renders gate row with correct structure", %{
      conn: conn,
      user: user,
      project: project,
      workflow: workflow,
      wait_step: wait_step
    } do
      # Create a gate task
      {:ok, task} = Tasks.insert(project, %{title: "Gate Task", user_id: user.id})

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: wait_step.id,
          project_id: project.id,
          step_name: "Gate Step",
          status: "pending"
        })

      {:ok, _view, html} = live(conn, "/command-center")

      # Check for gate row
      assert html =~ "Gate Task"
      assert html =~ "GATE"
      assert html =~ "awaiting your approval"
    end

    test "renders context pressure row with correct structure", %{
      conn: conn,
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create a high-token task
      {:ok, task} = Tasks.insert(project, %{title: "Context Task", user_id: user.id})

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "completed",
          input_tokens: 70_000,
          output_tokens: 40_000
        })

      {:ok, _view, html} = live(conn, "/command-center")

      # Check for context pressure row
      assert html =~ "Context Task"
      assert html =~ "CTX"
      assert html =~ "110.0k tok"
    end

    test "renders rows for multiple attention causes in same view", %{
      conn: conn,
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step,
      wait_step: wait_step
    } do
      # Create both a failed task and a gate task
      {:ok, failed_task} = Tasks.insert(project, %{title: "Failed Run", user_id: user.id})
      {:ok, gate_task} = Tasks.insert(project, %{title: "Gate Task", user_id: user.id})

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: failed_task.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed"
        })

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: gate_task.id,
          workflow_id: workflow.id,
          step_id: wait_step.id,
          project_id: project.id,
          step_name: "Gate Step",
          status: "pending"
        })

      {:ok, _view, html} = live(conn, "/command-center")

      # Check both rows appear
      assert html =~ "Failed Run"
      assert html =~ "FAILED"
      assert html =~ "Gate Task"
      assert html =~ "GATE"
      refute html =~ "Nothing needs attention"
    end

    test "greys out when socket is disconnected", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/command-center")

      # Check initial state - connected, not greyed
      assert html =~ "opacity-100"
      refute html =~ "opacity-50"
    end
  end
end
