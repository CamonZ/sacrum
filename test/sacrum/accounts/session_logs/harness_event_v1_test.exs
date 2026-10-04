defmodule Sacrum.Accounts.SessionLogs.HarnessEventV1Test do
  use ExUnit.Case, async: true

  alias Sacrum.Accounts.SessionLogs.HarnessEventV1

  @tokens %{"input_tokens" => 1, "cached_input_tokens" => 0, "output_tokens" => 2}

  test "non-usage payloads and metadata remain opaque and unchanged" do
    for type <- ["text", "tool_call", "control_requested", "turn_finished", "future_v1_event"],
        data <- [nil, "opaque", [1, 2], %{"usage" => "client-owned"}] do
      event = event(type, data) |> Map.put("future_metadata", 42)
      assert {:ok, ^event} = decode(event)
    end
  end

  test "accepts only consumed usage counters and preserves unused fields" do
    usage = %{
      "tokens" => Map.put(@tokens, "reasoning_tokens", "opaque"),
      "cost_microusd" => "opaque",
      "context_window" => "opaque"
    }

    event =
      event("usage", %{
        "turn_delta" => usage,
        "session_snapshot" => Map.put(usage, "context_tokens", 0)
      })

    assert {:ok, ^event} = decode(event)

    for data <- [%{}, %{"turn_delta" => nil, "session_snapshot" => nil}] do
      event = event("usage", data)
      assert {:ok, ^event} = decode(event)
    end
  end

  test "rejects malformed consumed usage atomically" do
    for key <- Map.keys(@tokens), value <- [nil, -1, "1", 1.5, 18_446_744_073_709_551_616] do
      data = %{"turn_delta" => %{"tokens" => Map.put(@tokens, key, value)}}
      assert :error = decode(event("usage", data))
    end

    for key <- Map.keys(@tokens) do
      assert :error =
               decode(event("usage", %{"turn_delta" => %{"tokens" => Map.delete(@tokens, key)}}))
    end

    for snapshot <- [false, %{}, %{"tokens" => @tokens, "context_tokens" => -1}] do
      assert :error =
               decode(
                 event("usage", %{
                   "turn_delta" => %{"tokens" => @tokens},
                   "session_snapshot" => snapshot
                 })
               )
    end

    for data <- [nil, [], "usage"], do: assert(:error == decode(event("usage", data)))
  end

  test "requires envelope and matching durable identity" do
    event = event("text", %{"text" => "ok"})

    for key <- ~w(version event_id stream_id sequence timestamp semantics type data) do
      assert :error = decode(Map.delete(event, key))
    end

    for {key, value} <- [
          {"version", 2},
          {"event_id", ""},
          {"stream_id", ""},
          {"sequence", 0},
          {"sequence", 18_446_744_073_709_551_616},
          {"timestamp", "invalid"},
          {"semantics", "invalid"},
          {"correlation", nil},
          {"correlation", %{"thread_id" => 1}},
          {"provider_sequence", -1}
        ] do
      assert :error = decode(Map.put(event, key, value))
    end

    assert :error = HarnessEventV1.decode(Jason.encode!(event), "harness:other")
    assert :error = HarnessEventV1.decode("not json", "harness:event")
    assert :error = HarnessEventV1.decode(nil, nil)
  end

  defp event(type, data) do
    %{
      "version" => 1,
      "event_id" => "event",
      "stream_id" => "stream",
      "sequence" => 1,
      "timestamp" => "2026-10-04T09:00:00Z",
      "semantics" => "delta",
      "type" => type,
      "data" => data
    }
  end

  defp decode(event), do: HarnessEventV1.decode(Jason.encode!(event), "harness:event")
end
