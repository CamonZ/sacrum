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
  alias Sacrum.Orchestrator.PromptRenderer
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  @doc """
  Dispatches a step execution to the daemon.

  Fetches the step, finds the existing "entered" StepExecution, renders
  the prompt using PromptRenderer with Liquid template syntax, broadcasts
  the run_step event, and returns the execution.

  Returns:
    - {:ok, execution} on success
    - {:error, :no_entered_execution} if no "entered" execution exists
    - {:error, reason} on other failures
  """
  @spec create_and_dispatch(String.t(), struct(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch(user_id, task, step_id) do
    Logger.info(
      "[ExecutionDispatcher] create_and_dispatch user=#{user_id} task=#{task.id} step=#{step_id}"
    )

    with {:ok, step} <- fetch_step(user_id, step_id),
         {:ok, execution} <- find_entered_execution(task) do
      Logger.info(
        "[ExecutionDispatcher] Fetched step: #{step.name}, prompt=#{inspect(String.length(step.prompt || ""))} chars"
      )

      Logger.info(
        "[ExecutionDispatcher] Found entered execution: #{execution.id} status=#{execution.status}"
      )

      context = PromptRenderer.build_context(task, %{}, step)
      {:ok, rendered} = PromptRenderer.render(step.prompt, context)

      Logger.info(
        "[ExecutionDispatcher] Broadcasting run_step for execution=#{execution.id} project=#{task.project_id}"
      )

      broadcast_and_return(execution, step, task, rendered)
    else
      {:error, reason} = err ->
        Logger.error("[ExecutionDispatcher] create_and_dispatch failed: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Creates and dispatches an eval execution to determine which transition to take.

  Uses the step's eval_prompt instead of the normal prompt. The output from the
  previous execution is included in the context map under output.* keys instead of
  string replacement. The StepExecution is created with step_name "eval:{step_name}"
  to distinguish it from normal executions.

  Returns:
    - {:ok, execution} on success
    - {:error, reason} on failure
  """
  @spec create_and_dispatch_eval(String.t(), struct(), String.t(), String.t() | nil) ::
          {:ok, StepExecution.t()} | {:error, term()}
  def create_and_dispatch_eval(user_id, task, step_id, previous_output) do
    with {:ok, step} <- fetch_step(user_id, step_id),
         {:ok, execution} <- insert_eval_execution(user_id, task, step) do
      execution_data = %{previous: %{output: previous_output}}
      context = PromptRenderer.build_context(task, execution_data, step)
      {:ok, rendered} = PromptRenderer.render(step.eval_prompt, context)

      broadcast_and_return(execution, step, task, rendered)
    end
  end

  defp broadcast_and_return(execution, step, task, rendered_prompt) do
    payload = %{execution: execution, step: step, task: task, rendered_prompt: rendered_prompt}

    Logger.info(
      "[ExecutionDispatcher] broadcast_run_step payload: " <>
        "execution_id=#{execution.id} step=#{step.name} task=#{task.id} " <>
        "worktree=#{inspect(task.worktree)} prompt_length=#{String.length(rendered_prompt)}"
    )

    Broadcaster.broadcast_run_step(payload, task.project_id)

    {:ok, execution}
  end

  defp fetch_step(user_id, step_id) do
    Accounts.WorkflowSteps.get_by(user_id,
      conditions: [id: step_id],
      preloads: [:workflow]
    )
  end

  defp find_entered_execution(task) do
    query =
      from(e in StepExecution,
        where: e.task_id == ^task.id and e.status == "entered",
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_entered_execution}
      execution -> {:ok, execution}
    end
  end

  defp insert_eval_execution(user_id, task, step) do
    attrs = %{
      task_id: task.id,
      workflow_id: step.workflow_id,
      step_name: "eval:#{step.name}",
      status: "pending",
      project_id: task.project_id
    }

    Accounts.StepExecutions.insert(user_id, attrs)
  end
end
