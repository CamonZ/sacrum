defmodule Sacrum.Orchestrator.Routing.InterWorkflow do
  @moduledoc """
  Route step destination in a different workflow.

  Validates the destination workflow and transition, resolves the target step
  (explicit, initial, or first by order), and atomically updates the task and
  inserts an `"entered"` StepExecution in the new workflow. The continuation
  reloads the FSM's workflow/step cache since the workflow has changed.
  """

  require Logger

  import Ecto.Query

  alias Ecto.{Changeset, Multi}
  alias Sacrum.Orchestrator.{FSMData, Retry, TaskCompletion, WorkflowGraph}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{StepExecution, Workflow, WorkflowStep, WorkflowTransition}

  @doc """
  Routes to a destination workflow.
  """
  @spec handle_inter_workflow_routing(FSMData.t(), String.t(), map() | nil) ::
          {:ok, struct()} | {:error, term()}
  def handle_inter_workflow_routing(data, dest_workflow_id, handoff) do
    task_id = data.task.id

    with {:ok, dest_workflow} <- validate_destination_workflow(data, dest_workflow_id),
         :ok <- validate_workflow_transition_exists(data.task.workflow_id, dest_workflow_id),
         target_step_id <- get_target_step_for_workflow_transition(data, dest_workflow_id),
         {:ok, updated_task} <-
           assign_destination_workflow(data.task, dest_workflow, target_step_id, handoff) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Route step routed inter_workflow to workflow #{dest_workflow_id}"
      )

      {:ok, updated_task}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Inter-workflow routing failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Continuation after an inter-workflow route is applied — reloads the workflow
  graph since we've moved to a different workflow.
  """
  @spec handle_inter_route_continuation(FSMData.t(), String.t(), struct()) ::
          {:next_state, atom(), FSMData.t()} | {:stop, atom(), FSMData.t()}
  def handle_inter_route_continuation(data, task_id, updated_task) do
    case WorkflowGraph.load_workflow_and_graph(data.user_id, updated_task) do
      {:ok, workflow, steps, transitions} ->
        TaskCompletion.determine_next_state(updated_task.current_step_id, %{
          data
          | task: updated_task,
            workflow: workflow,
            steps: steps,
            transitions: transitions,
            slot_id: nil
        })

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to reload workflow after inter-workflow routing: #{inspect(reason)}"
        )

        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  @doc """
  Validates that the destination workflow exists and shares the caller's project/user.
  """
  @spec validate_destination_workflow(FSMData.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def validate_destination_workflow(data, workflow_id) do
    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :destination_workflow_not_found}

      workflow ->
        if workflow.project_id == data.project_id and workflow.user_id == data.user_id,
          do: {:ok, workflow},
          else: {:error, :destination_workflow_cross_project_or_user}
    end
  end

  @doc """
  Validates that a workflow transition exists from source to destination.
  """
  @spec validate_workflow_transition_exists(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_workflow_transition_exists(from_workflow_id, to_workflow_id) do
    query =
      from(t in WorkflowTransition,
        where: t.from_workflow_id == ^from_workflow_id and t.to_workflow_id == ^to_workflow_id
      )

    if Repo.exists?(query), do: :ok, else: {:error, :no_workflow_transition}
  end

  @doc """
  Returns the `target_step_id` set on the WorkflowTransition, or `nil` if unset.
  """
  @spec get_target_step_for_workflow_transition(FSMData.t(), String.t()) :: String.t() | nil
  def get_target_step_for_workflow_transition(data, to_workflow_id) do
    Repo.one(
      from(t in WorkflowTransition,
        where:
          t.from_workflow_id == ^data.task.workflow_id and
            t.to_workflow_id == ^to_workflow_id,
        select: t.target_step_id
      )
    )
  end

  @doc """
  Resolves the target step, then atomically updates the task and inserts the
  entered execution in the destination workflow.
  """
  @spec assign_destination_workflow(struct(), struct(), String.t() | nil, map() | nil) ::
          {:ok, struct()} | {:error, term()}
  def assign_destination_workflow(task, dest_workflow, target_step_id, handoff) do
    dest_workflow = Repo.preload(dest_workflow, :workflow_steps)

    with {:ok, target_step} <- resolve_target_step(dest_workflow, target_step_id) do
      do_assign_destination_workflow(task, dest_workflow, target_step, handoff)
    end
  end

  @doc """
  Resolves the target step: explicit id if given, otherwise the workflow's
  `initial_step_id` when set, otherwise the first step by `step_order`.
  """
  @spec resolve_target_step(struct(), String.t() | nil) :: {:ok, struct()} | {:error, term()}
  def resolve_target_step(_workflow, step_id) when not is_nil(step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :target_step_not_found}
      step -> {:ok, step}
    end
  end

  def resolve_target_step(%{initial_step_id: nil, workflow_steps: steps}, nil) do
    case Enum.sort_by(steps, & &1.step_order) do
      [first | _] -> {:ok, first}
      [] -> {:error, :destination_workflow_has_no_steps}
    end
  end

  def resolve_target_step(%{initial_step_id: step_id}, nil) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :initial_step_not_found}
      step -> {:ok, step}
    end
  end

  @doc """
  Runs the transaction that updates the task's workflow/current_step and
  inserts the `"entered"` StepExecution. Invalidates any prior "entered" row
  for the target step in the destination workflow.
  """
  @spec do_assign_destination_workflow(struct(), struct(), struct(), map() | nil) ::
          {:ok, struct()} | {:error, term()}
  def do_assign_destination_workflow(task, dest_workflow, target_step, handoff) do
    multi =
      Multi.new()
      |> Multi.update_all(
        :invalidate,
        from(e in StepExecution,
          where:
            e.task_id == ^task.id and
              e.step_id == ^target_step.id and
              e.workflow_id == ^dest_workflow.id and
              e.status == "entered"
        ),
        set: [status: "invalidated"]
      )
      # Invalidated is correct here: inter-workflow routing is a genuine supersession,
      # not a natural progression from a satisfied wait condition.
      |> Multi.update(
        :task,
        Changeset.change(task, %{
          workflow_id: dest_workflow.id,
          current_step_id: target_step.id
        })
      )
      |> Multi.insert(
        :step_execution,
        Retry.entered_step_execution_changeset(task, target_step, dest_workflow.id,
          handoff: handoff
        )
      )

    case Repo.transaction(multi) do
      {:ok, %{task: updated_task, step_execution: execution}} ->
        Logger.info(
          "[TaskOrchestrator:#{task.id}] Assigned destination workflow=#{dest_workflow.id} " <>
            "target_step=#{target_step.id} (#{target_step.name}) execution=#{execution.id} " <>
            "handoff=#{inspect(handoff != nil)}"
        )

        Broadcaster.broadcast({:ok, updated_task}, :task_updated, :project)
        Broadcaster.broadcast_step_execution({:ok, execution}, :step_execution_created)

        {:ok, updated_task}

      {:error, op, changeset, _changes} ->
        Logger.error(
          "[TaskOrchestrator:#{task.id}] Assign destination workflow failed op=#{inspect(op)} " <>
            "dest_workflow=#{dest_workflow.id} errors=#{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end
end
