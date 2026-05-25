defmodule Sacrum.ChatSessionRunner.Events.CheckpointsTest do
  use Sacrum.DataCase

  alias Sacrum.ChatSessionRunner.Events.Checkpoints
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "writes one public and one internal checkpoint per turn", ctx do
    assert {:ok, [_public, _internal]} =
             Checkpoints.checkpoint_step(ctx.session, :load_messages, %{"message_count" => 1})

    assert {:ok, [_public, _internal]} =
             Checkpoints.checkpoint_step(ctx.session, :load_messages, %{"message_count" => 1})

    assert ChatSessionRunnerFixtures.event_count(
             ctx.session,
             "chat_session_runner.load_messages.completed"
           ) == 2
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
