defmodule Sacrum.Repo.TaskWorkflows do
  @moduledoc """
  Workflow assignment and progression functions for tasks.

  ## Error Contract

  - `assign_workflow/2` returns `{:ok, task}` or `{:error, changeset}`
  - `unassign_workflow/1` returns `{:ok, task}` or `{:error, changeset}`
  - `advance_to_step/2` returns `{:ok, task}` or `{:error, changeset}` or `{:error, atom}`
  - `move_to_step/2` returns `{:ok, task}` or `{:error, changeset}` or `{:error, atom}`
  - `get_current_step/1` returns `{:ok, step}` or `{:error, atom}`

  ## Domain-Specific Errors

  `advance_to_step/2` may return `{:error, atom}` for:
  - `:no_workflow` - when task has no workflow assigned
  - `:no_current_step` - when task has no current step assigned
  - `:step_not_found` - when target step does not exist
  - `:step_not_in_workflow` - when target step belongs to a different workflow

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

  Returns an error if an orchestrator process is registered for this task.

  Idempotent: if the task is already assigned to this workflow at the initial step
  with an existing "entered" StepExecution, returns {:ok, task} without inserting
  a duplicate row.
  """
  @spec assign_workflow(Task.t(), Workflow.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def assign_workflow(%Task{} = task, %Workflow{} = workflow) do
    with :ok <- check_orchestrator_not_active(task.id),
         workflow = Repo.preload(workflow, :workflow_steps),
         {:ok, initial_step} <- resolve_initial_step(workflow) do
      if already_assigned?(task, workflow, initial_step) do
        {:ok, task}
      else
        execute_assign_workflow_multi(task, workflow, initial_step)
      end
    end
  end

  @doc """
  Removes the workflow assignment from a task, clearing workflow_id and current_step_id.
  """
  @spec unassign_workflow(Task.t()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def unassign_workflow(%Task{} = task) do
    task
    |> task_workflow_changeset(nil, nil)
    |> Repo.update()
  end

  @doc """
  Advances a task to a specific step within its current workflow.

  Validates that the target step belongs to the task's current workflow, then
  updates the task's current_step_id and creates an "entered" StepExecution
  audit record. Optionally stores handoff data on the new execution record.
  Transition validity is assumed since transitions are validated on creation.

  By default, returns an error if an orchestrator process is registered for this task
  (CLI-only call). Pass `skip_orchestrator_check: true` for internal/orchestrator calls.

  Options:
    - `skip_orchestrator_check` (boolean): Skip orchestrator registration check

  Returns:
    - {:ok, task} with updated current_step_id on success
    - {:error, :no_workflow} if task has no workflow
    - {:error, :no_current_step} if task has no current step
    - {:error, :step_not_found} if target step doesn't exist
    - {:error, :step_not_in_workflow} if target step belongs to a different workflow
    - {:error, :orchestrator_active} if an orchestrator process is registered (CLI-only)
    - {:error, changeset} on database errors
  """
  @spec advance_to_step(Task.t(), String.t(), map() | nil, keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def advance_to_step(task, step_id, handoff \\ nil, opts \\ [])

  def advance_to_step(%Task{workflow_id: nil}, _step_id, _handoff, _opts),
    do: {:error, :no_workflow}

  def advance_to_step(%Task{current_step_id: nil}, _step_id, _handoff, _opts),
    do: {:error, :no_current_step}

  def advance_to_step(%Task{} = task, step_id, handoff, opts) do
    with :ok <- maybe_check_orchestrator(task.id, opts),
         {:ok, target_step} <- get_workflow_step(task.workflow_id, step_id) do
      Multi.new()
      |> invalidate_entered_executions(task.id, task.workflow_id, target_step.id)
      |> Multi.update(:task, task_workflow_changeset(task, task.workflow_id, target_step.id))
      |> Multi.insert(
        :step_execution,
        step_execution_attrs(task, task.workflow_id, target_step, handoff)
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
  Moves a task to a specific step within its current workflow.
  Validates that the target step belongs to the task's current workflow and
  that a StepTransition exists between the current step and the target step
  (in either direction).

  Optionally stores handoff data on the new execution record.
  Creates a StepExecution audit record for the new step.

  By default, returns an error if an orchestrator process is registered for this task
  (CLI-only call). Pass `skip_orchestrator_check: true` for internal/orchestrator calls.
  """
  @spec move_to_step(Task.t(), String.t(), map() | nil, keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def move_to_step(task, step_id, handoff \\ nil, opts \\ [])
  def move_to_step(%Task{workflow_id: nil}, _step_id, _handoff, _opts), do: {:error, :no_workflow}

  def move_to_step(%Task{current_step_id: nil}, _step_id, _handoff, _opts),
    do: {:error, :no_current_step}

  def move_to_step(%Task{} = task, step_id, handoff, opts) do
    with :ok <- maybe_check_orchestrator(task.id, opts),
         {:ok, target_step} <- get_workflow_step(task.workflow_id, step_id),
         :ok <- validate_transition_exists(task.current_step_id, target_step.id) do
      Multi.new()
      |> invalidate_entered_executions(task.id, task.workflow_id, target_step.id)
      |> Multi.update(:task, task_workflow_changeset(task, task.workflow_id, target_step.id))
      |> Multi.insert(
        :step_execution,
        step_execution_attrs(task, task.workflow_id, target_step, handoff)
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
  @spec get_current_step(Task.t()) :: {:ok, WorkflowStep.t()} | {:error, atom()}
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
  @spec start_current_step(Task.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
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

  If the step is final, sets `completed_at` on the task. If the step is not final, just completes
  the execution (caller uses `move_to_step` to advance).
  """
  @spec complete_current_step(Task.t()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def complete_current_step(%Task{} = task) do
    with {:ok, execution, step} <- get_latest_step_execution(task),
         :ok <- validate_execution_status(execution, "started", :not_in_started_status) do
      if step.is_final do
        complete_final_step(task, execution)
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
  @spec reject_current_step(Task.t(), String.t(), String.t() | nil) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
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

  defp maybe_check_orchestrator(task_id, opts) do
    if Keyword.get(opts, :skip_orchestrator_check, false) do
      :ok
    else
      check_orchestrator_not_active(task_id)
    end
  end

  defp check_orchestrator_not_active(task_id) do
    case Registry.lookup(Sacrum.Orchestrator.TaskRegistry, task_id) do
      [] -> :ok
      _pids -> {:error, :orchestrator_active}
    end
  end

  defp invalidate_entered_executions(multi, task_id, workflow_id, step_id) do
    Multi.update_all(
      multi,
      :invalidate,
      from(e in StepExecution,
        where:
          e.task_id == ^task_id and
            e.step_id == ^step_id and
            e.workflow_id == ^workflow_id and
            e.status == "entered"
      ),
      set: [status: "invalidated"]
    )
  end

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

  defp build_assign_workflow_multi(task, workflow, initial_step) do
    Multi.new()
    |> maybe_invalidate_previous_workflow(task, workflow.id)
    |> Multi.update(:task, task_workflow_changeset(task, workflow.id, initial_step.id))
    |> Multi.insert(
      :step_execution,
      step_execution_attrs(task, workflow.id, initial_step)
    )
  end

  defp maybe_invalidate_previous_workflow(multi, %Task{current_step_id: nil}, _new_workflow_id),
    do: multi

  defp maybe_invalidate_previous_workflow(multi, %Task{workflow_id: same}, same), do: multi

  defp maybe_invalidate_previous_workflow(multi, task, _new_workflow_id) do
    Multi.update_all(
      multi,
      :invalidate,
      from(e in StepExecution,
        where:
          e.task_id == ^task.id and
            e.workflow_id == ^task.workflow_id and
            e.status == "entered"
      ),
      set: [status: "invalidated"]
    )
  end

  defp task_workflow_changeset(task, workflow_id, step_id) do
    task
    |> Ecto.Changeset.change(%{workflow_id: workflow_id, current_step_id: step_id})
    |> Ecto.Changeset.foreign_key_constraint(:workflow_id)
    |> Ecto.Changeset.foreign_key_constraint(:current_step_id)
  end

  defp step_execution_attrs(%Task{} = task, workflow_id, step, handoff \\ nil) do
    attrs = %{
      task_id: task.id,
      workflow_id: workflow_id,
      step_id: step.id,
      step_name: step.name,
      status: "entered"
    }

    attrs = if is_map(handoff), do: Map.put(attrs, :handoff, handoff), else: attrs

    StepExecution.create_changeset(
      %StepExecution{user_id: task.user_id, project_id: task.project_id},
      attrs
    )
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
              se.step_id == ^step.id and
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

  defp complete_final_step(task, execution) do
    Multi.new()
    |> Multi.update(:execution, StepExecution.update_changeset(execution, %{status: "completed"}))
    |> Multi.update(:task, Ecto.Changeset.change(task, %{completed_at: DateTime.utc_now()}))
    |> Repo.transaction()
    |> case do
      {:ok, %{task: task, execution: execution}} ->
        broadcast_task_changed(task)
        broadcast_execution_changed(execution)
        {:ok, task}

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

  defp execute_assign_workflow_multi(task, workflow, initial_step) do
    task
    |> build_assign_workflow_multi(workflow, initial_step)
    |> Repo.transaction()
    |> case do
      {:ok, %{task: task}} ->
        broadcast_task_changed(task)
        {:ok, task}

      {:error, _op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp already_assigned?(task, workflow, initial_step) do
    task.workflow_id == workflow.id and
      task.current_step_id == initial_step.id and
      Repo.exists?(
        from(e in StepExecution,
          where:
            e.task_id == ^task.id and
              e.step_id == ^initial_step.id and
              e.workflow_id == ^workflow.id and
              e.status == "entered"
        )
      )
  end
end
