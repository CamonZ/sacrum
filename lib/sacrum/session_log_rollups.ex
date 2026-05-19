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
        |> StepExecution.update_changeset(rollup_attrs(execution, usage))
        |> Repo.update()
    end
  end

  defp rollup_attrs(%StepExecution{} = execution, usage) do
    %{
      session_input_tokens: token_count(execution.session_input_tokens) + usage.input_tokens,
      session_cache_read_input_tokens:
        token_count(execution.session_cache_read_input_tokens) + usage.cache_read_input_tokens,
      session_output_tokens: token_count(execution.session_output_tokens) + usage.output_tokens,
      session_total_tokens: token_count(execution.session_total_tokens) + usage.total_tokens,
      context_window_input_tokens: usage.context_window_input_tokens,
      context_window_cache_read_input_tokens: usage.context_window_cache_read_input_tokens,
      context_window_total_tokens: usage.context_window_total_tokens
    }
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
      total_tokens: total_input + output,
      context_window_input_tokens: total_input,
      context_window_cache_read_input_tokens: cache_read,
      context_window_total_tokens: total_input + output
    }
  end

  defp usage_from_payload(format, usage) when format == "openai" do
    input = integer(usage["input_tokens"] || usage["prompt_tokens"])
    cache_read = openai_cache_read_tokens(usage)
    output = integer(usage["output_tokens"] || usage["completion_tokens"])
    context_window_input = max(input - cache_read, 0)

    %{
      input_tokens: input,
      cache_read_input_tokens: cache_read,
      output_tokens: output,
      total_tokens: total_tokens(usage, input, output),
      context_window_input_tokens: context_window_input,
      context_window_cache_read_input_tokens: 0,
      context_window_total_tokens: context_window_input + output
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
      is_integer(usage["cached_input_tokens"]) ->
        usage["cached_input_tokens"]

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
