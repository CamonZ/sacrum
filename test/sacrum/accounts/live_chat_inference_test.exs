defmodule Sacrum.Accounts.LiveChatInferenceTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.ChatEvents, as: ChatEventsRepo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users
  alias Sacrum.TestSupport.AuthoringIntentProvider

  defmodule FakeProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:fake_provider_messages, messages})
      end

      {:ok,
       %Result{
         content: "Persisted assistant output",
         content_format: :markdown,
         public_metadata: %{
           "provider" => "fake",
           "model" => "fake-model",
           "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
         },
         internal_metadata: %{
           "trace_id" => "trace-1",
           "reasoning" => %{
             "text" => "Internal model reasoning",
             "details" => [
               %{
                 "type" => "reasoning.text",
                 "text" => "Internal model reasoning",
                 "signature" => "opaque-provider-signature"
               }
             ],
             "tokens" => 9
           },
           "raw_provider_payload" => %{
             "id" => "provider-response-1",
             "headers" => %{
               "authorization" => "Bearer raw-secret",
               "x-api-key" => "sk-header-secret",
               "content-type" => "application/json"
             },
             "usage" => %{"total_tokens" => 12}
           },
           "api_key" => "sk-internal-secret"
         }
       }}
    end
  end

  defp create_user(prefix \\ "live-chat-inference") do
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

  defp create_project(user, name \\ "Inference Project") do
    {:ok, project} = Projects.insert(user.id, %{name: name})
    project
  end

  defp setup_session(_context) do
    user = create_user()
    project = create_project(user)
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

    %{user: user, project: project, session: session}
  end

  describe "run_inference/4" do
    setup [:setup_session]

    test "persists public assistant output and internal-only provider metadata", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, _user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "What should we do next?",
                 client_message_id: "client-1"
               })

      assert {:ok, assistant_message} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: FakeProvider,
                 test_pid: self()
               )

      assert_receive {:fake_provider_messages,
                      [%{role: "user", content: "What should we do next?"}]}

      assert assistant_message.role == :assistant
      assert assistant_message.content == "Persisted assistant output"
      assert assistant_message.content_format == :markdown

      assert assistant_message.metadata == %{
               "provider" => "fake",
               "model" => "fake-model",
               "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
             }

      refute Map.has_key?(assistant_message.metadata, "reasoning")

      assert {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)
      public_event_types = Enum.map(public_events, & &1.event_type)

      assert public_event_types == [
               "chat_session_created",
               "chat_message_created",
               "chat_message_created"
             ]

      refute Enum.any?(public_events, &(&1.event_type == "chat_inference.completed"))
      refute inspect(public_events) =~ "Internal model reasoning"
      refute inspect(public_events) =~ "raw_provider_payload"
      refute inspect(public_events) =~ "raw-secret"

      internal_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^session.id and
                event.event_type == "chat_inference.completed",
            order_by: [asc: event.inserted_at, asc: event.id]
        )

      assert [internal_event] = internal_events
      assert internal_event.visibility == :internal
      assert internal_event.public_payload == %{}

      assert %{
               "assistant_message_id" => assistant_message_id,
               "metadata" => %{
                 "trace_id" => "trace-1",
                 "reasoning" => %{
                   "text" => "Internal model reasoning",
                   "details" => [
                     %{
                       "type" => "reasoning.text",
                       "text" => "Internal model reasoning",
                       "signature" => "opaque-provider-signature"
                     }
                   ],
                   "tokens" => 9
                 },
                 "raw_provider_payload" => %{
                   "id" => "provider-response-1",
                   "headers" => %{"content-type" => "application/json"},
                   "usage" => %{"total_tokens" => 12}
                 }
               }
             } = internal_event.internal_payload

      assert assistant_message_id == assistant_message.id
      refute inspect(assistant_message.metadata) =~ "sk-"
      refute inspect(internal_event.internal_payload) =~ "sk-internal-secret"
      refute inspect(internal_event.internal_payload) =~ "sk-header-secret"
      refute inspect(internal_event.internal_payload) =~ "raw-secret"

      assert {:ok, projected_internal} = ChatEventsRepo.get(internal_event.id)
      assert projected_internal.internal_payload == internal_event.internal_payload
    end

    test "uses template-backed code-factory tool intents to persist and revise one structured draft",
         %{
           user: user,
           project: project,
           session: session
         } do
      insert_code_factory_template!(scoped_to(project))

      assert {:ok, first_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Create a workflow factory for implementation and review",
                 client_message_id: "client-code-factory-1"
               })

      assert {:ok, _assistant_message} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content:
                   "I drafted a minimal implementation workflow. What should review check?",
                 authoring_tool_intent: code_factory_start_intent(first_user_message.id)
               )

      assert_receive {:authoring_provider_messages, _messages}

      assert [draft] = authoring_drafts_for_session(user, project, session)
      assert draft.data["state_machine_id"] == "code_factory_creation"
      assert draft.data["current_state"] == "collect_workflow_goal"
      assert draft.data["revision"] == %{"source" => "authoring_template", "value" => 1}
      assert [%{"key" => "implementation"}] = draft.data["workflows"]
      assert [%{"target_step" => "verification.review"}] = draft.data["transitions"]

      refute Map.has_key?(draft.data, "starter_shape")

      assert {:ok, second_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Have review require tests and a concise risk note.",
                 client_message_id: "client-code-factory-2"
               })

      assert {:ok, _assistant_message} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content: "Updated the same draft with test and risk expectations.",
                 authoring_tool_intent:
                   revise_authoring_intent("code_factory_creation", second_user_message.id, %{
                     "tool" => "workflow.create_from_recipe",
                     "current_state" => "refine_workflow_recipe",
                     "feedback" => "Have review require tests and a concise risk note."
                   })
               )

      assert_receive {:authoring_provider_messages, _messages}

      assert [revised_draft] = authoring_drafts_for_session(user, project, session)
      assert revised_draft.id == draft.id
      assert revised_draft.data["current_state"] == "refine_workflow_recipe"
      assert revised_draft.data["revision"] == %{"source" => "chat_feedback", "value" => 2}
      assert revised_draft.data["workflows"] == draft.data["workflows"]

      assert "Have review require tests and a concise risk note." in Map.get(
               revised_draft.data,
               "revision_notes",
               []
             )
    end

    test "returns an error without persisting a partial draft when code-factory template is missing",
         %{
           user: user,
           project: project,
           session: session
         } do
      assert {:ok, first_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Create a workflow factory for implementation and review",
                 client_message_id: "client-code-factory-missing-template"
               })

      assert {:error, :not_found} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content: "I tried to draft a workflow recipe.",
                 authoring_tool_intent:
                   code_factory_start_intent(first_user_message.id, %{
                     "state_machine_entrypoint" => "missing_code_factory_template"
                   })
               )

      assert_receive {:authoring_provider_messages, _messages}
      assert [] = authoring_drafts_for_session(user, project, session)
    end

    test "returns an error without persisting a partial draft when rendered authoring payload is invalid",
         %{
           user: user,
           project: project,
           session: session
         } do
      insert_code_factory_template!(scoped_to(project))

      assert {:ok, first_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Create a workflow factory for implementation and review",
                 client_message_id: "client-code-factory-malformed-render"
               })

      assert {:error, {:missing_option, :initial_state}} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content: "I tried to draft a workflow recipe.",
                 authoring_tool_intent:
                   code_factory_start_intent(first_user_message.id, %{
                     "initial_state" => nil
                   })
               )

      assert_receive {:authoring_provider_messages, _messages}
      assert [] = authoring_drafts_for_session(user, project, session)
    end

    test "starts investigation-session authoring from an app-owned starter without exposing raw templates",
         %{
           user: user,
           project: project,
           session: session
         } do
      insert_investigation_session_template!(scoped_to(project))

      assert {:ok, first_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Investigate why task runs sometimes stop updating the GUI",
                 client_message_id: "client-investigation-1"
               })

      assert {:ok, assistant_message} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content:
                   "I started an investigation draft. Which update path should we inspect first?",
                 authoring_tool_intent: investigation_start_intent(first_user_message.id)
               )

      assert_receive {:authoring_provider_messages, _messages}

      assert assistant_message.metadata == %{
               "model" => "authoring-intent-model",
               "provider" => "fake"
             }

      assert [draft] = authoring_drafts_for_session(user, project, session)
      assert draft.artifact_type == "authoring_draft"
      assert draft.data["state_machine_id"] == "investigation_session_authoring"
      assert draft.data["state_machine_entrypoint"] == "start_investigation_session_authoring"
      assert draft.data["current_state"] == "collect_investigation_scope"
      assert draft.data["revision"] == %{"source" => "authoring_template", "value" => 1}
      assert draft.data["source_chat"]["source_message_id"] == first_user_message.id
      assert draft.data["apply_target"] == "investigation_session"

      assert %{
               "assumptions" => assumptions,
               "open_questions" => open_questions,
               "proposed_approach" => proposed_approach,
               "candidate_work_units" => candidate_work_units,
               "apply_targets" => apply_targets,
               "validation_expectations" => validation_expectations
             } = draft.data

      assert is_list(assumptions) and assumptions != []
      assert is_list(open_questions) and open_questions != []
      assert is_list(proposed_approach) and proposed_approach != []
      assert is_list(candidate_work_units) and candidate_work_units != []
      assert is_list(apply_targets) and apply_targets != []
      assert is_list(validation_expectations) and validation_expectations != []

      refute Map.has_key?(draft.data, "starter_shape")
    end

    test "enters discovery mode for vague feature requests and revises the same structured draft",
         %{
           user: user,
           project: project,
           session: session
         } do
      insert_feature_exploration_template!(scoped_to(project))

      assert {:ok, first_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Build the dashboard thing we discussed",
                 client_message_id: "client-feature-1"
               })

      assert {:ok, _assistant_message} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content: "Which dashboard user path should we support first?",
                 authoring_tool_intent:
                   feature_start_intent(first_user_message.id, %{
                     "open_questions" => ["Which dashboard user path should we support first?"]
                   })
               )

      assert_receive {:authoring_provider_messages, _messages}

      assert [draft] = authoring_drafts_for_session(user, project, session)
      assert draft.data["state_machine_id"] == "feature_exploration"
      assert draft.data["current_state"] == "collect_feature_scope"

      assert draft.data["open_questions"] == [
               "Which dashboard user path should we support first?"
             ]

      assert {:ok, second_user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Start with admins reviewing failed imports.",
                 client_message_id: "client-feature-2"
               })

      assert {:ok, _assistant_message} =
               LiveChat.run_inference(user.id, project.id, session.id,
                 provider: AuthoringIntentProvider,
                 test_pid: self(),
                 content: "I updated the draft around failed import review.",
                 authoring_tool_intent:
                   revise_authoring_intent("feature_exploration", second_user_message.id, %{
                     "current_state" => "refine_scope",
                     "candidate_work_units" => [
                       %{
                         "title" => "Admin failed import review",
                         "level" => "ticket",
                         "desired_behavior" =>
                           "Admins can review failed imports from the dashboard."
                       }
                     ]
                   })
               )

      assert_receive {:authoring_provider_messages, _messages}

      assert [revised_draft] = authoring_drafts_for_session(user, project, session)
      assert revised_draft.id == draft.id
      assert revised_draft.data["current_state"] == "refine_scope"

      assert List.last(revised_draft.data["candidate_work_units"]) == %{
               "title" => "Admin failed import review",
               "level" => "ticket",
               "desired_behavior" => "Admins can review failed imports from the dashboard."
             }
    end
  end

  defp scoped_to(project) do
    %{name: "project_#{project.id}", payload: %{"scope" => %{"project_id" => project.id}}}
  end
end
