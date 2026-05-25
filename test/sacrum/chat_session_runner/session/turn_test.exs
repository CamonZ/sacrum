defmodule Sacrum.ChatSessionRunner.Session.TurnTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.ChatMessages
  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "finds the latest user turn and derives assistant client ids", ctx do
    assert {:ok, latest} = Turn.latest_user_message(ctx.session)
    assert latest.id == ctx.user_message.id

    assistant_client_id = Turn.assistant_client_message_id(latest.id)
    assert assistant_client_id == "chat_session_runner:assistant:v1:#{latest.id}"

    {:ok, assistant} =
      ChatMessages.append_to_session(ctx.session, %{
        role: :assistant,
        content: "Answer",
        content_format: :markdown,
        client_message_id: assistant_client_id
      })

    assert Turn.turn_message_id_from_assistant(assistant) == latest.id
    assert Turn.compare_messages(assistant, latest) == :gt
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
