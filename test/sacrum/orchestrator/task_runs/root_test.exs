defmodule Sacrum.Orchestrator.TaskRuns.RootTest do
  use Sacrum.DataCase, async: true

  import Ecto.Query

  alias Sacrum.Accounts.{Projects, TaskRuns, Tasks, WorkflowSteps, Workflows}
  alias Sacrum.Orchestrator.TaskRuns.Root
  alias Sacrum.Repo
  alias Sacrum.Repo.{StepTransitions, TaskWorkflows, Users}
  alias Sacrum.Repo.Schemas.WorkflowStep

  test "get_or_create creates a queued root run when no active run exists" do
    user = create_user()
    {_project, task} = create_task(user)

    assert {:ok, task_run} = Root.get_or_create(task)
    assert task_run.status == :queued
    assert task_run.task_id == task.id
    assert task_run.project_id == task.project_id
    assert task_run.user_id == user.id
    assert task_run.parent_task_run_id == nil
    assert task_run.root_task_run_id == nil
    assert task_run.max_concurrency == nil
  end

  test "get_or_create persists the root concurrency limit" do
    user = create_user()
    {_project, task} = create_task(user)

    assert {:ok, task_run} = Root.get_or_create(task, max_concurrency: 2)
    assert task_run.max_concurrency == 2
  end

  test "get_or_create reuses an active root run" do
    user = create_user()
    {_project, task} = create_task(user)

    {:ok, existing_run} =
      TaskRuns.insert(user.id, task.project_id, task.id, %{status: :executing})

    assert {:ok, task_run} = Root.get_or_create(task)
    assert task_run.id == existing_run.id
  end

  test "validate_dispatchable rejects terminal runs" do
    user = create_user()
    {_project, task} = create_task(user)

    {:ok, completed_run} =
      TaskRuns.insert(user.id, task.project_id, task.id, %{status: :completed})

    assert {:error, {:task_run_not_dispatchable, :completed}} =
             Root.validate_dispatchable(completed_run)
  end

  test "get_or_create creates a new root run after a run boundary" do
    user = create_user()
    {_project, task} = create_task(user)

    {:ok, stopped_run} =
      TaskRuns.insert(user.id, task.project_id, task.id, %{
        status: :stopped,
        ended_at: DateTime.utc_now(),
        outcome_kind: "run_boundary",
        outcome_context: %{"step_id" => task.current_step_id}
      })

    assert {:ok, new_run} = Root.get_or_create(task)
    assert new_run.id != stopped_run.id
    assert new_run.status == :queued
  end

  test "get_or_create creates a queued run even when the graph is invalid" do
    %{task: task, source: source} = configured_route_task()
    invalidate_source_schema(source)

    # Root is a TaskRun acquisition boundary only. An invalid graph is
    # rejected when the FSM loads its validated snapshot in :initializing,
    # not before the TaskRun row exists.
    assert {:ok, task_run} = Root.get_or_create(task)
    assert task_run.status == :queued
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "task-runs-root-#{suffix}@example.com",
        username: "taskrunsroot#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Root Project"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Root Task"})

    {project, task}
  end

  defp configured_route_task do
    user = create_user()
    {project, task} = create_task(user)
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Route workflow"})

    source =
      create_step(user, workflow, "source", 1, output_schema: predecessor_schema(["approved"]))

    destination = create_step(user, workflow, "destination", 2)
    route = create_step(user, workflow, "route", 3, step_type: "route", prompt: "Fallback")

    create_transition(user, source, route)
    create_transition(user, route, destination)

    {:ok, route} =
      WorkflowSteps.update(route, %{route_config: route_config(destination.id)})

    {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

    %{route: route, source: source, task: task}
  end

  defp create_step(user, workflow, name, order, attrs \\ []) do
    defaults = %{
      name: name,
      prompt: "Prompt for #{name}",
      step_order: order,
      workflow_id: workflow.id,
      project_id: workflow.project_id
    }

    {:ok, step} = WorkflowSteps.insert(user.id, Map.merge(defaults, Map.new(attrs)))
    step
  end

  defp create_transition(user, from_step, to_step) do
    {:ok, transition} =
      StepTransitions.insert(user.id, %{
        from_step_id: from_step.id,
        to_step_id: to_step.id,
        project_id: from_step.project_id
      })

    transition
  end

  defp invalidate_source_schema(source) do
    Repo.update_all(
      from(step in WorkflowStep, where: step.id == ^source.id),
      set: [output_schema: nil]
    )
  end

  defp route_config(destination_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "approved",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "approved"
          },
          "transition" => %{"type" => "intra_workflow", "step_id" => destination_id}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_id" => destination_id}
      }
    }
  end

  defp predecessor_schema(result_values) do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => result_values},
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
end
