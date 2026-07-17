defmodule Sacrum.SessionLogRollups do
  @moduledoc """
  Rolls provider and normalized harness session-log usage into StepExecution.
  """

  import Ecto.Query

  alias Sacrum.HarnessEventV1Usage
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  @spec rollup_step_execution(SessionLog.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def rollup_step_execution(%SessionLog{step_execution_id: step_execution_id} = log)
      when is_binary(step_execution_id) do
    case lock_step_execution(step_execution_id) do
      nil ->
        {:error, :not_found}

      execution ->
        rollup_log(execution, log)
    end
  end

  @spec refresh_step_execution(SessionLog.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def refresh_step_execution(%SessionLog{step_execution_id: step_execution_id} = log)
      when is_binary(step_execution_id) do
    case lock_step_execution(step_execution_id) do
      nil ->
        {:error, :not_found}

      execution ->
        refresh_log_rollups(execution, log)
    end
  end

  defp lock_step_execution(step_execution_id) do
    StepExecution
    |> where([execution], execution.id == ^step_execution_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp rollup_log(%StepExecution{} = execution, %SessionLog{} = log) do
    case provider_usage_from_log(log) do
      nil ->
        {:ok, execution}

      usage ->
        execution
        |> StepExecution.update_changeset(rollup_attrs(execution, usage))
        |> Repo.update()
    end
  end

  defp refresh_log_rollups(%StepExecution{} = execution, %SessionLog{format: "harness"} = log) do
    case HarnessEventV1Usage.parse(log) do
      {:ok, _event} -> refresh_from_logs(execution, log)
      :error -> normalize_unset_rollups(execution)
    end
  end

  defp refresh_log_rollups(%StepExecution{} = execution, %SessionLog{} = log) do
    refresh_from_logs(execution, log)
  end

  defp refresh_from_logs(execution, triggering_log) do
    parsed_logs = parsed_logs(execution.id)
    total_usage = aggregate_usage(parsed_logs)

    latest_context =
      if harness_rollups?(parsed_logs) do
        deterministic_context(parsed_logs)
      else
        provider_usage_from_log(triggering_log) || empty_usage()
      end

    execution
    |> StepExecution.update_changeset(refresh_attrs(total_usage, latest_context))
    |> Repo.update()
  end

  defp harness_rollups?(parsed_logs) do
    Enum.any?(parsed_logs, fn
      {_log, %{kind: :harness}} -> true
      {_log, _rollup} -> false
    end)
  end

  defp normalize_unset_rollups(execution) do
    attrs = %{
      session_input_tokens: token_count(execution.session_input_tokens),
      session_cache_read_input_tokens: token_count(execution.session_cache_read_input_tokens),
      session_output_tokens: token_count(execution.session_output_tokens),
      session_total_tokens: token_count(execution.session_total_tokens),
      context_window_input_tokens: token_count(execution.context_window_input_tokens),
      context_window_cache_read_input_tokens:
        token_count(execution.context_window_cache_read_input_tokens),
      context_window_total_tokens: token_count(execution.context_window_total_tokens)
    }

    execution
    |> StepExecution.update_changeset(attrs)
    |> Repo.update()
  end

  defp parsed_logs(step_execution_id) do
    SessionLog
    |> where([log], log.step_execution_id == ^step_execution_id)
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
    legacy_candidates =
      for {log, %{kind: :legacy, context: context}} <- parsed_logs,
          do: context_candidate(log, context)

    harness_candidates =
      parsed_logs
      |> Enum.reduce(%{}, fn
        {log, %{kind: :harness, context: context, stream_id: stream_id, sequence: sequence}},
        candidates
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

    case Enum.max_by(legacy_candidates ++ harness_candidates, & &1.insertion_order, fn -> nil end) do
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
          kind: :harness,
          stream_id: event.stream_id,
          sequence: event.sequence,
          delta: harness_delta_usage(event.turn_delta),
          context: harness_context_usage(event.session_snapshot)
        }

      :error ->
        nil
    end
  end

  defp rollup_from_log(%SessionLog{} = log) do
    case provider_usage_from_log(log) do
      nil -> nil
      usage -> %{kind: :legacy, delta: usage, context: usage}
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

  defp rollup_attrs(%StepExecution{} = execution, usage) do
    %{
      session_input_tokens: token_count(execution.session_input_tokens) + usage.input_tokens,
      session_cache_read_input_tokens:
        token_count(execution.session_cache_read_input_tokens) + usage.cache_read_input_tokens,
      session_output_tokens: token_count(execution.session_output_tokens) + usage.output_tokens,
      session_total_tokens: token_count(execution.session_total_tokens) + usage.total_tokens,
      context_window_input_tokens: usage.input_tokens,
      context_window_cache_read_input_tokens: usage.cache_read_input_tokens,
      context_window_total_tokens: usage.total_tokens
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

  defp provider_usage_from_log(%SessionLog{content: content, format: format})
       when format in ["anthropic", "openai"] do
    with {:ok, decoded} <- Jason.decode(content),
         %{} = usage <- find_usage(decoded) do
      usage_from_payload(format, usage)
    else
      _ -> nil
    end
  end

  defp provider_usage_from_log(%SessionLog{}), do: nil

  defp usage_from_payload("anthropic", usage) do
    input = integer(usage["input_tokens"])
    cache_create = integer(usage["cache_creation_input_tokens"])
    cache_read = integer(usage["cache_read_input_tokens"])
    output = integer(usage["output_tokens"])
    total_input = input + cache_create + cache_read

    %{
      input_tokens: total_input,
      cache_read_input_tokens: cache_read,
      output_tokens: output,
      total_tokens: total_input + output
    }
  end

  defp usage_from_payload("openai", usage) do
    input = integer(usage["input_tokens"] || usage["prompt_tokens"])
    cache_read = openai_cache_read_tokens(usage)
    output = integer(usage["output_tokens"] || usage["completion_tokens"])

    %{
      input_tokens: input,
      cache_read_input_tokens: cache_read,
      output_tokens: output,
      total_tokens: total_tokens(usage, input, output)
    }
  end

  defp find_usage(%{"usage" => %{} = usage}), do: usage
  defp find_usage(%{"response" => %{} = response}), do: find_usage(response)
  defp find_usage(%{"message" => %{} = message}), do: find_usage(message)
  defp find_usage(%{"result" => %{} = result}), do: find_usage(result)
  defp find_usage(_), do: nil

  defp openai_cache_read_tokens(usage) do
    cond do
      is_integer(usage["cache_read_input_tokens"]) ->
        usage["cache_read_input_tokens"]

      # Codex `exec --json` reports cache reads on the `turn.completed` usage as
      # `cached_input_tokens` — not under older completion
      # (`prompt_tokens_details`) or Responses (`input_token_details`) shapes.
      is_integer(usage["cached_input_tokens"]) ->
        usage["cached_input_tokens"]

      is_map(usage["input_token_details"]) ->
        integer(usage["input_token_details"]["cached_tokens"])

      is_map(usage["prompt_tokens_details"]) ->
        integer(usage["prompt_tokens_details"]["cached_tokens"])

      true ->
        0
    end
  end

  defp total_tokens(%{"total_tokens" => value}, _input, _output), do: integer(value)
  defp total_tokens(_usage, input, output), do: input + output

  defp integer(value) when is_integer(value), do: value

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0
    end
  end

  defp integer(_), do: 0
  defp token_count(value) when is_integer(value), do: value
  defp token_count(_), do: 0
end
