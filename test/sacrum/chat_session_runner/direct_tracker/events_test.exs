defmodule Sacrum.ChatSessionRunner.DirectTracker.EventsTest do
  use Sacrum.DataCase

  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.DirectTracker.Events
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

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
