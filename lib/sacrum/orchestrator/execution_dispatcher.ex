defmodule Sacrum.Orchestrator.ExecutionDispatcher do
  @moduledoc """
  Dispatches step executions to the daemon.

  Creates a StepExecution row in "started" status for the current step,
  renders the prompt using PromptRenderer with Liquid/Solid templates,
  and broadcasts a run_step event to the daemon.

  The dispatcher is the single source of StepExecution row creation for
  execute/evaluate/route steps. Transitions (advance_to_step, move_to_step)
  only update current_step_id; execution rows are created exclusively
  at dispatch time.

  Used by both the GraphQL runStep resolver and the TaskOrchestrator to
  ensure consistent execution dispatch behavior.
  """

  require Logger

  alias Ecto.Multi
  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionHistory, PromptContext, PromptRenderer}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Tasks.Status

  @doc """
  Creates a "started" StepExecution for the current step and broadcasts run_step
  to the daemon. The dispatcher is the single source of execution row creation
  for execute/route/evaluate steps.

  `handoff` is attached to the new row when present (typically supplied by the
  orchestrator from FSMData after a route step).
  """
  @spec create_and_dispatch(String.t(), struct(), String.t(), map() | nil) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(user_id, task, step_id, handoff \\ nil) do
    with {:ok, step} <- fetch_step(user_id, step_id),
         :ok <- validate_workflow(task),
         {:ok, %{execution: execution, task: task}} <- insert_and_stamp(task, step, handoff) do
      execution_data = ExecutionHistory.build_execution_data(task.id, execution)
      context = PromptContext.build_context(task, execution_data, step)

      with {:ok, rendered} <- PromptRenderer.render(step.prompt, context),
           {:ok, updated_execution} <-
             Accounts.StepExecutions.update(execution, %{prompt: rendered}) do
        Logger.info(
          "[ExecutionDispatcher] Dispatching execution=#{updated_execution.id} step=#{step.name} " <>
            "task=#{task.id} prompt_length=#{String.length(rendered)}"
        )

        Broadcaster.broadcast_run_step(
          %{execution: updated_execution, step: step, task: task, rendered_prompt: rendered},
          task.project_id
        )

        Broadcaster.broadcast_step_execution({:ok, updated_execution}, :step_execution_created)

        {:ok, updated_execution}
      end
    else
      {:error, _op, reason, _changes} ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} = err ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        err
    end
  end

  defp fetch_step(user_id, step_id) do
    Accounts.WorkflowSteps.get_by(user_id,
      conditions: [id: step_id],
      preloads: [:workflow]
    )
  end

  defp validate_workflow(%{workflow_id: nil}), do: {:error, :no_workflow}
  defp validate_workflow(_task), do: :ok

  # Inserts the started StepExecution and updates the task (started_at +
  # derived status) in a single transaction. The task changeset is built
  # *after* the execution insert so that derive/1 sees the new execution and
  # produces :running.
  defp insert_and_stamp(task, step, handoff) do
    Multi.new()
    |> Multi.insert(:execution, started_execution_changeset(task, step, handoff))
    |> Multi.update(:task, fn _changes -> task_dispatch_changeset(task) end)
    |> Repo.transaction()
  end

  defp started_execution_changeset(task, step, handoff) do
    attrs = %{
      task_id: task.id,
      workflow_id: task.workflow_id,
      step_id: step.id,
      step_name: step.name,
      status: "started"
    }

    attrs = if is_map(handoff), do: Map.put(attrs, :handoff, handoff), else: attrs

    StepExecution.create_changeset(
      %StepExecution{user_id: task.user_id, project_id: task.project_id},
      attrs
    )
  end

  defp task_dispatch_changeset(task) do
    changes = if is_nil(task.started_at), do: %{started_at: DateTime.utc_now()}, else: %{}

    task
    |> Ecto.Changeset.change(changes)
    |> Status.put_status()
  end
end
