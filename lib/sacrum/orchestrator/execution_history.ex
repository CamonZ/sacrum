defmodule Sacrum.Orchestrator.ExecutionHistory do
  @moduledoc """
  Builds execution history and context data for prompt rendering.

  Collects previous execution output, handoff data, and run counts for a step.
  """

  import Ecto.Query

  alias Sacrum.Orchestrator.StructuredOutput
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  require Logger

  @doc """
  Builds execution data for a step execution.

  Returns a map with `:previous`, `:handoff`, `:run_count`, `:completed_count`,
  `:failed_count` keys suitable for `PromptContext.build_context/3`.
  """
  @spec build_execution_data(String.t(), struct()) :: map()
  def build_execution_data(task_id, dispatched_execution) do
    %{}
    |> put_previous_output(task_id)
    |> put_handoff(dispatched_execution.handoff)
    |> put_run_counts(task_id, dispatched_execution.step_id)
  end

  @doc """
  Queries the most recent completed StepExecution and stores its (decoded)
  output under the `:previous` key.
  """
  @spec put_previous_output(map(), String.t()) :: map()
  def put_previous_output(data, task_id) do
    query =
      from(e in StepExecution,
        left_join: ws in WorkflowStep,
        on: ws.id == e.step_id or (is_nil(e.step_id) and ws.name == e.step_name),
        where: e.task_id == ^task_id and e.status == "completed",
        order_by: [desc: e.inserted_at],
        limit: 1,
        select: {e.output, ws.output_schema}
      )

    case Repo.one(query) do
      nil -> data
      {output, schema} -> Map.put(data, :previous, %{output: decode_prior_output(output, schema)})
    end
  end

  @doc """
  Decodes prior execution output as JSON when an output schema is present.
  Falls back to the raw string on decode failure.
  """
  @spec decode_prior_output(String.t() | nil, map() | nil) :: term()
  def decode_prior_output(output, schema) when is_binary(output) and is_map(schema) do
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

  def decode_prior_output(output, _schema), do: output

  @doc """
  Stores handoff data under the `:handoff` key when it is a map.
  """
  @spec put_handoff(map(), map() | nil) :: map()
  def put_handoff(data, handoff) when is_map(handoff), do: Map.put(data, :handoff, handoff)
  def put_handoff(data, _), do: data

  @doc """
  Adds `:completed_count`, `:failed_count`, and `:run_count` (their sum) for
  the step's terminal executions.
  """
  @spec put_run_counts(map(), String.t(), String.t()) :: map()
  def put_run_counts(data, task_id, step_id) do
    step_name =
      Repo.one(from(ws in WorkflowStep, where: ws.id == ^step_id, select: ws.name, limit: 1))

    query = run_counts_query(task_id, step_id, step_name)

    counts = query |> Repo.all() |> Map.new()
    completed = Map.get(counts, "completed", 0)
    failed = Map.get(counts, "failed", 0)

    data
    |> Map.put(:completed_count, completed)
    |> Map.put(:failed_count, failed)
    |> Map.put(:run_count, completed + failed)
  end

  defp run_counts_query(task_id, step_id, nil) do
    from(e in StepExecution,
      where:
        e.task_id == ^task_id and e.step_id == ^step_id and
          e.status in ["completed", "failed", "cancelled"],
      group_by: e.status,
      select: {e.status, count(e.id)}
    )
  end

  defp run_counts_query(task_id, step_id, step_name) do
    from(e in StepExecution,
      where:
        e.task_id == ^task_id and
          (e.step_id == ^step_id or (is_nil(e.step_id) and e.step_name == ^step_name)) and
          e.status in ["completed", "failed", "cancelled"],
      group_by: e.status,
      select: {e.status, count(e.id)}
    )
  end
end
