defmodule Sacrum.Accounts.SessionLogs.HarnessItemTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sacrum.Accounts.SessionLogs.{HarnessEventV1, HarnessItem}
  alias Sacrum.HarnessDaemonGen

  property "every daemon-shaped event decodes and plays the role its adapter gives it" do
    check all(events <- HarnessDaemonGen.events(), max_runs: 300) do
      for spec <- events do
        attrs = HarnessDaemonGen.attrs(spec, "run")
        assert {:ok, event} = HarnessEventV1.decode(attrs.content, attrs.logical_key)
        assert HarnessItem.classify(event) == spec.role
        assert HarnessItem.completes?(event) == match?({:complete, _key, _type}, spec.role)
      end
    end
  end

  test "reasoning deltas are broadcast-only; the reasoning snapshot is a point" do
    delta = event("reasoning", "delta", %{"text" => "hm"}, %{"item_id" => "r"})
    assert HarnessItem.classify(delta) == {:delta, {:reasoning, "s", "r"}}
    assert HarnessItem.classify(event("reasoning", "snapshot", %{"text" => "hm"})) == :point
  end

  test "usage is a point event whatever its semantics" do
    for semantics <- ~w(delta snapshot) do
      assert HarnessItem.classify(event("usage", semantics, %{})) == :point
    end
  end

  test "text deltas stream their item and a snapshot completes it" do
    text = event("text", "delta", %{"text" => "a"}, %{"item_id" => "i"})
    assert HarnessItem.classify(text) == {:delta, {:text, "s", "i"}}

    assert HarnessItem.classify(%{text | "semantics" => "snapshot"}) ==
             {:complete, {:text, "s", "i"}, "text"}

    assert HarnessItem.classify(event("text", "snapshot", %{"text" => "a"})) == :point
  end

  test "tool events share one item per tool_call_id until a terminal status" do
    key = {:tool, "s", "t1"}

    assert HarnessItem.classify(tool("tool_call", "snapshot", "started")) ==
             {:open, key, "tool_call"}

    assert HarnessItem.classify(tool("tool_output", "delta", "running")) == {:delta, key}

    assert HarnessItem.classify(tool("tool_output", "snapshot", "running")) ==
             {:open, key, "tool_output"}

    for status <- ~w(completed failed declined cancelled) do
      assert HarnessItem.classify(tool("tool_output", "snapshot", status)) ==
               {:complete, key, "tool_output"}
    end

    assert HarnessItem.classify(tool("tool_output", "delta", "completed")) ==
             {:complete, key, nil}
  end

  test "tool_output content_semantics delta is a delta" do
    output =
      tool("tool_output", "snapshot", "running")
      |> put_in(["data", "content_semantics"], "delta")

    assert HarnessItem.classify(output) == {:delta, {:tool, "s", "t1"}}
  end

  test "a file change without status is complete; without a tool call id it is a point" do
    change = event("file_change", "snapshot", %{"tool_call_id" => "t1", "changes" => []})
    assert HarnessItem.classify(change) == {:complete, {:tool, "s", "t1"}, "file_change"}
    assert HarnessItem.classify(event("file_change", "snapshot", %{"changes" => []})) == :point
  end

  test "stream terminals close the stream; everything else is a point" do
    for type <- ~w(turn_finished run_finished session_closed) do
      assert HarnessItem.classify(event(type, "snapshot", %{})) == {:close_stream, "s"}
    end

    for type <- ~w(usage error turn_started control_requested future_event) do
      assert HarnessItem.classify(event(type, "snapshot", %{})) == :point
    end
  end

  defp tool(type, semantics, status),
    do: event(type, semantics, %{"tool_call_id" => "t1", "status" => status})

  defp event(type, semantics, data, correlation \\ %{}) do
    %{
      "type" => type,
      "semantics" => semantics,
      "stream_id" => "s",
      "correlation" => correlation,
      "data" => data
    }
  end
end
