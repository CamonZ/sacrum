defmodule Sacrum.ChatSessionRunner.DirectTracker.OperationsTest do
  use Sacrum.DataCase

  alias Sacrum.Chat.DirectTrackerOperationResolver
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.DirectTracker.Operations
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "detects and deserializes resolved direct tracker metadata", ctx do
    operation = ChatSessionRunnerFixtures.show_task_operation(ctx)
    serialized = DirectTrackerOperationResolver.serialize_resolution(operation)

    result = %Result{
      ChatSessionRunnerFixtures.build_result()
      | internal_metadata: %{"resolved_direct_tracker_operation" => serialized}
    }

    assert Operations.direct_tracker_metadata?(result)
    assert {:ok, [deserialized]} = Operations.direct_tracker_operations(result)
    assert deserialized.action == "show_task"
    assert deserialized.targets.task.id == operation.targets.task.id
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
