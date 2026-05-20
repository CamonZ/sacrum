defmodule Sacrum.SessionLogRollups do
  @moduledoc """
  Rolls provider session-log token usage into the owning StepExecution row.
  """

  import Ecto.Query

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

  @spec recompute_step_execution(SessionLog.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def recompute_step_execution(%SessionLog{step_execution_id: step_execution_id} = log)
      when is_binary(step_execution_id) do
    case lock_step_execution(step_execution_id) do
      nil ->
        {:error, :not_found}

      execution ->
        recompute_log(execution, log)
    end
  end

  defp lock_step_execution(step_execution_id) do
    StepExecution
    |> where([execution], execution.id == ^step_execution_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp rollup_log(%StepExecution{} = execution, %SessionLog{} = log) do
    case usage_from_log(log) do
      nil ->
        {:ok, execution}

      usage ->
        execution
        |> StepExecution.update_changeset(incremental_rollup_attrs(execution, usage))
        |> Repo.update()
    end
  end

  defp recompute_log(%StepExecution{} = execution, %SessionLog{} = log) do
    execution
    |> StepExecution.update_changeset(
      rollup_attrs(usage_from_logs(execution.id), usage_from_log(log))
    )
    |> Repo.update()
  end

  defp usage_from_logs(step_execution_id) do
    SessionLog
    |> where([log], log.step_execution_id == ^step_execution_id)
    |> order_by([log], asc: log.inserted_at, asc: log.id)
    |> Repo.all()
    |> Enum.reduce(nil, fn log, acc ->
      case usage_from_log(log) do
        nil -> acc
        usage -> sum_usage(acc, usage)
      end
    end)
  end

  defp sum_usage(nil, usage), do: usage

  defp sum_usage(acc, usage) do
    %{
      input_tokens: acc.input_tokens + usage.input_tokens,
      cache_read_input_tokens: acc.cache_read_input_tokens + usage.cache_read_input_tokens,
      output_tokens: acc.output_tokens + usage.output_tokens,
      total_tokens: acc.total_tokens + usage.total_tokens
    }
  end

  defp incremental_rollup_attrs(%StepExecution{} = execution, usage) do
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

  defp rollup_attrs(usage, context_usage) do
    usage = usage || zero_usage()
    context_usage = context_usage || zero_usage()

    %{
      session_input_tokens: usage.input_tokens,
      session_cache_read_input_tokens: usage.cache_read_input_tokens,
      session_output_tokens: usage.output_tokens,
      session_total_tokens: usage.total_tokens,
      context_window_input_tokens: context_usage.input_tokens,
      context_window_cache_read_input_tokens: context_usage.cache_read_input_tokens,
      context_window_total_tokens: context_usage.total_tokens
    }
  end

  defp zero_usage do
    %{input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp usage_from_log(%SessionLog{content: content, format: format}) do
    with {:ok, decoded} <- Jason.decode(content),
         %{} = usage <- find_usage(decoded) do
      usage_from_payload(format, usage)
    else
      _ -> nil
    end
  end

  defp usage_from_payload(format, usage) when format == "anthropic" do
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

  defp usage_from_payload(format, usage) when format == "openai" do
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

  defp usage_from_payload(_format, _usage), do: nil

  defp find_usage(%{"usage" => %{} = usage}), do: usage
  defp find_usage(%{"response" => %{} = response}), do: find_usage(response)
  defp find_usage(%{"message" => %{} = message}), do: find_usage(message)
  defp find_usage(%{"result" => %{} = result}), do: find_usage(result)
  defp find_usage(_), do: nil

  defp openai_cache_read_tokens(usage) do
    cond do
      is_integer(usage["cache_read_input_tokens"]) ->
        usage["cache_read_input_tokens"]

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
