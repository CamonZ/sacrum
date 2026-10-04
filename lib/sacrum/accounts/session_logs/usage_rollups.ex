defmodule Sacrum.Accounts.SessionLogs.UsageRollups do
  @moduledoc """
  Rolls normalized harness session-log usage into StepExecution counters.

  Totals are folded one persisted log at a time, so the same state can be seeded
  from history and then advanced incrementally as new logs commit.
  """

  alias Sacrum.Accounts.SessionLogs.HarnessEventV1Usage
  alias Sacrum.Repo.Schemas.SessionLog

  @type usage :: %{
          input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type t :: %{total: usage(), contexts: %{String.t() => map()}}

  @spec new() :: t()
  def new, do: %{total: empty_usage(), contexts: %{}}

  @doc "Fold one persisted log into the rollup."
  @spec add(t(), SessionLog.t()) :: t()
  def add(rollup, %SessionLog{format: "harness"} = log) do
    case HarnessEventV1Usage.parse(log) do
      {:ok, event} ->
        rollup
        |> add_delta(harness_delta_usage(event.turn_delta))
        |> add_context(log, event, harness_context_usage(event.session_snapshot))

      :error ->
        rollup
    end
  end

  def add(rollup, %SessionLog{}), do: rollup

  @doc "StepExecution attributes for the rollup."
  @spec attrs(t()) :: map()
  def attrs(%{total: total, contexts: contexts}) do
    latest =
      contexts
      |> Map.values()
      |> Enum.max_by(& &1.insertion_order, fn -> %{usage: empty_usage()} end)

    refresh_attrs(total, latest.usage)
  end

  defp add_delta(rollup, nil), do: rollup
  defp add_delta(rollup, usage), do: %{rollup | total: merge_usage(rollup.total, usage)}

  defp add_context(rollup, _log, _event, nil), do: rollup

  defp add_context(rollup, log, event, usage) do
    candidate = %{
      sequence: event.sequence,
      insertion_order: {DateTime.to_unix(log.inserted_at, :microsecond), log.id},
      usage: usage
    }

    contexts =
      Map.update(rollup.contexts, event.stream_id, candidate, fn current ->
        later_stream_candidate(current, candidate)
      end)

    %{rollup | contexts: contexts}
  end

  defp later_stream_candidate(current, candidate) do
    if {candidate.sequence, candidate.insertion_order} >
         {current.sequence, current.insertion_order} do
      candidate
    else
      current
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
