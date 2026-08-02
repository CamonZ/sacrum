defmodule Sacrum.Orchestrator.ExecutionHistory do
  @moduledoc """
  Builds execution history and context data for prompt rendering.

  Collects previous execution output, handoff data, and run counts for a step.
  """

  import Ecto.Query

  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Orchestrator.StructuredOutput
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  require Logger

  @doc """
  Builds execution data for a step execution in a validated TaskRun.

  History is collected from the current TaskRun only. The database query is
  ordered oldest-first with an id tie-breaker, then exposed nearest-first for
  prompt rendering. The execution currently being rendered is excluded when it
  already has a persisted id.
  """
  @spec build_execution_data(
          Sacrum.Repo.Schemas.Task.t(),
          struct(),
          Sacrum.Repo.Schemas.TaskRun.t()
        ) :: map()
  def build_execution_data(task, dispatched_execution, task_run) do
    history = list_prior_executions(task, dispatched_execution, task_run)

    %{}
    |> Map.put(:history, history)
    |> put_previous_output(task, task_run, dispatched_execution.id)
    |> put_handoff(dispatched_execution.handoff)
    |> put_run_counts(task, task_run, dispatched_execution.step_id)
  end

  @deprecated "Pass the task and validated TaskRun to build_execution_data/3"
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
  Adds the most recent completed output from the current TaskRun.
  """
  @spec put_previous_output(
          map(),
          Sacrum.Repo.Schemas.Task.t(),
          Sacrum.Repo.Schemas.TaskRun.t(),
          binary() | nil
        ) :: map()
  def put_previous_output(data, task, task_run, current_execution_id) do
    query =
      from(e in StepExecution,
        left_join: ws in WorkflowStep,
        on: ws.id == e.step_id or (is_nil(e.step_id) and ws.name == e.step_name),
        where:
          e.user_id == ^task.user_id and e.project_id == ^task.project_id and
            e.task_id == ^task.id and e.task_run_id == ^task_run.id and
            e.status == "completed",
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1,
        select: {e.output, ws.output_schema}
      )

    query = exclude_current_execution(query, current_execution_id)

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

  @doc """
  Adds terminal execution counts for a workflow step within one TaskRun.
  """
  @spec put_run_counts(
          map(),
          Sacrum.Repo.Schemas.Task.t(),
          Sacrum.Repo.Schemas.TaskRun.t(),
          String.t()
        ) :: map()
  def put_run_counts(data, task, task_run, step_id) do
    step_name =
      Repo.one(from(ws in WorkflowStep, where: ws.id == ^step_id, select: ws.name, limit: 1))

    query = run_counts_query(task, task_run, step_id, step_name)

    counts = query |> Repo.all() |> Map.new()
    completed = Map.get(counts, "completed", 0)
    failed = Map.get(counts, "failed", 0)

    data
    |> Map.put(:completed_count, completed)
    |> Map.put(:failed_count, failed)
    |> Map.put(:run_count, completed + failed)
  end

  defp list_prior_executions(task, dispatched_execution, task_run) do
    task.user_id
    |> TaskRuns.list_step_executions_for_run(task.project_id, task.id, task_run.id)
    |> Enum.take_while(fn execution -> execution.id != dispatched_execution.id end)
    |> Enum.reverse()
    |> Enum.map(&execution_to_history/1)
  end

  defp execution_to_history(%StepExecution{} = execution) do
    %{
      id: execution.id,
      step_id: execution.step_id,
      step_name: execution.step_name,
      status: execution.status,
      output: execution.output,
      duration_ms: execution.duration_ms,
      inserted_at: execution.inserted_at
    }
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

  defp run_counts_query(task, task_run, step_id, nil) do
    from(e in StepExecution,
      where:
        e.user_id == ^task.user_id and e.project_id == ^task.project_id and
          e.task_id == ^task.id and e.task_run_id == ^task_run.id and e.step_id == ^step_id and
          e.status in ["completed", "failed", "cancelled"],
      group_by: e.status,
      select: {e.status, count(e.id)}
    )
  end

  defp run_counts_query(task, task_run, step_id, step_name) do
    from(e in StepExecution,
      where:
        e.user_id == ^task.user_id and e.project_id == ^task.project_id and
          e.task_id == ^task.id and e.task_run_id == ^task_run.id and
          (e.step_id == ^step_id or (is_nil(e.step_id) and e.step_name == ^step_name)) and
          e.status in ["completed", "failed", "cancelled"],
      group_by: e.status,
      select: {e.status, count(e.id)}
    )
  end

  defp exclude_current_execution(query, nil), do: query

  defp exclude_current_execution(query, current_execution_id) do
    where(query, [e], e.id != ^current_execution_id)
  end
end
