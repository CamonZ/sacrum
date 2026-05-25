defmodule Sacrum.ChatSessionRunner.Events.InferenceEventsTest do
  use Sacrum.DataCase

  alias Sacrum.ChatSessionRunner.Events.InferenceEvents
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  test "creates inference completed events idempotently by assistant message", ctx do
    result = ChatSessionRunnerFixtures.build_result()

    {:ok, assistant} =
      ChatSessionRunnerFixtures.append_assistant(ctx.session, ctx.user_message, result)

    assert {:ok, first} =
             InferenceEvents.append_inference_completed_event(ctx.session, assistant, result)

    assert {:ok, second} =
             InferenceEvents.append_inference_completed_event(ctx.session, assistant, result)

    assert first.id == second.id

    assert {:ok, found} =
             InferenceEvents.get_inference_completed_for_assistant(ctx.session, assistant.id)

    assert found.id == first.id
  end

  defp setup_session(context), do: ChatSessionRunnerFixtures.setup_session(context)
end
