defmodule Sacrum.Orchestrator.Routing.RouteAuditTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.RouteAudit
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  describe "deterministic?/1" do
    test "requires a local route audit with a source execution" do
      assert RouteAudit.deterministic?(%StepExecution{
               context: %{
                 "route" => %{
                   "mode" => "deterministic",
                   "source_execution_id" => Ecto.UUID.generate()
                 }
               }
             })

      refute RouteAudit.deterministic?(%StepExecution{context: %{}})
      refute RouteAudit.deterministic?(nil)
    end
  end

  describe "visit_count/2" do
    test "counts only completed deterministic audits for the same task and route step across runs" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      route =
        create_step(user, workflow, %{
          "name" => "route",
          "step_order" => 1,
          "step_type" => "route"
        })

      other_step = create_step(user, workflow, %{"name" => "other", "step_order" => 2})
      task = create_task(user, project, workflow)

      first_run = create_task_run(user, task)
      second_run = create_task_run(user, task, %{status: :completed})

      assert RouteAudit.visit_count(task, route.id) == 1

      _first_visit =
        create_step_execution(user, task, workflow, route, %{
          "task_run_id" => first_run.id,
          "context" => deterministic_route_context()
        })

      _loop_visit =
        create_step_execution(user, task, workflow, route, %{
          "task_run_id" => first_run.id,
          "context" => deterministic_route_context()
        })

      _later_run_visit =
        create_step_execution(user, task, workflow, route, %{
          "task_run_id" => second_run.id,
          "context" => deterministic_route_context()
        })

      _other_step =
        create_step_execution(user, task, workflow, other_step, %{
          "task_run_id" => first_run.id,
          "context" => deterministic_route_context()
        })

      _failed_attempt =
        create_step_execution(user, task, workflow, route, %{
          "task_run_id" => first_run.id,
          "status" => "failed",
          "context" => deterministic_route_context()
        })

      _legacy_route =
        create_step_execution(user, task, workflow, route, %{
          "task_run_id" => first_run.id,
          "context" => %{}
        })

      assert RouteAudit.visit_count(task, route.id) == 4
    end

    test "does not count another task's routes or a rolled-back local attempt" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      route =
        create_step(user, workflow, %{
          "name" => "route",
          "step_order" => 1,
          "step_type" => "route"
        })

      task = create_task(user, project, workflow)
      other_task = create_task(user, project, workflow)
      task_run = create_task_run(user, task)
      other_run = create_task_run(user, other_task)

      _other_task_visit =
        create_step_execution(user, other_task, workflow, route, %{
          "task_run_id" => other_run.id,
          "context" => deterministic_route_context()
        })

      assert {:error, :rollback_route_audit} =
               Repo.transaction(fn ->
                 {:ok, _rolled_back} =
                   Accounts.StepExecutions.insert(user.id, %{
                     task_id: task.id,
                     task_run_id: task_run.id,
                     project_id: project.id,
                     workflow_id: workflow.id,
                     step_id: route.id,
                     step_name: route.name,
                     status: "completed",
                     context: deterministic_route_context()
                   })

                 Repo.rollback(:rollback_route_audit)
               end)

      assert RouteAudit.visit_count(task, route.id) == 1
    end
  end

  defp deterministic_route_context do
    %{"route" => %{"mode" => "deterministic", "source_execution_id" => Ecto.UUID.generate()}}
  end

  defp create_step_execution(user, task, workflow, step, attrs) do
    default_attrs = %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "workflow_id" => workflow.id,
      "step_name" => step.name,
      "step_id" => step.id,
      "status" => "completed"
    }

    {:ok, execution} = Accounts.StepExecutions.insert(user.id, Map.merge(default_attrs, attrs))
    execution
  end

  defp create_task_run(user, task, attrs \\ %{}) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(
        user.id,
        task.project_id,
        task.id,
        Map.merge(%{status: :executing}, attrs)
      )

    task_run
  end

  defp create_task(user, project, workflow) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Route audit task"})
    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_step(user, workflow, attrs) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        "name" => Map.fetch!(attrs, "name"),
        "step_order" => Map.get(attrs, "step_order", 1),
        "step_type" => Map.get(attrs, "step_type", "execute"),
        "prompt" => "Run this step",
        "workflow_id" => workflow.id,
        "project_id" => workflow.project_id
      })

    step
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{name: "Route audit workflow"})

    workflow
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Route audit project"})
    project
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "route-audit-#{suffix}@example.com",
        username: "routeaudit#{suffix}",
        password: "password123"
      })

    user
  end
end
