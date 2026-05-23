defmodule Sacrum.Accounts.AuthoringChatLoopTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{AuthoringChatLoop, AuthoringDrafts, ChatMessages, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
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

    test "turns a vague feature request into a template-backed feature draft and focused follow-up",
         %{user: user, project: project, session: session, user_message: user_message} do
      insert_feature_exploration_template!(scoped_to(project))

      intent = %{
        "name" => "authoring.start_feature_exploration",
        "arguments" => %{
          "request" => "Make feature planning better somehow"
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

      assert response.assistant_text =~ "What user-visible behavior should change first?"
      assert response.state.current_state == "collect_feature_scope"
      assert response.state.state_machine_id == "feature_exploration"
      assert response.state.state_machine_entrypoint == "start_minimal_feature_exploration"
      assert response.state.draft_id == response.draft.id
      assert response.state.revision == %{"source" => "authoring_template", "value" => 1}

      assert response.state.revision_identity == %{
               draft_id: response.draft.id,
               revision: %{"source" => "authoring_template", "value" => 1}
             }

      draft = Repo.get!(Artifact, response.draft.id)

      assert draft.artifact_type == "authoring_draft"
      assert draft.data["state_machine_id"] == "feature_exploration"
      assert draft.data["state_machine_entrypoint"] == "start_minimal_feature_exploration"
      assert draft.data["current_state"] == "collect_feature_scope"
      assert draft.data["revision"] == %{"source" => "authoring_template", "value" => 1}

      assert draft.data["assumptions"] == [
               "The user has a feature idea but not enough implementation detail yet."
             ]

      assert draft.data["open_questions"] == [
               "What user-visible behavior should change first?"
             ]

      assert draft.data["proposed_approach"] == [
               "Capture the smallest useful outcome before decomposing work."
             ]

      assert [
               %{
                 "title" => "Clarify minimal feature outcome",
                 "level" => "task",
                 "desired_behavior" => "Record the feature goal, constraints, and unknowns."
               }
             ] = draft.data["candidate_work_units"]

      assert draft.data["source_chat"]["source_message_id"] == user_message.id
      refute Map.has_key?(draft.data, "starter_shape")
    end

    test "creates and revises one code-factory example draft from template-backed structured payloads",
         %{project: project, session: session, user_message: user_message} do
      insert_code_factory_template!(scoped_to(project))

      start_result = authoring_result(code_factory_start_intent(user_message.id))

      assert :ok = AuthoringChatLoop.apply_inference_result(session, start_result)

      assert {:ok, %{artifact: draft}} =
               AuthoringDrafts.get_for_chat_session(session, "code_factory_creation")

      assert draft.data["state_machine_id"] == "code_factory_creation"
      assert draft.data["state_machine_entrypoint"] == "start_code_factory_creation"
      assert draft.data["current_state"] == "collect_workflow_goal"
      assert draft.data["revision"] == %{"source" => "authoring_template", "value" => 1}

      assert [%{"key" => "implementation", "steps" => [%{"key" => "work"}]}] =
               draft.data["workflows"]

      assert [%{"target_step" => "verification.review"}] = draft.data["transitions"]

      assert "Every prompt uses guarded Liquid variables." in draft.data[
               "validation_expectations"
             ]

      refute Map.has_key?(draft.data, "starter_shape")

      revise_result =
        authoring_result(%{
          "action" => "revise_authoring",
          "state_machine_id" => "code_factory_creation",
          "current_state" => "refine_workflow_recipe",
          "source_message_id" => user_message.id,
          "feedback" => "Have review require tests."
        })

      assert :ok = AuthoringChatLoop.apply_inference_result(session, revise_result)

      assert {:ok, %{artifact: revised_draft}} =
               AuthoringDrafts.get_for_chat_session(session, "code_factory_creation")

      assert revised_draft.id == draft.id
      assert revised_draft.data["current_state"] == "refine_workflow_recipe"
      assert revised_draft.data["revision"] == %{"source" => "chat_feedback", "value" => 2}
      assert revised_draft.data["workflows"] == draft.data["workflows"]
      assert revised_draft.data["revision_notes"] == ["Have review require tests."]
    end

    test "rejects unsupported structured authoring actions", %{session: session} do
      result = authoring_result(%{"action" => "delete_authoring"})

      assert {:error, :unsupported_authoring_action} =
               AuthoringChatLoop.apply_inference_result(session, result)
    end

    test "updates the existing draft when the user answers the follow-up",
         %{user: user, project: project, session: session, user_message: user_message} do
      insert_feature_exploration_template!(scoped_to(project))

      assert {:ok, %{artifact: existing_draft}} =
               AuthoringDrafts.upsert_for_chat_session(user.id, project.id, session.id, %{
                 state_machine_id: "feature_exploration",
                 state_machine_entrypoint: "start_minimal_feature_exploration",
                 current_state: "collect_feature_scope",
                 revision: %{source: "authoring_template", value: 1},
                 source_chat: %{
                   chat_session_id: session.id,
                   source_message_id: user_message.id,
                   turn_index: 1
                 },
                 assumptions: ["The user wants better feature planning."],
                 open_questions: ["Which workflow matters first?"],
                 proposed_approach: [
                   "Capture the smallest useful outcome before decomposing work."
                 ]
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
      assert response.state.current_state == "refine_feature_scope"
      assert response.state.revision == %{"source" => "chat_feedback", "value" => 2}

      assert response.state.revision_identity == %{
               draft_id: existing_draft.id,
               revision: %{"source" => "chat_feedback", "value" => 2}
             }

      assert response.assistant_text =~ "breaking a vague request into tickets"

      assert {:ok, %{artifact: draft}} =
               AuthoringDrafts.get_for_chat_session(session, "feature_exploration")

      assert draft.id == existing_draft.id
      assert draft.data["revision"] == %{"source" => "chat_feedback", "value" => 2}

      assert draft.data["revision_notes"] == [
               "Start with breaking a vague request into tickets."
             ]

      assert draft.data["source_chat"]["source_message_id"] == next_user_message.id
    end

    test "persists assistant chat text while Sacrum-owned state tracks draft and revision identity",
         %{user: user, project: project, session: session, user_message: user_message} do
      insert_feature_exploration_template!(scoped_to(project))

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
               "collect_feature_scope"

      assert assistant_message.metadata["authoring_loop"]["draft_id"] == response.draft.id

      assert assistant_message.metadata["authoring_loop"]["revision"] == %{
               "source" => "authoring_template",
               "value" => 1
             }

      assert assistant_message.metadata["authoring_loop"]["revision_identity"] == %{
               "draft_id" => response.draft.id,
               "revision" => %{"source" => "authoring_template", "value" => 1}
             }

      refute Map.has_key?(intent["arguments"], "current_state")
      refute Map.has_key?(intent["arguments"], "draft_id")
      refute Map.has_key?(intent["arguments"], "revision")
    end
  end

  defp authoring_result(intent) do
    %Result{
      content: "Authoring intent",
      content_format: :markdown,
      public_metadata: %{},
      internal_metadata: %{"authoring_tool_intent" => intent}
    }
  end

  defp scoped_to(project) do
    %{name: "project_#{project.id}", payload: %{"scope" => %{"project_id" => project.id}}}
  end
end
