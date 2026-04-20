defmodule Sacrum.Orchestrator.ExecutionDispatcher do
  @moduledoc """
  Dispatches step executions to the daemon.

  Finds the existing "entered" StepExecution for the current step,
  renders the prompt using PromptRenderer with Liquid/Solid templates,
  and broadcasts a run_step event to the daemon.

  Used by both the GraphQL runStep resolver and the TaskOrchestrator to
  ensure consistent execution dispatch behavior.
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionHistory, PromptContext, PromptRenderer}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  @doc """
  Dispatches a step execution to the daemon.

  Fetches the step, finds the existing "entered" StepExecution scoped to
  the current step and workflow, renders the prompt using PromptRenderer
  with Liquid template syntax, broadcasts the run_step event, and returns
  the execution.

  Returns:
    - {:ok, execution} on success
    - {:error, :no_entered_execution} if no "entered" execution exists
    - {:error, reason} on other failures
  """
  @spec create_and_dispatch(String.t(), struct(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(user_id, task, step_id) do
    with {:ok, step} <- fetch_step(user_id, step_id),
         {:ok, execution} <- find_entered_execution(task, step_id, task.workflow_id) do
      execution_data = ExecutionHistory.build_execution_data(task.id, execution)
      context = PromptContext.build_context(task, execution_data, step)
      {:ok, rendered} = PromptRenderer.render(step.prompt, context)

      Logger.info(
        "[ExecutionDispatcher] Dispatching execution=#{execution.id} step=#{step.name} " <>
          "task=#{task.id} prompt_length=#{String.length(rendered)}"
      )

      Broadcaster.broadcast_run_step(
        %{execution: execution, step: step, task: task, rendered_prompt: rendered},
        task.project_id
      )

      {:ok, execution}
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

  defp find_entered_execution(_task, _step_id, nil), do: {:error, :no_workflow}

  defp find_entered_execution(task, step_id, workflow_id) do
    query =
      from(e in StepExecution,
        where:
          e.task_id == ^task.id and
            e.step_id == ^step_id and
            e.workflow_id == ^workflow_id and
            e.status == "entered",
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_entered_execution}
      execution -> {:ok, execution}
    end
  end
end
