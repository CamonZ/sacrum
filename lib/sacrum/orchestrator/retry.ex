defmodule Sacrum.Orchestrator.Retry do
  @moduledoc """
  Handles step execution retries when the daemon reports a failure.

  Inserts a fresh `"entered"` StepExecution for the current step (reusing any
  prior handoff) and re-dispatches it, capped at `@max_retries`. The FSM is
  expected to reset `run_retry_attempt` on a successful completion so failure
  bursts on different steps don't accumulate.
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{ExecutionDispatcher, FSMData, WorkflowGraph}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

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

    if attempt < @max_retries do
      create_retry_execution_and_dispatch(data)
    else
      {:next_state, :failed, data}
    end
  end

  @doc """
  Builds the `"entered"` StepExecution changeset shared by the retry path and
  cross-workflow assignment. Uses `task.workflow_id` when `workflow_id` is nil.
  """
  @spec entered_step_execution_changeset(struct(), struct(), String.t() | nil, keyword()) ::
          Ecto.Changeset.t()
  def entered_step_execution_changeset(task, step, workflow_id, opts) do
    StepExecution.create_changeset(
      %StepExecution{user_id: task.user_id, project_id: task.project_id},
      %{
        task_id: task.id,
        workflow_id: workflow_id || task.workflow_id,
        step_name: step.name,
        status: "entered",
        handoff: Keyword.get(opts, :handoff)
      }
    )
  end

  defp create_retry_execution_and_dispatch(data) do
    task_id = data.task.id
    attempt = data.run_retry_attempt + 1

    with {:ok, current_step} <- WorkflowGraph.get_current_step(data),
         handoff = prior_step_handoff(data.task.id, current_step.name),
         {:ok, _new_execution} <-
           Repo.insert(
             entered_step_execution_changeset(data.task, current_step, nil, handoff: handoff)
           ),
         {:ok, execution} <-
           ExecutionDispatcher.create_and_dispatch(data.user_id, data.task, current_step.id) do
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

  defp prior_step_handoff(task_id, step_name) do
    query =
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.step_name == ^step_name,
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: e.handoff
      )

    Repo.one(query)
  end
end
