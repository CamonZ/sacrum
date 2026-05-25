defmodule Sacrum.ChatSessionRunner.Events.MessageEventsTest do
  use Sacrum.DataCase

  alias Sacrum.ChatSessionRunner.Events.MessageEvents
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "creates the public message event idempotently", ctx do
    assert {:ok, first} =
             MessageEvents.ensure_public_message_event(ctx.session, ctx.user_message)

    assert {:ok, second} =
             MessageEvents.ensure_public_message_event(ctx.session, ctx.user_message)

    assert first.id == second.id
    assert first.event_type == "chat_message_created"
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
