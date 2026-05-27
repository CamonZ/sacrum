defmodule Sacrum.ChatSessionRunner.DirectTracker.ContinuationTest do
  use ExUnit.Case, async: true

  alias Sacrum.ChatSessionRunner.DirectTracker.Continuation
  alias Sacrum.Repo.Schemas.ChatEvent

  test "builds assistant tool_call and tool result continuation messages" do
    metadata = %{
      "direct_tracker_provider_tool_calls" => [
        %{
          "id" => "call_show_task_0",
          "type" => "function",
          "function" => %{
            "name" => "show_task",
            "arguments" => "{\"task_ref\":\"8048bf17\"}"
          }
        }
      ],
      "direct_tracker_assistant_content" => ""
    }

    events = [
      %ChatEvent{
        internal_payload: %{
          "result" => %{
            "action" => "show_task",
            "task" => %{"id" => "8048bf17", "title" => "Continue chat"}
          }
        }
      }
    ]

    assert {:ok,
            [
              %{
                role: :assistant,
                content: "",
                tool_calls: [
                  %{
                    id: "call_show_task_0",
                    name: "show_task",
                    input: %{"task_ref" => "8048bf17"}
                  }
                ]
              },
              %{
                role: :tool,
                tool_call_id: "call_show_task_0",
                name: "show_task",
                content: content
              }
            ]} = Continuation.messages(metadata, events)

    assert Jason.decode!(content) == %{
             "action" => "show_task",
             "task" => %{"id" => "8048bf17", "title" => "Continue chat"}
           }
  end
end
