defmodule Sacrum.HarnessEventV1Usage do
  @moduledoc """
  Strictly parses usage from the provider-neutral HarnessEventV1 envelope.

  Only the top-level V1 `usage` payload is considered. Provider payload shapes
  and usage nested in terminal outcome events are intentionally ignored.
  """

  alias Sacrum.Repo.Schemas.SessionLog

  @max_u64 18_446_744_073_709_551_615
  @correlation_keys ~w(session_id thread_id turn_id run_id item_id tool_call_id parent_tool_call_id provider_resume_id)

  @enforce_keys [:event_id, :stream_id, :sequence]
  defstruct [:event_id, :stream_id, :sequence, :turn_delta, :session_snapshot]

  @type token_usage :: %{
          input_tokens: non_neg_integer(),
          cached_input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          reasoning_tokens: non_neg_integer()
        }

  @type usage :: %{
          required(:tokens) => token_usage(),
          required(:cost_microusd) => non_neg_integer(),
          optional(:context_tokens) => non_neg_integer() | nil,
          optional(:context_window) => non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          event_id: String.t(),
          stream_id: String.t(),
          sequence: pos_integer(),
          turn_delta: usage() | nil,
          session_snapshot: usage() | nil
        }

  @spec parse(SessionLog.t()) :: {:ok, t()} | :error
  def parse(%SessionLog{format: "harness", content: content, logical_key: logical_key}) do
    with {:ok, %{} = event} <- Jason.decode(content),
         1 <- event["version"],
         event_id when is_binary(event_id) and byte_size(event_id) > 0 <- event["event_id"],
         stream_id when is_binary(stream_id) and byte_size(stream_id) > 0 <- event["stream_id"],
         sequence <- event["sequence"],
         true <- u64?(sequence) and sequence >= 1,
         {:ok, _correlation} <- correlation(event),
         timestamp when is_binary(timestamp) <- event["timestamp"],
         {:ok, _timestamp, _offset} <- DateTime.from_iso8601(timestamp),
         semantics when semantics in ["delta", "snapshot"] <- event["semantics"],
         {:ok, _provider_sequence} <- optional_u64(event, "provider_sequence"),
         "usage" <- event["type"],
         %{} = data <- event["data"],
         true <- logical_key == "harness:" <> event_id,
         {:ok, turn_delta} <- optional_usage(data, "turn_delta", :turn),
         {:ok, session_snapshot} <- optional_usage(data, "session_snapshot", :session) do
      {:ok,
       %__MODULE__{
         event_id: event_id,
         stream_id: stream_id,
         sequence: sequence,
         turn_delta: turn_delta,
         session_snapshot: session_snapshot
       }}
    else
      _ -> :error
    end
  end

  def parse(%SessionLog{}), do: :error

  defp correlation(event) do
    case Map.fetch(event, "correlation") do
      :error ->
        {:ok, %{}}

      {:ok, %{} = correlation} ->
        if Enum.all?(@correlation_keys, &optional_string?(correlation, &1)) do
          {:ok, correlation}
        else
          :error
        end

      {:ok, _invalid} ->
        :error
    end
  end

  defp optional_string?(map, key) do
    case Map.fetch(map, key) do
      :error -> true
      {:ok, nil} -> true
      {:ok, value} -> is_binary(value)
    end
  end

  defp optional_usage(data, key, kind) do
    case Map.fetch(data, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, %{} = value} -> parse_usage(value, kind)
      {:ok, _invalid} -> :error
    end
  end

  defp parse_usage(usage, kind) do
    with %{} = tokens <- usage["tokens"],
         {:ok, parsed_tokens} <- parse_tokens(tokens),
         cost <- usage["cost_microusd"],
         true <- u64?(cost),
         {:ok, context_tokens} <- optional_nonnegative_integer(usage, "context_tokens", kind),
         {:ok, context_window} <- optional_nonnegative_integer(usage, "context_window", kind) do
      {:ok,
       %{
         tokens: parsed_tokens,
         cost_microusd: cost,
         context_tokens: context_tokens,
         context_window: context_window
       }}
    else
      _ -> :error
    end
  end

  defp parse_tokens(tokens) do
    with input <- tokens["input_tokens"],
         true <- u64?(input),
         cached <- tokens["cached_input_tokens"],
         true <- u64?(cached),
         output <- tokens["output_tokens"],
         true <- u64?(output),
         reasoning <- tokens["reasoning_tokens"],
         true <- u64?(reasoning) do
      {:ok,
       %{
         input_tokens: input,
         cached_input_tokens: cached,
         output_tokens: output,
         reasoning_tokens: reasoning
       }}
    else
      _ -> :error
    end
  end

  defp optional_nonnegative_integer(_usage, _key, :turn), do: {:ok, nil}

  defp optional_nonnegative_integer(usage, key, :session) do
    optional_u64(usage, key)
  end

  defp optional_u64(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> if u64?(value), do: {:ok, value}, else: :error
    end
  end

  defp u64?(value), do: is_integer(value) and value >= 0 and value <= @max_u64
end
