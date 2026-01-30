defmodule Sacrum.Repo.TaskWorkflows do
  @moduledoc """
  Workflow assignment and progression functions for tasks.

  ## Error Contract

  - `assign_workflow/2` returns `{:ok, task}` or `{:error, changeset}`
  - `unassign_workflow/1` returns `{:ok, task}` or `{:error, changeset}`
  - `move_to_step/2` returns `{:ok, task}` or `{:error, changeset}` or `{:error, atom}`
  - `get_current_step/1` returns `{:ok, step}` or `{:error, atom}`

  ## Domain-Specific Errors

  `move_to_step/2` may return `{:error, atom}` for:
  - `:no_workflow` - when task has no workflow assigned
  - `:no_current_step` - when task has no current step assigned
  - `:step_not_found` - when target step does not exist
  - `:step_not_in_workflow` - when target step belongs to a different workflow
  - `:no_transition` - when no transition exists between current and target steps

  `get_current_step/1` may return `{:error, atom}` for:
  - `:no_current_step` - when task has no current step assigned
  - `:not_found` - when the current step ID does not reference an existing step

  `assign_workflow/2` may return `{:error, atom}` for:
  - `:initial_step_not_found` - when workflow's initial_step_id does not exist
  - `:workflow_has_no_steps` - when workflow has no workflow steps

  ## Preload Strategy

  Preloading is managed by callers. Functions perform necessary preloads internally
  for validation but do not return preloaded records.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, Workflow, WorkflowStep, StepExecution, StepTransition}
  alias Sacrum.Repo.Schemas.Project

  @doc """
  Assigns a workflow to a task, setting current_step_id to the workflow's initial step.
  Creates a StepExecution audit record for the initial step entry.
  """
  def assign_workflow(%Task{} = task, %Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :workflow_steps)

    with {:ok, initial_step} <- resolve_initial_step(workflow) do
      Multi.new()
      |> Multi.update(:task, task_workflow_changeset(task, workflow.id, initial_step.id))
      |> Multi.insert(:step_execution, step_execution_attrs(task.id, workflow.id, initial_step))
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} ->
          broadcast_workflow_changed(task)
          {:ok, task}

        {:error, _op, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Removes the workflow assignment from a task, clearing workflow_id and current_step_id.
  """
  def unassign_workflow(%Task{} = task) do
    task
    |> task_workflow_changeset(nil, nil)
    |> Repo.update()
  end

  @doc """
  Moves a task to a specific step within its current workflow.
  Validates that the target step belongs to the task's current workflow and
  that a StepTransition exists between the current step and the target step
  (in either direction).

  Creates a StepExecution audit record for the new step.
  """
  def move_to_step(%Task{workflow_id: nil}, _step_id), do: {:error, :no_workflow}
  def move_to_step(%Task{current_step_id: nil}, _step_id), do: {:error, :no_current_step}

  def move_to_step(%Task{} = task, step_id) do
    with {:ok, target_step} <- get_workflow_step(task.workflow_id, step_id),
         :ok <- validate_transition_exists(task.current_step_id, target_step.id) do
      Multi.new()
      |> Multi.update(:task, task_workflow_changeset(task, task.workflow_id, target_step.id))
      |> Multi.insert(
        :step_execution,
        step_execution_attrs(task.id, task.workflow_id, target_step)
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} ->
          broadcast_workflow_changed(task)
          {:ok, task}

        {:error, _op, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Returns the current WorkflowStep for a task, or {:error, :no_current_step}.
  """
  def get_current_step(%Task{current_step_id: nil}), do: {:error, :no_current_step}

  def get_current_step(%Task{current_step_id: step_id}) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :not_found}
      step -> {:ok, step}
    end
  end

  # Private helpers

  defp resolve_initial_step(%Workflow{initial_step_id: step_id})
       when not is_nil(step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :initial_step_not_found}
      step -> {:ok, step}
    end
  end

  defp resolve_initial_step(%Workflow{workflow_steps: steps}) when is_list(steps) do
    case Enum.sort_by(steps, & &1.step_order) do
      [first | _] -> {:ok, first}
      [] -> {:error, :workflow_has_no_steps}
    end
  end

  defp task_workflow_changeset(task, workflow_id, step_id) do
    task
    |> Ecto.Changeset.change(%{workflow_id: workflow_id, current_step_id: step_id})
    |> Ecto.Changeset.foreign_key_constraint(:workflow_id)
    |> Ecto.Changeset.foreign_key_constraint(:current_step_id)
  end

  defp step_execution_attrs(task_id, workflow_id, step) do
    StepExecution.create_changeset(%StepExecution{}, %{
      task_id: task_id,
      workflow_id: workflow_id,
      step_name: step.name,
      status: "entered"
    })
  end

  defp get_workflow_step(workflow_id, step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil ->
        {:error, :step_not_found}

      %WorkflowStep{} = step ->
        if step.workflow_id == workflow_id do
          {:ok, step}
        else
          {:error, :step_not_in_workflow}
        end
    end
  end

  defp validate_transition_exists(from_step_id, to_step_id) do
    query =
      from(t in StepTransition,
        where:
          (t.from_step_id == ^from_step_id and t.to_step_id == ^to_step_id) or
            (t.from_step_id == ^to_step_id and t.to_step_id == ^from_step_id)
      )

    if Repo.exists?(query) do
      :ok
    else
      {:error, :no_transition}
    end
  end

  defp broadcast_workflow_changed(task) do
    task = Repo.preload(task, :project)

    case task.project do
      %Project{slug: slug} ->
        SacrumWeb.ProjectChannel.broadcast_workflow_changed(slug, task)

      _ ->
        :ok
    end
  end
end
