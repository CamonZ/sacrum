defmodule Sacrum.ChatSessionRunner.Transcript.MessagesTest do
  use Sacrum.DataCase

  alias Sacrum.ChatSessionRunner.Transcript.Messages
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "creates status and assistant messages idempotently", ctx do
    assert {:ok, first} = Messages.ensure_status_message(ctx.session, :intake, "Started")
    assert {:ok, second} = Messages.ensure_status_message(ctx.session, :intake, "Started")
    assert first.id == second.id

    assert {:ok, assistant} =
             ChatSessionRunnerFixtures.append_assistant(ctx.session, ctx.user_message)

    assert {:ok, found} = Messages.lookup_assistant_message(ctx.session)
    assert found.id == assistant.id
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
