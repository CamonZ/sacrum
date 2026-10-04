defmodule Sacrum.Accounts.SessionLogs.HarnessEventV1 do
  @moduledoc """
  Validates the V1 envelope, durable identity, and counters used by Sacrum.

  Non-usage payloads and unconsumed usage metadata remain opaque. The original
  JSON is persisted unchanged for clients to interpret.
  """

  @max_u64 18_446_744_073_709_551_615
  @correlation_keys ~w(session_id thread_id turn_id run_id item_id tool_call_id parent_tool_call_id provider_resume_id)
  @token_keys ~w(input_tokens cached_input_tokens output_tokens)

  @spec decode(String.t(), String.t()) :: {:ok, map()} | :error
  def decode(content, logical_key) when is_binary(content) and is_binary(logical_key) do
    with {:ok, %{} = event} <- Jason.decode(content),
         1 <- event["version"],
         true <- nonempty_string?(event["event_id"]) and nonempty_string?(event["stream_id"]),
         true <- u64?(event["sequence"]) and event["sequence"] > 0,
         timestamp when is_binary(timestamp) <- event["timestamp"],
         {:ok, _timestamp, _offset} <- DateTime.from_iso8601(timestamp),
         semantics when semantics in ["delta", "snapshot"] <- event["semantics"],
         true <- optional?(event, "provider_sequence", &u64?/1),
         true <- correlation?(Map.get(event, "correlation", %{})),
         true <- nonempty_string?(event["type"]),
         {:ok, data} <- Map.fetch(event, "data"),
         true <- logical_key == "harness:" <> event["event_id"],
         true <- payload?(event["type"], data) do
      {:ok, event}
    else
      _ -> :error
    end
  end

  def decode(_content, _logical_key), do: :error

  defp payload?("usage", %{} = data) do
    optional?(data, "turn_delta", &usage?(&1, :turn)) and
      optional?(data, "session_snapshot", &usage?(&1, :session))
  end

  defp payload?("usage", _data), do: false
  defp payload?(_type, _data), do: true

  defp usage?(%{"tokens" => %{} = tokens} = usage, kind) do
    Enum.all?(@token_keys, &u64?(tokens[&1])) and
      (kind == :turn or optional?(usage, "context_tokens", &u64?/1))
  end

  defp usage?(_usage, _kind), do: false

  defp correlation?(%{} = correlation),
    do:
      Enum.all?(@correlation_keys, &optional?(correlation, &1, fn value -> is_binary(value) end))

  defp correlation?(_correlation), do: false

  defp optional?(map, key, valid?) do
    case Map.get(map, key) do
      nil -> true
      value -> valid?.(value)
    end
  end

  defp nonempty_string?(value), do: is_binary(value) and byte_size(value) > 0
  defp u64?(value), do: is_integer(value) and value >= 0 and value <= @max_u64
end
