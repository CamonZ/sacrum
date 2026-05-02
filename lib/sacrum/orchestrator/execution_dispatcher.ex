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
         {:ok, task} <- stamp_started_at_if_needed(task),
         {:ok, execution} <- create_started_execution(task, step, handoff),
         {:ok, task} <- Status.refresh(task) do
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

  defp stamp_started_at_if_needed(%{started_at: nil} = task) do
    Accounts.Tasks.update(task, %{started_at: DateTime.utc_now()})
  end

  defp stamp_started_at_if_needed(task), do: {:ok, task}

  defp create_started_execution(task, step, handoff) do
    attrs = %{
      task_id: task.id,
      workflow_id: task.workflow_id,
      step_id: step.id,
      step_name: step.name,
      status: "started"
    }

    attrs = if is_map(handoff), do: Map.put(attrs, :handoff, handoff), else: attrs

    %StepExecution{user_id: task.user_id, project_id: task.project_id}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
  end
end
