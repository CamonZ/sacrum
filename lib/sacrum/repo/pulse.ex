defmodule Sacrum.Repo.Pulse do
  @moduledoc """
  Compute metrics for the Pulse top strip of the Command Center.

  Four 24-hour rolling metrics:
  - Concurrency vs cap (live engine slots in use vs cap, global)
  - Spend (USD and token count in past 24h, scope-aware)
  - Throughput (tasks completed in past 24h, scope-aware)
  - P50 time-to-terminal-step (median duration to reach final step, scope-aware)
  """

  import Ecto.Query

  alias Sacrum.Orchestrator.ExecutionPool
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, WorkflowStep}

  @window_seconds 86_400

  @spec get_all_metrics(binary() | nil) :: map()
  def get_all_metrics(project_id \\ nil) do
    {concurrency, cap} = get_concurrency_and_cap()

    %{
      concurrency: concurrency,
      cap: cap,
      spend_usd: get_spend_usd(project_id),
      spend_tokens: get_spend_tokens(project_id),
      throughput: get_throughput(project_id),
      p50_duration_ms: get_p50_duration_ms(project_id)
    }
  end

  @doc """
  Live engine slots in use and the configured cap.

  Reads from the in-memory `ExecutionPool` — the same source of truth the engine
  uses to enforce the cap. Always global; the cap is global today (see ticket
  e86899dc for lifting it).
  """
  @spec get_concurrency_and_cap() :: {non_neg_integer(), pos_integer()}
  def get_concurrency_and_cap do
    %{in_use_count: in_use, max_concurrent: cap} = ExecutionPool.pool_status()
    {in_use, cap}
  end

  @spec get_spend_usd(binary() | nil) :: Decimal.t()
  def get_spend_usd(project_id) do
    query =
      from se in StepExecution,
        where: se.inserted_at >= ^cutoff() and not is_nil(se.cost),
        select: coalesce(sum(se.cost), 0)

    Repo.one(scope(query, project_id)) || Decimal.new(0)
  end

  @spec get_spend_tokens(binary() | nil) :: non_neg_integer()
  def get_spend_tokens(project_id) do
    query =
      from se in StepExecution,
        where: se.inserted_at >= ^cutoff(),
        select: coalesce(sum(se.input_tokens), 0) + coalesce(sum(se.output_tokens), 0)

    Repo.one(scope(query, project_id)) || 0
  end

  @spec get_throughput(binary() | nil) :: non_neg_integer()
  def get_throughput(project_id) do
    query =
      from se in StepExecution,
        join: ws in WorkflowStep,
        on: se.step_id == ws.id,
        where:
          se.inserted_at >= ^cutoff() and se.status == "completed" and
            ws.is_final == true,
        select: count(se.task_id, :distinct)

    Repo.one(scope(query, project_id)) || 0
  end

  @doc """
  Median time from a task's first step_execution to its final completed step_execution,
  in milliseconds, over the past 24h.
  """
  @spec get_p50_duration_ms(binary() | nil) :: integer()
  def get_p50_duration_ms(project_id) do
    cutoff = cutoff()

    final_query =
      from se in StepExecution,
        join: ws in WorkflowStep,
        on: se.step_id == ws.id,
        where:
          se.inserted_at >= ^cutoff and se.status == "completed" and
            ws.is_final == true,
        select: se.task_id,
        distinct: true

    task_ids = Repo.all(scope(final_query, project_id))

    durations =
      task_ids
      |> Enum.map(&task_duration_ms(&1, cutoff, project_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    case durations do
      [] -> 0
      list -> percentile(list, 0.5)
    end
  end

  defp task_duration_ms(task_id, cutoff, project_id) do
    first_query =
      from se in StepExecution,
        where: se.task_id == ^task_id and se.inserted_at >= ^cutoff,
        order_by: [asc: se.inserted_at],
        limit: 1,
        select: se.inserted_at

    last_query =
      from se in StepExecution,
        join: ws in WorkflowStep,
        on: se.step_id == ws.id,
        where:
          se.task_id == ^task_id and se.inserted_at >= ^cutoff and
            se.status == "completed" and ws.is_final == true,
        order_by: [desc: se.inserted_at],
        limit: 1,
        select: se.inserted_at

    with %DateTime{} = first <- Repo.one(scope(first_query, project_id)),
         %DateTime{} = last <- Repo.one(scope(last_query, project_id)) do
      DateTime.diff(last, first, :millisecond)
    else
      _ -> nil
    end
  end

  defp scope(query, nil), do: query
  defp scope(query, project_id), do: from(se in query, where: se.project_id == ^project_id)

  defp cutoff, do: DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

  defp percentile(list, percentile) when is_list(list) and percentile >= 0 and percentile <= 1 do
    count = length(list)
    rank = percentile * (count - 1)
    lower = floor(rank)
    upper = ceil(rank)

    if lower == upper do
      Enum.at(list, lower)
    else
      lower_val = Enum.at(list, lower)
      upper_val = Enum.at(list, upper)
      frac = rank - lower
      trunc(lower_val + frac * (upper_val - lower_val))
    end
  end
end
