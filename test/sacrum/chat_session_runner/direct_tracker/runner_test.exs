defmodule Sacrum.ChatSessionRunner.DirectTracker.RunnerTest do
  use Sacrum.DataCase

  alias Sacrum.ChatSessionRunner.DirectTracker.Runner
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "executes resolved operations and records public events", ctx do
    operation = ChatSessionRunnerFixtures.show_task_operation(ctx)

    assert {:ok, [event]} =
             Runner.execute(ctx.session, [operation], %{
               "turn_message_id" => ctx.user_message.id
             })

    assert event.event_type == "chat_direct_tracker_operation.completed"
    assert event.public_payload["action"] == "show_task"
    assert event.public_payload["result"]["id"] == operation.targets.task.id
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
