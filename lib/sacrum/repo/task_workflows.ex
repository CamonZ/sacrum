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
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.{StepExecution, StepTransition, Task, Workflow, WorkflowStep}

  @doc """
  Assigns a workflow to a task, setting current_step_id to the workflow's initial step.
  Creates a StepExecution audit record for the initial step entry.
  """
  def assign_workflow(%Task{} = task, %Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :workflow_steps)

    with {:ok, initial_step} <- resolve_initial_step(workflow) do
      Multi.new()
      |> Multi.update(:task, task_workflow_changeset(task, workflow.id, initial_step.id))
      |> Multi.insert(
        :step_execution,
        step_execution_attrs(task.id, task.user_id, task.project_id, workflow.id, initial_step)
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} ->
          broadcast_task_changed(task)
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
        step_execution_attrs(
          task.id,
          task.user_id,
          task.project_id,
          task.workflow_id,
          target_step
        )
      )
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} ->
          broadcast_task_changed(task)
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

  @doc """
  Starts the current step by updating the latest StepExecution from "entered" to "started".
  Also sets `started_at` on the task if it hasn't been set yet.
  """
  def start_current_step(%Task{} = task) do
    with {:ok, execution, _step} <- get_latest_step_execution(task),
         :ok <- validate_execution_status(execution, "entered", :not_in_entered_status) do
      Multi.new()
      |> Multi.update(:execution, StepExecution.update_changeset(execution, %{status: "started"}))
      |> maybe_set_started_at(task)
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task, execution: execution}} ->
          broadcast_task_changed(task)
          broadcast_execution_changed(execution)
          {:ok, task}

        {:ok, %{execution: execution}} ->
          task = Repo.get!(Task, task.id)
          broadcast_task_changed(task)
          broadcast_execution_changed(execution)
          {:ok, task}

        {:error, _op, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Completes the current step by updating the latest StepExecution from "started" to "completed".

  If the step is final:
  - If the workflow has `on_done_workflow_id`, chains to that workflow via `assign_workflow/2`
  - Otherwise, sets `completed_at` on the task

  If the step is not final, just completes the execution (caller uses `move_to_step` to advance).
  """
  def complete_current_step(%Task{} = task) do
    with {:ok, execution, step} <- get_latest_step_execution(task),
         :ok <- validate_execution_status(execution, "started", :not_in_started_status) do
      if step.is_final do
        complete_final_step(task, execution, step)
      else
        complete_non_final_step(task, execution)
      end
    end
  end

  @doc """
  Rejects the current step by updating the latest StepExecution from "started" to "rejected",
  then moves the task to the target step.

  Optionally stores feedback in the execution's `transition_result` field.
  """
  def reject_current_step(%Task{} = task, target_step_id, feedback \\ nil) do
    with {:ok, execution, _step} <- get_latest_step_execution(task),
         :ok <- validate_execution_status(execution, "started", :not_in_started_status) do
      reject_attrs = %{status: "rejected"}

      reject_attrs =
        if feedback, do: Map.put(reject_attrs, :transition_result, feedback), else: reject_attrs

      Multi.new()
      |> Multi.update(:execution, StepExecution.update_changeset(execution, reject_attrs))
      |> Repo.transaction()
      |> case do
        {:ok, %{execution: execution}} ->
          broadcast_execution_changed(execution)
          task = Repo.get!(Task, task.id)
          move_to_step(task, target_step_id)

        {:error, _op, changeset, _changes} ->
          {:error, changeset}
      end
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

  defp step_execution_attrs(task_id, user_id, project_id, workflow_id, step) do
    StepExecution.create_changeset(%StepExecution{user_id: user_id, project_id: project_id}, %{
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

  defp get_latest_step_execution(%Task{} = task) do
    with {:ok, step} <- get_current_step(task) do
      query =
        from(se in StepExecution,
          where:
            se.task_id == ^task.id and
              se.step_name == ^step.name and
              se.workflow_id == ^task.workflow_id,
          order_by: [desc: se.inserted_at],
          limit: 1
        )

      case Repo.one(query) do
        nil -> {:error, :no_step_execution}
        execution -> {:ok, execution, step}
      end
    end
  end

  defp validate_execution_status(%StepExecution{status: status}, expected, _error)
       when status == expected,
       do: :ok

  defp validate_execution_status(_execution, _expected, error), do: {:error, error}

  defp maybe_set_started_at(multi, %Task{started_at: nil} = task) do
    Multi.update(multi, :task, Ecto.Changeset.change(task, %{started_at: DateTime.utc_now()}))
  end

  defp maybe_set_started_at(multi, _task), do: multi

  defp complete_final_step(task, execution, _step) do
    workflow = Repo.preload(task, :workflow).workflow

    Multi.new()
    |> Multi.update(:execution, StepExecution.update_changeset(execution, %{status: "completed"}))
    |> maybe_complete_or_chain(task, workflow)
    |> Repo.transaction()
    |> case do
      {:ok, %{task: task, execution: execution}} ->
        broadcast_task_changed(task)
        broadcast_execution_changed(execution)
        {:ok, task}

      {:ok, %{execution: execution}} ->
        broadcast_execution_changed(execution)
        # on_done_workflow chain case — assign_workflow handles its own transaction
        task = Repo.get!(Task, task.id)

        case chain_to_workflow(task, workflow) do
          {:ok, task} -> {:ok, task}
          {:error, reason} -> {:error, reason}
        end

      {:error, _op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp complete_non_final_step(task, execution) do
    Multi.new()
    |> Multi.update(:execution, StepExecution.update_changeset(execution, %{status: "completed"}))
    |> Repo.transaction()
    |> case do
      {:ok, %{execution: execution}} ->
        task = Repo.get!(Task, task.id)
        broadcast_task_changed(task)
        broadcast_execution_changed(execution)
        {:ok, task}

      {:error, _op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp maybe_complete_or_chain(multi, task, %Workflow{on_done_workflow_id: nil}) do
    Multi.update(multi, :task, Ecto.Changeset.change(task, %{completed_at: DateTime.utc_now()}))
  end

  defp maybe_complete_or_chain(multi, _task, %Workflow{on_done_workflow_id: _id}) do
    # Don't set completed_at — will chain to next workflow after transaction
    multi
  end

  defp chain_to_workflow(task, %Workflow{on_done_workflow_id: wf_id})
       when not is_nil(wf_id) do
    case Repo.get(Workflow, wf_id) do
      nil -> {:error, :on_done_workflow_not_found}
      next_workflow -> assign_workflow(task, next_workflow)
    end
  end

  defp broadcast_execution_changed(execution) do
    require Logger
    task = Repo.get(Task, execution.task_id)

    if task do
      task = Repo.preload(task, :project)

      case task.project do
        %Project{id: project_id} ->
          Logger.info("[Broadcast] step_execution_status_changed for project #{project_id}")

          SacrumWeb.ProjectChannel.broadcast_step_execution_status_changed(
            project_id,
            execution
          )

        _ ->
          :ok
      end
    end
  end

  defp broadcast_task_changed(task) do
    require Logger
    task = Repo.preload(task, :project)

    case task.project do
      %Project{id: project_id} ->
        Logger.info("[Broadcast] task_updated for project #{project_id}")
        SacrumWeb.ProjectChannel.broadcast_task_updated(project_id, task)

      _ ->
        Logger.warning("[Broadcast] task_updated failed to extract project_id")
        :ok
    end
  end
end
