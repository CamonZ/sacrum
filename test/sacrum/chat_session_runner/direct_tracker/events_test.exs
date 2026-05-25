defmodule Sacrum.ChatSessionRunner.DirectTracker.EventsTest do
  use Sacrum.DataCase

  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.DirectTracker.Events
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  defmodule UnsupportedDirectTrackerStruct do
    defstruct [:value]
  end

  setup [:setup_session]

  test "converts direct tracker scalar structs and nested values into JSON-compatible values" do
    completed_at = ~U[2026-05-23 00:38:14.956038Z]
    naive_at = ~N[2026-05-23 00:38:14.956038]
    date = ~D[2026-05-23]
    time = ~T[12:34:56.789]

    assert Events.serialize_result(%{
             action: :show_task,
             task: %{
               completed_at: completed_at,
               naive_at: naive_at,
               date: date,
               time: time,
               estimate: Decimal.new("12.34"),
               status: :done,
               nil_value: nil,
               flags: [true, false, :blocked],
               tuple: {:ok, completed_at},
               nested: [%{date: date}]
             }
           }) == %{
             "action" => "show_task",
             "task" => %{
               "completed_at" => "2026-05-23T00:38:14.956038Z",
               "naive_at" => "2026-05-23T00:38:14.956038",
               "date" => "2026-05-23",
               "time" => "12:34:56.789",
               "estimate" => "12.34",
               "status" => "done",
               "nil_value" => nil,
               "flags" => [true, false, "blocked"],
               "tuple" => ["ok", "2026-05-23T00:38:14.956038Z"],
               "nested" => [%{"date" => "2026-05-23"}]
             }
           }
  end

  test "falls back deterministically for unsupported structs instead of raising" do
    value = %UnsupportedDirectTrackerStruct{value: "opaque"}

    assert Events.serialize_result(%{value: value}) == %{
             "value" => inspect(value)
           }
  end

  test "persists completed and rejected direct tracker events", ctx do
    operation = ChatSessionRunnerFixtures.show_task_operation(ctx)

    assert {:ok, completed} =
             Events.append_completed(
               ctx.session,
               operation,
               %{task: %{id: operation.targets.task.id}},
               %{
                 "turn_message_id" => ctx.user_message.id
               }
             )

    assert completed.public_payload["status"] == "succeeded"
    assert completed.public_payload["target"]["id"] == operation.targets.task.id

    result = %Result{
      ChatSessionRunnerFixtures.build_result()
      | internal_metadata: %{
          "direct_tracker_operation_rejected" => %{"reason_code" => "out_of_scope"}
        }
    }

    assert {:ok, rejected} = Events.append_rejection(ctx.session, result, ctx.user_message.id)
    assert rejected.public_payload["status"] == "rejected"
    assert rejected.public_payload["reason"] == "out_of_scope"
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
