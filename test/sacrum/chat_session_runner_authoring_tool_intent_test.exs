defmodule Sacrum.ChatSessionRunnerAuthoringToolIntentTest do
  @moduledoc """
  End-to-end test for the producer side of the authoring chat loop with
  verifier gating disabled.

  Walks the full pipeline:

    intake -> load_messages -> invoke_inference -> verify_authoring
           -> append_assistant -> complete_session

  using a stubbed OpenRouter provider that returns a tool_call for
  `start_authoring`. The test asserts that exactly one Artifact is persisted
  and that the public chat events expected by the GUI contract are emitted.

  Covers Testing Criterion 3 (revise_authoring round trip via
  apply_inference_result) and Testing Criterion 11 (full pipeline end-to-end).
  """

  use Sacrum.DataCase

  import Sacrum.TestSupport.AuthoringFixtures

  alias Sacrum.Accounts.{ChatMessages, ChatSessions, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Users

  setup do
    original = Application.get_env(:sacrum, :authoring_verifier, [])
    Application.put_env(:sacrum, :authoring_verifier, enabled: false)
    on_exit(fn -> Application.put_env(:sacrum, :authoring_verifier, original) end)
    :ok
  end

  defmodule StubAuthoringStartProvider do
    @moduledoc false
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid), do: send(test_pid, {:stub_messages, messages})

      source_message_id = Keyword.get(opts, :source_message_id) || last_user_id(messages)

      {:ok,
       %Result{
         content: "Drafting your code factory workflow.",
         content_format: :markdown,
         public_metadata: %{"provider" => "openrouter-stub", "model" => "test-model"},
         internal_metadata: %{
           "provider" => "openrouter-stub",
           "model" => "test-model",
           "authoring_tool_intent" => %{
             "action" => "start_authoring",
             "run_kind" => "code_factory",
             "artifact_type" => "workflow_draft",
             "template_kind" => "starter_draft",
             "state_machine_entrypoint" => "start_code_factory_creation",
             "state_machine_id" => "code_factory_creation",
             "initial_state" => "collect_workflow_goal",
             "tool" => "workflow.create_from_recipe",
             "source_message_id" => source_message_id
           }
         }
       }}
    end

    defp last_user_id(messages) do
      messages
      |> Enum.filter(&(Map.get(&1, :role) == "user" or Map.get(&1, "role") == "user"))
      |> List.last()
      |> case do
        %{} = m -> Map.get(m, :id) || Map.get(m, "id")
        _ -> nil
      end
    end
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "authoring-e2e-#{suffix}@example.com",
        username: "authoring_e2e_#{suffix}",
        password: "password123"
      })

    user
  end

  defp setup_session do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "E2E Authoring Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})
    %{user: user, project: project, session: session}
  end

  defp assert_turn_completed(user, project, session, attempts \\ 50)

  defp assert_turn_completed(user, project, session, attempts) when attempts > 0 do
    {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)

    if Enum.any?(
         public_events,
         &(&1.event_type == "chat_session_runner.complete_session.completed")
       ) do
      :ok
    else
      Process.sleep(20)
      assert_turn_completed(user, project, session, attempts - 1)
    end
  end

  defp assert_turn_completed(user, project, session, 0) do
    {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)

    assert Enum.any?(
             public_events,
             &(&1.event_type == "chat_session_runner.complete_session.completed")
           )
  end

  defp assistant_message(messages), do: Enum.find(messages, &(&1.role == :assistant))

  defp authoring_drafts(user, project, session) do
    Sacrum.Accounts.Artifacts.list_for_subject(user.id, project.id, "chat_session", session.id)
    |> Enum.filter(&(&1.artifact_type == "authoring_draft"))
  end

  test "drives a tool_call through the full runner pipeline and persists exactly one Artifact" do
    %{user: user, project: project, session: session} = setup_session()

    insert_code_factory_template!(%{payload: %{"scope" => %{"project_id" => project.id}}})

    assert {:ok, user_message} =
             LiveChat.send_message_and_start_runner(
               user.id,
               project.id,
               session.id,
               %{
                 content: "Create a workflow factory for implementation and review",
                 client_message_id: "e2e-user-1"
               },
               start_opts: [
                 inference_opts: [
                   provider: StubAuthoringStartProvider,
                   test_pid: self()
                 ]
               ]
             )

    assert user_message.role == :user

    [{pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
    assert_turn_completed(user, project, session)

    assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
    assert Process.alive?(pid)
    on_exit(fn -> Sacrum.ChatSessionSupervisor.terminate_runner(session.id) end)

    {:ok, completed_session} = ChatSessions.get_session(user.id, project.id, session.id)
    assert completed_session.status == :running

    {:ok, messages} = ChatMessages.list_for_session(completed_session, include_private: true)

    assistant = assistant_message(messages)
    assert assistant != nil
    assert assistant.content == "Drafting your code factory workflow."

    drafts = authoring_drafts(user, project, session)
    assert [%Artifact{} = draft] = drafts
    assert draft.data["state_machine_id"] == "code_factory_creation"
    assert draft.data["current_state"] == "collect_workflow_goal"
    assert [%{"key" => "implementation"}] = draft.data["workflows"]

    {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)
    types = Enum.map(public_events, & &1.event_type)

    assert "chat_session_created" in types
    assert "chat_message_created" in types
    # session_updated is emitted when status flips; complete_session emits one
    assert Enum.any?(types, &(&1 == "chat_session_updated"))
  end

  test "revise_authoring tool_call from inference revises an existing draft end-to-end" do
    %{user: user, project: project, session: session} = setup_session()

    # Seed an existing draft so revise_authoring has something to update.
    insert_code_factory_template!(%{payload: %{"scope" => %{"project_id" => project.id}}})

    {:ok, first_user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "Create a workflow factory for implementation and review",
        client_message_id: "e2e-revise-user-1"
      })

    {:ok, _assistant} =
      LiveChat.run_inference(user.id, project.id, session.id,
        provider: StubAuthoringStartProvider,
        test_pid: self(),
        source_message_id: first_user_message.id
      )

    # Now drive a revise_authoring intent.
    {:ok, second_user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "Have review require tests and a concise risk note.",
        client_message_id: "e2e-revise-user-2"
      })

    revise_provider = fn ->
      defmodule ReviseProvider do
      end
    end

    # Inline reviser provider through AuthoringIntentProvider for revise side.
    alias Sacrum.TestSupport.AuthoringIntentProvider

    revise_intent =
      revise_authoring_intent("code_factory_creation", second_user_message.id, %{
        "tool" => "workflow.create_from_recipe",
        "current_state" => "refine_workflow_recipe",
        "feedback" => "Have review require tests and a concise risk note."
      })

    {:ok, _assistant2} =
      LiveChat.run_inference(user.id, project.id, session.id,
        provider: AuthoringIntentProvider,
        test_pid: self(),
        content: "Tightened the workflow.",
        authoring_tool_intent: revise_intent
      )

    drafts = authoring_drafts(user, project, session)
    assert [%Artifact{} = revised] = drafts
    assert revised.data["current_state"] == "refine_workflow_recipe"
    assert revised.data["revision"] == %{"source" => "chat_feedback", "value" => 2}

    assert "Have review require tests and a concise risk note." in Map.get(
             revised.data,
             "revision_notes",
             []
           )

    _ = revise_provider
  end
end
