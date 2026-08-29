defmodule Sacrum.Orchestrator.Routing.RouteProvenanceTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.RouteProvenance
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun

  test "resolves the TaskRun cursor instead of a newer unrelated task execution" do
    %{user: user, project: project, workflow: workflow, task: task, source: source, route: route} =
      route_fixture()

    task_run = create_task_run(user, task)

    source_execution =
      create_execution(user, task, workflow, source, %{task_run_id: task_run.id, output: "source"})

    _unrelated_later_execution =
      create_execution(user, task, workflow, source, %{output: "newer unrelated execution"})

    task_run = update_cursor(task_run, source_execution.id)

    assert {:ok, provenance} =
             RouteProvenance.resolve(
               fsm_data(user, project, task, task_run, source, route),
               route
             )

    assert provenance.task_run.id == task_run.id
    assert provenance.source_execution.id == source_execution.id
    assert provenance.source_step.id == source.id
    assert provenance.route_step.id == route.id
  end

  test "rejects a missing TaskRun cursor" do
    %{user: user, project: project, task: task, source: source, route: route} = route_fixture()
    task_run = create_task_run(user, task)

    assert {:error, :route_provenance_missing_cursor} =
             RouteProvenance.resolve(
               fsm_data(user, project, task, task_run, source, route),
               route
             )
  end

  test "rejects cursor executions outside the active TaskRun and task scope" do
    %{user: user, project: project, workflow: workflow, task: task, source: source, route: route} =
      route_fixture()

    task_run = create_task_run(user, task)
    other_run = create_task_run(user, task)

    other_run_execution =
      create_execution(user, task, workflow, source, %{task_run_id: other_run.id})

    task_run = update_cursor(task_run, other_run_execution.id)

    assert {:error, :route_provenance_cursor_execution_not_found} =
             RouteProvenance.resolve(
               fsm_data(user, project, task, task_run, source, route),
               route
             )
  end

  test "rejects an incomplete cursor source and a source without an incoming edge" do
    %{user: user, project: project, workflow: workflow, task: task, source: source, route: route} =
      route_fixture()

    task_run = create_task_run(user, task)

    incomplete =
      create_execution(user, task, workflow, source, %{
        task_run_id: task_run.id,
        status: "started"
      })

    task_run = update_cursor(task_run, incomplete.id)

    assert {:error, :route_provenance_cursor_execution_not_found} =
             RouteProvenance.resolve(
               fsm_data(user, project, task, task_run, source, route),
               route
             )

    completed =
      create_execution(user, task, workflow, source, %{
        task_run_id: task_run.id,
        status: "completed"
      })

    task_run = update_cursor(task_run, completed.id)
    data = fsm_data(user, project, task, task_run, source, route, %{source.id => []})

    assert {:error, :route_provenance_no_incoming_transition} =
             RouteProvenance.resolve(data, route)
  end

  defp route_fixture do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)
    source = create_step(user, workflow, %{name: "source", step_order: 1})

    route =
      create_step(user, workflow, %{name: "route", step_order: 2, step_type: :route, prompt: nil})

    {:ok, _transition} =
      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: source.id,
        to_step_id: route.id,
        project_id: project.id
      })

    {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})
    task = create_task(user, project, workflow)
    {:ok, task} = Repo.update(Ecto.Changeset.change(task, current_step_id: route.id))

    %{user: user, project: project, workflow: workflow, task: task, source: source, route: route}
  end

  defp fsm_data(user, project, task, task_run, source, route, transitions \\ nil) do
    %{
      user_id: user.id,
      project_id: project.id,
      task: task,
      task_run_id: task_run.id,
      workflow: %{id: task.workflow_id},
      steps: %{source.id => source, route.id => route},
      transitions: transitions || %{source.id => [route.id], route.id => []}
    }
  end

  defp update_cursor(task_run, execution_id) do
    {:ok, task_run} =
      task_run
      |> TaskRun.update_changeset(%{latest_step_execution_id: execution_id})
      |> Repo.update()

    task_run
  end

  defp create_execution(user, task, workflow, step, attrs) do
    attrs =
      Map.merge(
        %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "completed"
        },
        attrs
      )

    {:ok, execution} = Accounts.StepExecutions.insert(user.id, attrs)
    execution
  end

  defp create_task_run(user, task) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(user.id, task.project_id, task.id, %{status: :executing})

    task_run
  end

  defp create_task(user, project, workflow) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Route provenance task"})
    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_step(user, workflow, attrs) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        name: attrs.name,
        step_order: attrs.step_order,
        step_type: Map.get(attrs, :step_type, :execute),
        prompt: Map.get(attrs, :prompt, "Run this step"),
        workflow_id: workflow.id,
        project_id: workflow.project_id
      })

    step
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{name: "Route provenance workflow"})

    workflow
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Route provenance project"})
    project
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "route-provenance-#{suffix}@example.com",
        username: "routeprovenance#{suffix}",
        password: "password123"
      })

    user
  end
end
