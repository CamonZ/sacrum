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

    source =
      create_step(user, workflow, %{
        name: "source",
        step_order: 1,
        config: %{"output_schema" => predecessor_schema()}
      })

    destination = create_step(user, workflow, %{name: "destination", step_order: 3})

    {:ok, workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})

    route =
      create_step(user, workflow, %{
        name: "route",
        step_order: 2,
        step_type: :route,
        config: %{"route_config" => route_config(destination.id)}
      })

    {:ok, _outgoing_transition} =
      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: route.id,
        to_step_id: destination.id,
        project_id: project.id
      })

    {:ok, _transition} =
      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: source.id,
        to_step_id: route.id,
        project_id: project.id
      })

    task = create_task(user, project, workflow)
    {:ok, task} = Repo.update(Ecto.Changeset.change(task, current_step_id: route.id))

    %{user: user, project: project, workflow: workflow, task: task, source: source, route: route}
  end

  defp predecessor_schema do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => ["approved"]},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => [],
              "properties" => %{}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end

  defp route_config(target_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "task-level",
          "when" => %{"ref" => "task.level", "op" => "eq", "value" => "task"},
          "transition" => %{"type" => "intra_workflow", "step_id" => target_id}
        }
      ],
      "default" => %{"transition" => %{"type" => "intra_workflow", "step_id" => target_id}}
    }
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
    step_type = Map.get(attrs, :step_type, :llm_inference)

    step_attrs =
      %{
        name: attrs.name,
        step_order: attrs.step_order,
        step_type: step_type,
        workflow_id: workflow.id,
        project_id: workflow.project_id
      }
      |> Map.merge(Map.take(attrs, [:config]))
      |> put_default_config(step_type)

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, step_attrs)
    step
  end

  # llm_inference steps get a default prompt under any config the caller supplies.
  defp put_default_config(attrs, :llm_inference) do
    default = %{"prompt" => "Run this step"}
    Map.update(attrs, :config, default, &Map.merge(default, &1))
  end

  defp put_default_config(attrs, _step_type), do: attrs

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
