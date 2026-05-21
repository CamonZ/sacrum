defmodule Sacrum.Accounts.AuthoringChatLoopTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{AuthoringChatLoop, AuthoringDrafts, ChatMessages, LiveChat, Projects}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Users

  defp create_user(prefix \\ "authoring-chat-loop") do
    suffix = System.unique_integer([:positive])
    username_prefix = String.replace(prefix, "-", "_")

    {:ok, user} =
      Users.insert(%{
        email: "#{prefix}-#{suffix}@example.com",
        username: "#{username_prefix}_#{suffix}",
        password: "password123"
      })

    user
  end

  defp setup_chat_session(_context) do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Authoring Chat Loop Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{session_kind: "planning"})

    {:ok, user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "I want this app to be better at planning features.",
        client_message_id: "authoring-loop-user-message"
      })

    %{user: user, project: project, session: session, user_message: user_message}
  end

  describe "handle_tool_intent/5" do
    setup [:setup_chat_session]

    test "turns a vague feature request into feature exploration state and a focused follow-up",
         %{user: user, project: project, session: session, user_message: user_message} do
      intent = %{
        "name" => "authoring.start_feature_exploration",
        "arguments" => %{
          "request" => "Make it easier to plan features",
          "knowns" => ["The user wants better feature planning."],
          "unknowns" => ["Which planning workflow should be improved first?"]
        }
      }

      assert {:ok, response} =
               AuthoringChatLoop.handle_tool_intent(
                 user.id,
                 project.id,
                 session.id,
                 intent,
                 source_message_id: user_message.id
               )

      assert response.assistant_text =~ "Which planning workflow"
      assert response.state.current_state == "feature_exploration"
      assert response.state.state_machine_id == "authoring_chat_loop"
      assert response.state.entrypoint == "feature_exploration"
      assert response.state.draft_id == response.draft.id
      assert response.state.revision == 1
      assert response.state.revision_identity == %{draft_id: response.draft.id, revision: 1}

      draft = Repo.get!(Artifact, response.draft.id)

      assert draft.artifact_type == "authoring_draft"
      assert draft.data["state_machine_id"] == "authoring_chat_loop"
      assert draft.data["state_machine_entrypoint"] == "feature_exploration"
      assert draft.data["current_state"] == "feature_exploration"
      assert draft.data["revision"] == 1
      assert draft.data["knowns"] == ["The user wants better feature planning."]
      assert draft.data["unknowns"] == ["Which planning workflow should be improved first?"]
      assert draft.data["open_questions"] == ["Which planning workflow should be improved first?"]
      assert draft.data["source_chat"]["source_message_id"] == user_message.id
    end

    test "creates one code-factory example draft with a minimal starter shape and summary text",
         %{user: user, project: project, session: session, user_message: user_message} do
      intent = %{
        "name" => "authoring.start_code_factory_example",
        "arguments" => %{
          "request" => "Show a simple code factory example for creating one task"
        }
      }

      assert {:ok, response} =
               AuthoringChatLoop.handle_tool_intent(
                 user.id,
                 project.id,
                 session.id,
                 intent,
                 source_message_id: user_message.id
               )

      assert response.assistant_text =~ "code-factory"
      assert response.assistant_text =~ "starter"
      assert response.state.current_state == "code_factory_starter_example"
      assert response.state.entrypoint == "code_factory_starter_example"

      assert {:ok, %{artifact: draft}} =
               AuthoringDrafts.get_for_chat_session(session, "authoring_chat_loop")

      assert draft.id == response.draft.id
      assert draft.data["state_machine_id"] == "authoring_chat_loop"
      assert draft.data["state_machine_entrypoint"] == "code_factory_starter_example"
      assert draft.data["current_state"] == "code_factory_starter_example"
      assert draft.data["revision"] == 1

      assert draft.data["starter_shape"] == %{
               "kind" => "code_factory_example",
               "goal" => "Create one task from a user request",
               "inputs" => [%{"name" => "feature_request", "type" => "text"}],
               "outputs" => [%{"kind" => "task_draft", "count" => 1}]
             }
    end

    test "updates the existing draft when the user answers the follow-up",
         %{user: user, project: project, session: session, user_message: user_message} do
      assert {:ok, %{artifact: existing_draft}} =
               AuthoringDrafts.upsert_for_chat_session(user.id, project.id, session.id, %{
                 state_machine_id: "authoring_chat_loop",
                 state_machine_entrypoint: "feature_exploration",
                 current_state: "feature_exploration",
                 revision: 1,
                 source_chat: %{
                   chat_session_id: session.id,
                   source_message_id: user_message.id,
                   turn_index: 1
                 },
                 knowns: ["The user wants better feature planning."],
                 unknowns: ["Which workflow matters first?"],
                 open_questions: ["Which workflow matters first?"]
               })

      {:ok, next_user_message} =
        LiveChat.send_message(user.id, project.id, session.id, %{
          content: "Start with breaking a vague request into tickets.",
          client_message_id: "authoring-loop-next-user-message"
        })

      intent = %{
        "name" => "authoring.continue_feature_exploration",
        "arguments" => %{
          "response" => "Start with breaking a vague request into tickets."
        }
      }

      assert {:ok, response} =
               AuthoringChatLoop.handle_tool_intent(
                 user.id,
                 project.id,
                 session.id,
                 intent,
                 source_message_id: next_user_message.id
               )

      assert response.draft.id == existing_draft.id
      assert response.state.draft_id == existing_draft.id
      assert response.state.current_state == "feature_exploration"
      assert response.state.revision == 2
      assert response.state.revision_identity == %{draft_id: existing_draft.id, revision: 2}
      assert response.assistant_text =~ "breaking a vague request into tickets"

      assert {:ok, %{artifact: draft}} =
               AuthoringDrafts.get_for_chat_session(session, "authoring_chat_loop")

      assert draft.id == existing_draft.id
      assert draft.data["revision"] == 2
      assert draft.data["knowns"] == ["Start with breaking a vague request into tickets."]
      assert draft.data["source_chat"]["source_message_id"] == next_user_message.id
    end

    test "persists assistant chat text while Sacrum-owned state tracks draft and revision identity",
         %{user: user, project: project, session: session, user_message: user_message} do
      intent = %{
        "name" => "authoring.start_feature_exploration",
        "arguments" => %{
          "request" => "Explore a feature for guided implementation",
          "unknowns" => ["What concrete example should prove the loop?"]
        }
      }

      assert {:ok, response} =
               AuthoringChatLoop.handle_tool_intent(
                 user.id,
                 project.id,
                 session.id,
                 intent,
                 source_message_id: user_message.id,
                 persist_assistant: true
               )

      assert {:ok, messages} = ChatMessages.list_for_session(user.id, project.id, session.id)
      assert [assistant_message] = Enum.filter(messages, &(&1.role == :assistant))

      assert assistant_message.content == response.assistant_text

      assert assistant_message.metadata["authoring_loop"]["current_state"] ==
               "feature_exploration"

      assert assistant_message.metadata["authoring_loop"]["draft_id"] == response.draft.id
      assert assistant_message.metadata["authoring_loop"]["revision"] == 1

      assert assistant_message.metadata["authoring_loop"]["revision_identity"] == %{
               "draft_id" => response.draft.id,
               "revision" => 1
             }

      refute Map.has_key?(intent["arguments"], "current_state")
      refute Map.has_key?(intent["arguments"], "draft_id")
      refute Map.has_key?(intent["arguments"], "revision")
    end
  end
end
