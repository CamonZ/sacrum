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
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.{StepTransition, Task, Workflow, WorkflowStep}
  alias Sacrum.Tasks.Status

  @doc """
  Assigns a workflow to a task, setting current_step_id to the workflow's initial step.

  Returns an error if an orchestrator process is registered for this task.

  Idempotent: if the task is already assigned to this workflow at the initial step,
  returns {:ok, task} without re-assigning.
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
        task
        |> task_workflow_changeset(workflow.id, initial_step.id)
        |> Status.put_status()
        |> Repo.update()
        |> broadcast_on_success()
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
    |> Status.put_status()
    |> Repo.update()
    |> broadcast_on_success()
  end

  @doc """
  Advances a task to a specific step within its current workflow.

  Updates the task's current_step_id only. StepExecution rows are created
  exclusively by ExecutionDispatcher at dispatch time. Handoff data flows
  through orchestrator FSM state, not through this function.

  Pass `skip_orchestrator_check: true` for internal/orchestrator calls.
  """
  @spec advance_to_step(Task.t(), String.t(), keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def advance_to_step(task, step_id, opts \\ [])

  def advance_to_step(%Task{workflow_id: nil}, _step_id, _opts), do: {:error, :no_workflow}

  def advance_to_step(%Task{current_step_id: nil}, _step_id, _opts),
    do: {:error, :no_current_step}

  def advance_to_step(%Task{} = task, step_id, opts),
    do: change_step(task, step_id, opts, validate_transition: false)

  @doc """
  Moves a task to a specific step, requiring an explicit StepTransition between
  the current and target step. Updates current_step_id only.
  """
  @spec move_to_step(Task.t(), String.t(), keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def move_to_step(task, step_id, opts \\ [])
  def move_to_step(%Task{workflow_id: nil}, _step_id, _opts), do: {:error, :no_workflow}
  def move_to_step(%Task{current_step_id: nil}, _step_id, _opts), do: {:error, :no_current_step}

  def move_to_step(%Task{} = task, step_id, opts),
    do: change_step(task, step_id, opts, validate_transition: true)

  @spec change_step(Task.t(), String.t(), keyword(), keyword()) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  defp change_step(%Task{} = task, step_id, opts, mode) do
    with :ok <- maybe_check_orchestrator(task.id, opts),
         {:ok, target_step} <- get_workflow_step(task.workflow_id, step_id),
         :ok <- maybe_validate_transition(task, target_step, mode) do
      task
      |> Ecto.Changeset.change(%{current_step_id: target_step.id})
      |> Status.put_status()
      |> Repo.update()
      |> broadcast_on_success()
    end
  end

  defp maybe_validate_transition(%Task{current_step_id: from_id}, %WorkflowStep{id: to_id},
         validate_transition: true
       ),
       do: validate_transition_exists(from_id, to_id)

  defp maybe_validate_transition(_task, _step, validate_transition: false), do: :ok

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

  # Private helpers

  @spec maybe_check_orchestrator(String.t(), keyword()) :: :ok | {:error, :orchestrator_active}
  defp maybe_check_orchestrator(task_id, opts) do
    if Keyword.get(opts, :skip_orchestrator_check, false) do
      :ok
    else
      check_orchestrator_not_active(task_id)
    end
  end

  @spec check_orchestrator_not_active(String.t()) :: :ok | {:error, :orchestrator_active}
  defp check_orchestrator_not_active(task_id) do
    case Registry.lookup(Sacrum.Orchestrator.TaskRegistry, task_id) do
      [] -> :ok
      _pids -> {:error, :orchestrator_active}
    end
  end

  @spec resolve_initial_step(Workflow.t()) ::
          {:ok, WorkflowStep.t()}
          | {:error, :initial_step_not_found | :workflow_has_no_steps}
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

  @spec task_workflow_changeset(Task.t(), String.t() | nil, String.t() | nil) ::
          Ecto.Changeset.t()
  defp task_workflow_changeset(task, workflow_id, step_id) do
    task
    |> Ecto.Changeset.change(%{workflow_id: workflow_id, current_step_id: step_id})
    |> Ecto.Changeset.foreign_key_constraint(:workflow_id)
    |> Ecto.Changeset.foreign_key_constraint(:current_step_id)
  end

  @spec get_workflow_step(String.t(), String.t()) ::
          {:ok, WorkflowStep.t()} | {:error, :step_not_found | :step_not_in_workflow}
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

  @spec validate_transition_exists(String.t(), String.t()) :: :ok | {:error, :no_transition}
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

  @spec broadcast_on_success({:ok, Task.t()} | {:error, Ecto.Changeset.t()}) ::
          {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  defp broadcast_on_success({:ok, %Task{} = task} = ok) do
    require Logger
    task = Repo.preload(task, :project)

    case task.project do
      %Project{id: project_id} ->
        Logger.info("[Broadcast] task_updated for project #{project_id}")
        SacrumWeb.ProjectChannel.broadcast_task_updated(project_id, task)

      _ ->
        Logger.warning("[Broadcast] task_updated failed to extract project_id")
    end

    ok
  end

  defp broadcast_on_success({:error, _changeset} = error), do: error

  @spec already_assigned?(Task.t(), Workflow.t(), WorkflowStep.t()) :: boolean()
  defp already_assigned?(task, workflow, initial_step) do
    task.workflow_id == workflow.id and task.current_step_id == initial_step.id
  end
end
