defmodule Sacrum.ChatSessionRunner.Transcript.InferenceMessagesTest do
  use Sacrum.DataCase

  alias Sacrum.ChatSessionRunner.Transcript.{InferenceMessages, Messages}
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "keeps user turns and their paired assistant replies only", ctx do
    {:ok, status} = Messages.ensure_status_message(ctx.session, :intake, "Started")
    {:ok, assistant} = ChatSessionRunnerFixtures.append_assistant(ctx.session, ctx.user_message)

    messages = [ctx.user_message, status, assistant]

    assert InferenceMessages.conversation_messages_for_inference(messages) == [
             ctx.user_message,
             assistant
           ]
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
