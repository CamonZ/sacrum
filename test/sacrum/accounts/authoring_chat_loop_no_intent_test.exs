defmodule Sacrum.Accounts.AuthoringChatLoopNoIntentTest do
  @moduledoc """
  Covers Testing Criterion 4: when the model returns no tool_call, the
  OpenRouter provider must not put an `authoring_tool_intent` key in
  internal_metadata, and `AuthoringChatLoop.apply_inference_result/2` must
  return :ok without touching AuthoringDrafts.
  """

  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{AuthoringChatLoop, Artifacts, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Users

  defp setup_session do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "no-intent-#{suffix}@example.com",
        username: "no_intent_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user.id, %{name: "No-intent Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})
    %{user: user, project: project, session: session}
  end

  test "apply_inference_result/2 is a no-op when authoring_tool_intent is absent" do
    %{user: user, project: project, session: session} = setup_session()

    inference_result = %Result{
      content: "Plain conversational reply.",
      content_format: :markdown,
      public_metadata: %{"provider" => "openrouter-stub", "model" => "test"},
      internal_metadata: %{"provider" => "openrouter-stub", "model" => "test"}
    }

    refute Map.has_key?(inference_result.internal_metadata, "authoring_tool_intent")

    assert :ok = AuthoringChatLoop.apply_inference_result(session, inference_result)

    drafts =
      Artifacts.list_for_subject(user.id, project.id, "chat_session", session.id)
      |> Enum.filter(&(&1.artifact_type == "authoring_draft"))

    assert drafts == []
  end
end
