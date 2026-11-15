defmodule Sacrum.HarnessDaemonGen do
  @moduledoc """
  StreamData generators for HarnessEventV1 streams shaped like the ones the
  Vertebrae daemon's adapters emit (`crates/harness-claude`,
  `crates/harness-codex`):

  - text: `text` deltas carrying `correlation.item_id` (Claude `text_delta`,
    Codex `agentMessageDelta`), then a `text` snapshot with the same item id
    holding the whole text. An interrupted message has no snapshot.
  - reasoning: `reasoning` deltas with an item id (Claude `thinking_delta`),
    then a `reasoning` snapshot without one.
  - Claude tools: optional `file_change` `started` (edit tools), `tool_call`
    `started` with name and input, `tool_output` `running` deltas
    (`tool_progress`), then on `tool_result` a `file_change` with a terminal
    status followed by the terminal `tool_output`.
  - Codex tools: `tool_call` `started` on `item/started`, the terminal
    `tool_output` on `item/completed`; file changes are their own item, a
    `file_change` `started` then `completed`.
  - usage: Claude `message_delta` usage (a `session_snapshot` snapshot), the
    Claude result usage (a `turn_delta` with `delta` semantics) and Codex
    `tokenUsage` (both, snapshot semantics).
  - lifecycle: `turn_started`, `warning`, `error` points, and a stream end
    (`turn_finished`, `run_finished` or `session_closed`) whose outcome repeats
    the usage, which must not be counted again.

  Each spec carries the role the event plays per the ingestion contract
  (`Sacrum.Accounts.SessionLogs.HarnessItem.t()`), derived from the adapter
  behaviour above rather than from the classifier.
  """

  import StreamData

  @tool_outcomes ~w(completed failed declined cancelled)

  @doc "Interleaved daemon events for 1 to 3 concurrent streams."
  def events do
    bind(list_of(stream_plan(), min_length: 1, max_length: 3), fn plans ->
      streams =
        plans
        |> Enum.with_index()
        |> Enum.map(fn {plan, index} -> build_stream("s#{index}", plan) end)

      total = streams |> Enum.map(&length/1) |> Enum.sum()

      map(list_of(integer(0..(length(streams) - 1)), length: total), fn schedule ->
        interleave(streams, schedule, [])
      end)
    end)
  end

  @doc "A stream's segments and how it ends."
  def stream_plan do
    tuple({
      list_of(segment(), min_length: 1, max_length: 6),
      frequency([
        {6, member_of(~w(turn_finished run_finished session_closed))},
        {1, constant(nil)}
      ])
    })
  end

  defp segment do
    frequency([
      {4,
       tuple({constant(:text), chunks(), frequency([{5, constant(true)}, {1, constant(false)}])})},
      {1, tuple({constant(:reasoning), chunks()})},
      {4,
       tuple({
         constant(:tool),
         member_of([:claude, :codex]),
         boolean(),
         integer(0..3),
         frequency([{4, member_of(@tool_outcomes)}, {1, constant(:unfinished)}])
       })},
      {3,
       tuple({constant(:usage), member_of([:claude_message, :claude_result, :codex]), tokens()})},
      {1, tuple({constant(:point), member_of(~w(turn_started warning error))})}
    ])
  end

  defp chunks, do: list_of(string(:alphanumeric, min_length: 1, max_length: 4), max_length: 4)

  defp tokens, do: tuple({integer(0..5_000), integer(0..5_000), integer(0..5_000)})

  defp build_stream(stream_id, {segments, ending}) do
    events =
      segments
      |> Enum.with_index()
      |> Enum.flat_map(fn {segment, index} -> build(segment, stream_id, index) end)

    events = if ending, do: events ++ [finish(stream_id, ending)], else: events

    events
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, sequence} -> Map.put(spec, :sequence, sequence) end)
  end

  defp build({:text, chunks, finished?}, stream, index) do
    item = "msg#{index}:block:0"
    key = {:text, stream, item}

    deltas =
      for chunk <- chunks,
          do:
            spec(stream, "text", "delta", %{"text" => chunk}, {:delta, key}, %{"item_id" => item})

    snapshot =
      spec(
        stream,
        "text",
        "snapshot",
        %{"text" => Enum.join(chunks), "completion_status" => "completed"},
        {:complete, key, "text"},
        %{"item_id" => item}
      )

    if finished?, do: deltas ++ [snapshot], else: deltas
  end

  defp build({:reasoning, chunks}, stream, index) do
    item = "msg#{index}:block:1"
    key = {:reasoning, stream, item}

    deltas =
      for chunk <- chunks,
          do:
            spec(stream, "reasoning", "delta", %{"text" => chunk}, {:delta, key}, %{
              "item_id" => item
            })

    deltas ++ [spec(stream, "reasoning", "snapshot", %{"text" => Enum.join(chunks)}, :point)]
  end

  defp build({:tool, :codex, true, _progress, outcome}, stream, index) do
    id = "call#{index}"
    key = {:tool, stream, id}
    started = file_change(stream, id, "started", {:open, key, "file_change"})

    case outcome do
      :unfinished ->
        [started]

      outcome ->
        status = if outcome == "completed", do: "completed", else: "failed"
        [started, file_change(stream, id, status, {:complete, key, "file_change"})]
    end
  end

  defp build({:tool, flavor, file?, progress, outcome}, stream, index) do
    id = "call#{index}"
    key = {:tool, stream, id}
    file? = flavor == :claude and file?

    call =
      spec(
        stream,
        "tool_call",
        "snapshot",
        %{
          "tool_call_id" => id,
          "name" => "Edit",
          "input" => %{"file_path" => "a.ex"},
          "status" => "started"
        },
        {:open, key, "tool_call"},
        %{"tool_call_id" => id}
      )

    progress =
      for seconds <- 1..progress//1,
          do:
            spec(
              stream,
              "tool_output",
              "delta",
              %{
                "tool_call_id" => id,
                "output" => %{
                  "kind" => "progress",
                  "tool_name" => "Edit",
                  "elapsed_seconds" => seconds
                },
                "status" => "running",
                "content_semantics" => "delta"
              },
              {:delta, key}
            )

    opened =
      if file?,
        do: [file_change(stream, id, "started", {:open, key, "file_change"}), call],
        else: [call]

    case outcome do
      :unfinished ->
        opened ++ progress

      outcome ->
        output =
          spec(
            stream,
            "tool_output",
            "snapshot",
            %{
              "tool_call_id" => id,
              "output" => "done",
              "status" => outcome,
              "content_semantics" => "snapshot"
            },
            {:complete, key, "tool_output"},
            %{"tool_call_id" => id}
          )

        if file? do
          status = if outcome == "completed", do: "completed", else: "failed"
          # Claude emits the file change before the tool output, so the file
          # change completes the item and the output is stored after it.
          opened ++
            progress ++ [file_change(stream, id, status, {:complete, key, "file_change"}), output]
        else
          opened ++ progress ++ [output]
        end
    end
  end

  defp build({:usage, :claude_message, {input, cached, output}}, stream, _index) do
    data = %{
      "session_snapshot" =>
        Map.merge(usage(input, cached, output), %{
          "context_tokens" => input + cached,
          "context_window" => 200_000
        })
    }

    [spec(stream, "usage", "snapshot", data, :point)]
  end

  defp build({:usage, :claude_result, {input, cached, output}}, stream, _index) do
    data = %{"turn_delta" => Map.put(usage(input, cached, output), "cost_microusd", 12)}
    [spec(stream, "usage", "delta", data, :point)]
  end

  defp build({:usage, :codex, {input, cached, output}}, stream, _index) do
    data = %{
      "turn_delta" => usage(div(input, 2), div(cached, 2), div(output, 2)),
      "session_snapshot" =>
        Map.put(usage(input, cached, output), "context_tokens", input + output)
    }

    [spec(stream, "usage", "snapshot", data, :point)]
  end

  defp build({:point, type}, stream, _index),
    do: [spec(stream, type, "snapshot", %{"message" => type}, :point)]

  defp finish(stream, type) do
    data = %{"status" => "completed", "usage" => usage(1_000, 0, 1_000)}
    spec(stream, type, "snapshot", data, {:close_stream, stream})
  end

  defp file_change(stream, id, status, role) do
    spec(
      stream,
      "file_change",
      "snapshot",
      %{
        "tool_call_id" => id,
        "changes" => [%{"path" => "a.ex", "kind" => "update"}],
        "status" => status
      },
      role,
      %{"tool_call_id" => id}
    )
  end

  defp spec(stream, type, semantics, data, role, correlation \\ %{}) do
    %{
      stream_id: stream,
      type: type,
      semantics: semantics,
      data: data,
      correlation: correlation,
      role: role
    }
  end

  def usage(input, cached, output) do
    %{
      "tokens" => %{
        "input_tokens" => input,
        "cached_input_tokens" => cached,
        "output_tokens" => output
      }
    }
  end

  # Advance the scheduled stream, or the next one with events left.
  defp interleave(streams, [pick | schedule], acc) do
    count = length(streams)

    index =
      Enum.find(0..(count - 1), fn offset -> Enum.at(streams, rem(pick + offset, count)) != [] end)

    case index do
      nil ->
        Enum.reverse(acc)

      offset ->
        at = rem(pick + offset, count)
        [event | rest] = Enum.at(streams, at)
        interleave(List.replace_at(streams, at, rest), schedule, [event | acc])
    end
  end

  defp interleave(_streams, [], acc), do: Enum.reverse(acc)

  @doc "The decoded V1 envelope of a spec."
  def envelope(spec, run) do
    %{
      "version" => 1,
      "event_id" => event_id(spec, run),
      "stream_id" => spec.stream_id,
      "sequence" => spec.sequence,
      "timestamp" => "2026-11-14T00:00:00Z",
      "semantics" => spec.semantics,
      "type" => spec.type,
      "correlation" => spec.correlation,
      "data" => spec.data
    }
  end

  @doc "`createSessionLog` attributes for a spec."
  def attrs(spec, run) do
    %{logical_key: "harness:" <> event_id(spec, run), content: Jason.encode!(envelope(spec, run))}
  end

  defp event_id(spec, run), do: "#{run}-#{spec.stream_id}-#{spec.sequence}"
end
