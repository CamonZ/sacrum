defmodule Sacrum.Orchestrator.Routing.IntraWorkflow do
  @moduledoc """
  Route step destination within the same workflow.

  Validates the target step and transition, then advances the task. The
  continuation reuses the FSM's existing workflow/steps cache since the
  workflow hasn't changed.
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{FSMData, TaskCompletion}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepTransition, WorkflowStep}
  alias Sacrum.Repo.TaskWorkflows

  @doc """
  Routes to a destination step within the same workflow.
  """
  @spec handle_intra_workflow_routing(FSMData.t(), String.t(), map() | nil) ::
          {:ok, struct()} | {:error, term()}
  def handle_intra_workflow_routing(data, dest_step_id, handoff) do
    task_id = data.task.id

    with {:ok, _dest_step} <- validate_destination_step(data, dest_step_id),
         :ok <- validate_step_transition_exists(data.task.current_step_id, dest_step_id),
         {:ok, updated_task} <-
           TaskWorkflows.advance_to_step(data.task, dest_step_id, handoff,
             skip_orchestrator_check: true
           ) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Route step routed intra_workflow from #{data.task.current_step_id} to #{dest_step_id} handoff=#{inspect(handoff != nil)}"
      )

      {:ok, updated_task}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Intra-workflow routing failed: #{inspect(reason)} " <>
            "from=#{data.task.current_step_id} to=#{dest_step_id}"
        )

        {:error, reason}
    end
  end

  @doc """
  Continuation after an intra-workflow route is applied — reuses the existing
  workflow/steps cache.
  """
  @spec handle_intra_route_continuation(FSMData.t(), struct()) ::
          {:next_state, atom(), FSMData.t()} | {:stop, atom(), FSMData.t()}
  def handle_intra_route_continuation(data, updated_task) do
    TaskCompletion.determine_next_state(
      updated_task.current_step_id,
      %{data | task: updated_task, slot_id: nil}
    )
  end

  @doc """
  Validates that the destination step exists and shares the caller's project/user.
  """
  @spec validate_destination_step(FSMData.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def validate_destination_step(data, step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil ->
        {:error, :destination_step_not_found}

      step ->
        if step.project_id == data.project_id and step.user_id == data.user_id,
          do: {:ok, step},
          else: {:error, :destination_step_cross_project_or_user}
    end
  end

  @doc """
  Validates that a transition exists from source step to destination step.
  """
  @spec validate_step_transition_exists(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_step_transition_exists(from_step_id, to_step_id) do
    query =
      from(t in StepTransition,
        where: t.from_step_id == ^from_step_id and t.to_step_id == ^to_step_id
      )

    if Repo.exists?(query), do: :ok, else: {:error, :no_step_transition}
  end
end
