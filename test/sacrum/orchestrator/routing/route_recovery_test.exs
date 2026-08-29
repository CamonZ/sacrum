defmodule Sacrum.Orchestrator.Routing.RouteRecoveryTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.RouteRecovery
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun

  test "restores the persisted deterministic handoff without reevaluating the route" do
    %{user: user, project: project, task: task, route: route, destination: destination} =
      fixture()

    task_run = create_task_run(user, task)

    route_execution =
      create_route_execution(user, task, route, task_run, destination.id, %{
        "review" => "required"
      })

    {:ok, task} = Repo.update(Ecto.Changeset.change(task, current_step_id: destination.id))
    task_run = update_cursor(task_run, route_execution.id)

    assert {:ok, recovered} = RouteRecovery.restore(fsm_data(user, project, task, task_run))
    assert recovered.pending_handoff == %{"review" => "required"}
  end

  test "leaves ordinary TaskRun cursors unchanged" do
    %{user: user, project: project, task: task} = fixture()
    task_run = create_task_run(user, task)

    assert {:ok, recovered} = RouteRecovery.restore(fsm_data(user, project, task, task_run))
    assert recovered.pending_handoff == nil
  end

  test "does not fail closed when the TaskRun cannot be loaded" do
    %{user: user, project: project, task: task} = fixture()
    data = fsm_data(user, project, task, %{id: Ecto.UUID.generate()})

    assert {:ok, recovered} = RouteRecovery.restore(data)
    assert recovered.pending_handoff == nil
  end

  test "restores an inter-workflow audit after the task has left the source workflow" do
    %{user: user, project: project, task: task, route: route} = fixture()
    destination_workflow = create_workflow(user, project)

    destination =
      create_step(user, destination_workflow, %{
        name: "next",
        step_order: 1,
        step_type: :execute
      })

    task_run = create_task_run(user, task)

    route_execution =
      create_route_execution(user, task, route, task_run, destination_workflow.id, %{}, %{
        "transition_type" => "inter_workflow"
      })

    {:ok, task} =
      Repo.update(
        Ecto.Changeset.change(task, %{
          current_step_id: destination.id,
          workflow_id: destination_workflow.id
        })
      )

    task_run = update_cursor(task_run, route_execution.id)

    assert {:ok, recovered} = RouteRecovery.restore(fsm_data(user, project, task, task_run))
    assert recovered.pending_handoff == %{}
  end

  test "rejects a deterministic route record whose destination disagrees with the task" do
    %{user: user, project: project, task: task, route: route, destination: destination} =
      fixture()

    task_run = create_task_run(user, task)
    route_execution = create_route_execution(user, task, route, task_run, destination.id, %{})
    task_run = update_cursor(task_run, route_execution.id)

    assert {:error, :route_recovery_inconsistent} =
             RouteRecovery.restore(fsm_data(user, project, task, task_run))
  end

  defp fixture do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)
    route = create_step(user, workflow, %{name: "route", step_order: 1, step_type: :route})

    destination =
      create_step(user, workflow, %{name: "destination", step_order: 2, step_type: :execute})

    {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: route.id})
    task = create_task(user, project, workflow)

    %{user: user, project: project, task: task, route: route, destination: destination}
  end

  defp create_route_execution(user, task, route, task_run, destination_id, handoff, opts \\ %{}) do
    transition_type = Map.get(opts, "transition_type", "intra_workflow")

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, %{
        task_id: task.id,
        task_run_id: task_run.id,
        project_id: task.project_id,
        workflow_id: task.workflow_id,
        step_id: route.id,
        step_name: route.name,
        step_type: :route,
        status: "completed",
        handoff: handoff,
        context: %{
          "route" => %{"mode" => "deterministic", "source_execution_id" => Ecto.UUID.generate()}
        },
        transition_result:
          Jason.encode!(%{"dest_id" => destination_id, "transition_type" => transition_type})
      })

    execution
  end

  defp fsm_data(user, project, task, task_run) do
    %{
      user_id: user.id,
      project_id: project.id,
      task: task,
      task_run_id: task_run.id,
      pending_handoff: nil
    }
  end

  defp update_cursor(task_run, execution_id) do
    {:ok, task_run} =
      task_run
      |> TaskRun.update_changeset(%{latest_step_execution_id: execution_id})
      |> Repo.update()

    task_run
  end

  defp create_task_run(user, task) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(user.id, task.project_id, task.id, %{status: :executing})

    task_run
  end

  defp create_task(user, project, workflow) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Route recovery task"})
    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_step(user, workflow, attrs) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        name: attrs.name,
        step_order: attrs.step_order,
        step_type: attrs.step_type,
        prompt: "Run this step",
        workflow_id: workflow.id,
        project_id: workflow.project_id
      })

    step
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{name: "Route recovery workflow"})

    workflow
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Route recovery project"})
    project
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "route-recovery-#{suffix}@example.com",
        username: "routerecovery#{suffix}",
        password: "password123"
      })

    user
  end
end
