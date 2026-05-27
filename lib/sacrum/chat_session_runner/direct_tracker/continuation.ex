defmodule Sacrum.ChatSessionRunner.DirectTracker.Continuation do
  @moduledoc """
  Builds model-only continuation messages after direct tracker tool execution.
  """

  alias Sacrum.ChatSessionRunner.DirectTracker.Events
  alias Sacrum.Repo.Schemas.ChatEvent

  @tool_calls_key "direct_tracker_provider_tool_calls"
  @assistant_content_key "direct_tracker_assistant_content"

  @spec put_metadata(map(), [map()]) :: map()
  def put_metadata(metadata, resolved) when is_map(metadata) and is_list(resolved) do
    tool_calls =
      resolved
      |> Enum.map(&Map.get(&1, :tool_call))
      |> Enum.reject(&is_nil/1)

    if length(tool_calls) == length(resolved) do
      metadata
      |> Map.put(@tool_calls_key, tool_calls)
      |> maybe_put_assistant_content(resolved)
    else
      metadata
    end
  end

  @spec messages(map(), [ChatEvent.t()]) :: {:ok, [map()]} | {:error, term()}
  def messages(%{} = metadata, events) when is_list(events) do
    with {:ok, tool_calls} <- tool_calls(metadata),
         :ok <- ensure_has_events(events),
         :ok <- ensure_event_count(tool_calls, events) do
      assistant_message = %{
        role: :assistant,
        content: assistant_content(metadata),
        tool_calls: Enum.map(tool_calls, &req_llm_tool_call/1)
      }

      {:ok, [assistant_message | tool_result_messages(tool_calls, events)]}
    end
  end

  def messages(_metadata, _events), do: {:error, :missing_direct_tracker_result_events}

  @spec tool_calls(map()) :: {:ok, [map()]} | {:error, term()}
  def tool_calls(%{} = metadata) do
    metadata
    |> Map.get(@tool_calls_key)
    |> case do
      [_ | _] = tool_calls -> {:ok, tool_calls}
      _other -> {:error, :missing_direct_tracker_tool_call_metadata}
    end
  end

  defp maybe_put_assistant_content(metadata, [%{assistant_content: content} | _])
       when is_binary(content) do
    Map.put(metadata, @assistant_content_key, content)
  end

  defp maybe_put_assistant_content(metadata, _resolved), do: metadata

  defp ensure_has_events([_ | _]), do: :ok
  defp ensure_has_events(_events), do: {:error, :missing_direct_tracker_result_events}

  defp ensure_event_count(tool_calls, events) do
    if length(tool_calls) == length(events) do
      :ok
    else
      {:error, :direct_tracker_tool_result_mismatch}
    end
  end

  defp assistant_content(%{@assistant_content_key => content})
       when is_binary(content),
       do: content

  defp assistant_content(_metadata), do: ""

  defp tool_result_messages(tool_calls, events) do
    tool_calls
    |> Enum.zip(events)
    |> Enum.map(fn {tool_call, event} ->
      %{
        role: :tool,
        tool_call_id: Map.fetch!(tool_call, "id"),
        name: tool_call_name(tool_call),
        content: Jason.encode!(tool_result_payload(event))
      }
    end)
  end

  defp req_llm_tool_call(tool_call) do
    %{
      id: Map.fetch!(tool_call, "id"),
      name: tool_call_name(tool_call),
      input: tool_call_arguments(tool_call)
    }
  end

  defp tool_call_name(tool_call), do: get_in(tool_call, ["function", "name"])

  defp tool_call_arguments(tool_call) do
    tool_call
    |> get_in(["function", "arguments"])
    |> decode_tool_call_arguments()
  end

  defp decode_tool_call_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  defp decode_tool_call_arguments(arguments) when is_map(arguments), do: arguments
  defp decode_tool_call_arguments(_arguments), do: %{}

  defp tool_result_payload(%ChatEvent{} = event) do
    event.internal_payload
    |> Map.get("result")
    |> Events.serialize_result()
  end
end
