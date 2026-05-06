defmodule Sacrum.Orchestrator.Retry do
  @moduledoc """
  Handles step execution retries when the daemon reports a failure.

  Re-dispatches the current step up to `@max_retries` times, capped at `@max_retries`.
  The dispatcher creates the new StepExecution row each time.
  The FSM is expected to reset `run_retry_attempt` on a successful completion
  so failure bursts on different steps don't accumulate.
  """

  require Logger

  alias Sacrum.Orchestrator.{ExecutionDispatcher, FSMData, WorkflowGraph}
  alias Sacrum.Orchestrator.TaskRuns.RetryExhaustion

  @max_retries 5

  @spec max_retries() :: non_neg_integer()
  def max_retries, do: @max_retries

  @doc """
  Handles a daemon-reported execution failure. Re-dispatches up to
  `@max_retries` attempts, otherwise transitions to `:failed`.
  """
  @spec handle_execution_failure(String.t(), FSMData.t()) ::
          {:keep_state, FSMData.t()} | {:next_state, atom(), FSMData.t()}
  def handle_execution_failure(execution_id, data) do
    attempt = data.run_retry_attempt + 1

    Logger.error(
      "[TaskOrchestrator:#{data.task.id}] Execution #{execution_id} failed attempt=#{attempt}/#{@max_retries}"
    )

    if attempt < @max_retries,
      do: create_retry_execution_and_dispatch(data),
      else: exhaust_retries(execution_id, data, attempt)
  end

  @spec create_retry_execution_and_dispatch(FSMData.t()) ::
          {:keep_state, FSMData.t()} | {:next_state, :failed, FSMData.t()}
  defp create_retry_execution_and_dispatch(data) do
    task_id = data.task.id
    attempt = data.run_retry_attempt + 1

    with {:ok, current_step} <- WorkflowGraph.get_current_step(data),
         {:ok, execution} <-
           ExecutionDispatcher.create_and_dispatch(
             data.user_id,
             data.task,
             current_step.id,
             data.task_run_id
           ) do
      new_data = %{data | current_execution_id: execution.id, run_retry_attempt: attempt}

      Logger.info(
        "[TaskOrchestrator:#{task_id}] Retry execution #{execution.id} step=#{current_step.id} (#{current_step.name}) attempt=#{attempt}/#{@max_retries}"
      )

      {:keep_state, new_data}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to create retry execution: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  @spec exhaust_retries(binary(), FSMData.t(), pos_integer()) ::
          {:next_state, :failed, FSMData.t()}
  defp exhaust_retries(_execution_id, %{task_run_id: nil} = data, attempt) do
    {:next_state, :failed, %{data | run_retry_attempt: attempt}}
  end

  defp exhaust_retries(execution_id, %{task_run_id: task_run_id} = data, attempt) do
    case RetryExhaustion.mark(task_run_id, execution_id, %{
           task_id: data.task.id,
           current_step_id: data.task.current_step_id,
           current_attempt: attempt,
           max_attempts: @max_retries
         }) do
      {:ok, _task_run_or_unchanged} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{data.task.id}] Failed to mark TaskRun retry_exhausted: #{inspect(reason)}"
        )
    end

    {:next_state, :failed, %{data | run_retry_attempt: attempt}}
  end
end
