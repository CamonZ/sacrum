defmodule SacrumWeb.TaskWorkflowControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.StepTransitions
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

  defp setup_workflow(%{project: project} = context) do
    {:ok, workflow} = Workflows.insert(project, %{name: "Dev Workflow"})
    {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "backlog", step_order: 1})
    {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "in_progress", step_order: 2})
    {:ok, step3} = WorkflowSteps.insert(workflow, %{name: "done", step_order: 3, is_final: true})

    {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: step1.id})

    {:ok, _} = StepTransitions.insert(%{from_step_id: step1.id, to_step_id: step2.id})
    {:ok, _} = StepTransitions.insert(%{from_step_id: step2.id, to_step_id: step3.id})

    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})

    Map.merge(context, %{
      workflow: workflow,
      steps: %{backlog: step1, in_progress: step2, done: step3},
      task: task
    })
  end

  describe "POST /api/tasks/:tid/assign-workflow" do
    setup [:setup_authenticated, :setup_workflow]

    test "assigns workflow and returns task with workflow_id", ctx do
      conn =
        post(
          ctx.conn,
          ~p"/api/tasks/#{ctx.task.id}/assign-workflow",
          %{workflow_id: ctx.workflow.id}
        )

      assert %{
               "data" => %{
                 "workflow_id" => workflow_id,
                 "current_step_id" => step_id
               }
             } = json_response(conn, 200)

      assert workflow_id == ctx.workflow.id
      assert step_id == ctx.steps.backlog.id
    end
  end

  describe "DELETE /api/tasks/:tid/assign-workflow" do
    setup [:setup_authenticated, :setup_workflow]

    test "unassigns workflow and clears step", ctx do
      # First assign
      post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/assign-workflow", %{
        workflow_id: ctx.workflow.id
      })

      conn = delete(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/assign-workflow")

      assert %{
               "data" => %{
                 "workflow_id" => nil,
                 "current_step_id" => nil
               }
             } = json_response(conn, 200)
    end
  end

  describe "POST /api/tasks/:tid/move-to" do
    setup [:setup_authenticated, :setup_workflow]

    test "moves task to a valid forward step", ctx do
      # Assign workflow first
      post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/assign-workflow", %{
        workflow_id: ctx.workflow.id
      })

      conn =
        post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/move-to", %{
          step_id: ctx.steps.in_progress.id
        })

      assert %{
               "data" => %{
                 "current_step_id" => step_id
               }
             } = json_response(conn, 200)

      assert step_id == ctx.steps.in_progress.id
    end

    test "moves task to a valid backward step", ctx do
      # Assign and move forward first
      post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/assign-workflow", %{
        workflow_id: ctx.workflow.id
      })

      post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/move-to", %{
        step_id: ctx.steps.in_progress.id
      })

      conn =
        post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/move-to", %{
          step_id: ctx.steps.backlog.id
        })

      assert %{
               "data" => %{
                 "current_step_id" => step_id
               }
             } = json_response(conn, 200)

      assert step_id == ctx.steps.backlog.id
    end

    test "returns 422 when task has no workflow", ctx do
      conn =
        post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/move-to", %{
          step_id: ctx.steps.in_progress.id
        })

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)
    end

    test "returns 422 when no transition exists to target step", ctx do
      # Assign workflow — task is at backlog
      post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/assign-workflow", %{
        workflow_id: ctx.workflow.id
      })

      # Try to jump from backlog to done (no direct transition)
      conn =
        post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/move-to", %{
          step_id: ctx.steps.done.id
        })

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)
    end

    test "returns 422 when step_id does not exist", ctx do
      post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/assign-workflow", %{
        workflow_id: ctx.workflow.id
      })

      conn =
        post(ctx.conn, ~p"/api/tasks/#{ctx.task.id}/move-to", %{
          step_id: Ecto.UUID.generate()
        })

      assert %{"errors" => %{"detail" => _}} = json_response(conn, 422)
    end
  end
end
