defmodule Sacrum.Accounts.SessionLogs.UsageRollups do
  @moduledoc """
  Rolls normalized harness session-log usage into StepExecution.
  """

  import Ecto.Query

  alias Sacrum.Accounts.SessionLogs.HarnessEventV1Usage
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  @doc "Refresh usage while the caller holds the execution row lock."
  @spec refresh_step_execution(StepExecution.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()}
  def refresh_step_execution(%StepExecution{} = execution) do
    parsed_logs = parsed_logs(execution.id)

    execution
    |> StepExecution.update_changeset(
      refresh_attrs(aggregate_usage(parsed_logs), deterministic_context(parsed_logs))
    )
    |> Repo.update()
  end

  defp parsed_logs(step_execution_id) do
    SessionLog
    |> where([log], log.step_execution_id == ^step_execution_id and log.format == "harness")
    |> Repo.all()
    |> Enum.map(&{&1, rollup_from_log(&1)})
  end

  defp aggregate_usage(parsed_logs) do
    Enum.reduce(parsed_logs, empty_usage(), fn
      {_log, %{delta: usage}}, acc when not is_nil(usage) -> merge_usage(acc, usage)
      {_log, _rollup}, acc -> acc
    end)
  end

  defp deterministic_context(parsed_logs) do
    harness_candidates =
      parsed_logs
      |> Enum.reduce(%{}, fn
        {log, %{context: context, stream_id: stream_id, sequence: sequence}}, candidates
        when not is_nil(context) ->
          candidate =
            log
            |> context_candidate(context)
            |> Map.put(:sequence, sequence)

          Map.update(candidates, stream_id, candidate, fn current ->
            later_stream_candidate(current, candidate)
          end)

        {_log, _rollup}, candidates ->
          candidates
      end)
      |> Map.values()

    case Enum.max_by(harness_candidates, & &1.insertion_order, fn -> nil end) do
      nil -> empty_usage()
      candidate -> candidate.usage
    end
  end

  defp context_candidate(log, usage) do
    %{
      insertion_order: {DateTime.to_unix(log.inserted_at, :microsecond), log.id},
      usage: usage
    }
  end

  defp later_stream_candidate(current, candidate) do
    if {candidate.sequence, candidate.insertion_order} >
         {current.sequence, current.insertion_order} do
      candidate
    else
      current
    end
  end

  defp rollup_from_log(%SessionLog{format: "harness"} = log) do
    case HarnessEventV1Usage.parse(log) do
      {:ok, event} ->
        %{
          stream_id: event.stream_id,
          sequence: event.sequence,
          delta: harness_delta_usage(event.turn_delta),
          context: harness_context_usage(event.session_snapshot)
        }

      :error ->
        nil
    end
  end

  defp harness_delta_usage(nil), do: nil

  defp harness_delta_usage(%{tokens: tokens}) do
    %{
      input_tokens: tokens.input_tokens,
      cache_read_input_tokens: tokens.cached_input_tokens,
      output_tokens: tokens.output_tokens,
      total_tokens: tokens.input_tokens + tokens.output_tokens
    }
  end

  defp harness_context_usage(nil), do: nil

  defp harness_context_usage(%{tokens: tokens, context_tokens: context_tokens}) do
    %{
      input_tokens: tokens.input_tokens,
      cache_read_input_tokens: tokens.cached_input_tokens,
      output_tokens: tokens.output_tokens,
      total_tokens: context_tokens || tokens.input_tokens + tokens.output_tokens
    }
  end

  defp refresh_attrs(total_usage, latest_usage) do
    %{
      session_input_tokens: total_usage.input_tokens,
      session_cache_read_input_tokens: total_usage.cache_read_input_tokens,
      session_output_tokens: total_usage.output_tokens,
      session_total_tokens: total_usage.total_tokens,
      context_window_input_tokens: latest_usage.input_tokens,
      context_window_cache_read_input_tokens: latest_usage.cache_read_input_tokens,
      context_window_total_tokens: latest_usage.total_tokens
    }
  end

  defp empty_usage do
    %{
      input_tokens: 0,
      cache_read_input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0
    }
  end

  defp merge_usage(acc, usage) do
    %{
      input_tokens: acc.input_tokens + usage.input_tokens,
      cache_read_input_tokens: acc.cache_read_input_tokens + usage.cache_read_input_tokens,
      output_tokens: acc.output_tokens + usage.output_tokens,
      total_tokens: acc.total_tokens + usage.total_tokens
    }
  end
end
