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
  alias Sacrum.Orchestrator.{PromptRenderer, StructuredOutput}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.WorkflowStep

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

      execution_data = build_execution_data(task.id, execution)
      context = PromptRenderer.build_context(task, execution_data, step)
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

  defp build_execution_data(task_id, entered_execution) do
    %{}
    |> put_previous_output(task_id)
    |> put_handoff(entered_execution.handoff)
  end

  defp put_previous_output(data, task_id) do
    query =
      from(e in StepExecution,
        left_join: ws in WorkflowStep,
        on: ws.workflow_id == e.workflow_id and ws.name == e.step_name,
        where: e.task_id == ^task_id and e.status == "completed",
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: {e.output, ws.output_schema}
      )

    case Repo.one(query) do
      nil ->
        data

      {output, schema} ->
        Map.put(data, :previous, %{output: decode_prior_output(output, schema)})
    end
  end

  defp decode_prior_output(output, schema) when is_binary(output) and is_map(schema) do
    case StructuredOutput.decode(output) do
      {:ok, decoded} ->
        decoded

      {:error, reason} ->
        Logger.error(
          "[ExecutionDispatcher] Failed to decode prior output as JSON: #{inspect(reason)}. Returning raw string."
        )

        output
    end
  end

  defp decode_prior_output(output, _schema), do: output

  defp put_handoff(data, handoff) when is_map(handoff), do: Map.put(data, :handoff, handoff)
  defp put_handoff(data, _), do: data

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
end
