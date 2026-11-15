defmodule Sacrum.Accounts.SessionLogs.HarnessItem do
  @moduledoc """
  Classifies a decoded harness event by the item it belongs to.

  An item is a unit that streams and later completes:

  - text: `{:text, stream_id, item_id}`, from `correlation.item_id`. Deltas
    stream it; a snapshot completes it.
  - tool: `{:tool, stream_id, tool_call_id}`, shared by `tool_call`,
    `tool_output` and `file_change` events with that `tool_call_id`. Deltas
    (streamed input or progress output) stream it; non-terminal snapshots
    update it; the first event with a terminal status (`completed`, `failed`,
    `declined`, `cancelled`) completes it. A terminal delta completes it with
    `nil` as its type: it carries no final state of its own.

  - reasoning: deltas (Claude `thinking_delta`) are broadcast only, keyed
    `{:reasoning, stream_id, item_id}`. The reasoning snapshot carries no item
    id, so it is a point event and never completes the key.

  `turn_finished`, `run_finished` and `session_closed` close what is still
  open on their stream. Every other event, including a `usage` event with
  delta semantics, is a point event, complete on arrival.
  """

  @terminal_statuses ~w(completed failed declined cancelled)
  @stream_terminals ~w(turn_finished run_finished session_closed)
  @tool_types ~w(tool_call tool_output file_change)

  @type key ::
          {:text, String.t(), String.t()}
          | {:tool, String.t(), String.t()}
          | {:reasoning, String.t(), String.t() | nil}
  @type t ::
          {:delta, key()}
          | {:open, key(), String.t()}
          | {:complete, key(), String.t() | nil}
          | {:close_stream, String.t()}
          | :point

  @doc "The item role of a decoded V1 event."
  @spec classify(map()) :: t()
  def classify(
        %{"type" => "reasoning", "semantics" => "delta", "stream_id" => stream_id} = event
      ),
      do: {:delta, {:reasoning, stream_id, get_in(event, ["correlation", "item_id"])}}

  def classify(%{"type" => type, "stream_id" => stream_id} = event) do
    case key(event) do
      nil ->
        if type in @stream_terminals, do: {:close_stream, stream_id}, else: :point

      key ->
        role(key, type, delta?(event), terminal?(event))
    end
  end

  def classify(_event), do: :point

  defp role(key, _type, true, true), do: {:complete, key, nil}
  defp role(key, _type, true, false), do: {:delta, key}
  defp role({:text, _stream, _item} = key, type, false, _terminal), do: {:complete, key, type}
  defp role(key, type, false, true), do: {:complete, key, type}
  defp role(key, type, false, false), do: {:open, key, type}

  @doc "Whether a stored event completes its item."
  @spec completes?(map()) :: boolean()
  def completes?(event), do: match?({:complete, _key, _type}, classify(event))

  @doc "The item key of a stored event, if it has one."
  @spec item_key(map()) :: key() | nil
  def item_key(event), do: key(event)

  defp key(%{"type" => "text", "stream_id" => stream_id} = event) do
    item_id = get_in(event, ["correlation", "item_id"])
    if nonempty?(item_id), do: {:text, stream_id, item_id}
  end

  defp key(%{"type" => type, "stream_id" => stream_id, "data" => %{} = data})
       when type in @tool_types do
    if nonempty?(data["tool_call_id"]), do: {:tool, stream_id, data["tool_call_id"]}
  end

  defp key(_event), do: nil

  defp delta?(%{"semantics" => "delta"}), do: true
  defp delta?(%{"type" => "tool_output", "data" => %{"content_semantics" => "delta"}}), do: true
  defp delta?(_event), do: false

  defp terminal?(%{"type" => "file_change", "data" => %{} = data}),
    do: Map.get(data, "status", "completed") in @terminal_statuses

  defp terminal?(%{"data" => %{"status" => status}}), do: status in @terminal_statuses
  defp terminal?(_event), do: false

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
end
