defmodule Sacrum.Accounts.LiveChatInferenceTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.LiveChat
  alias Sacrum.Accounts.Projects
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.ChatEvents, as: ChatEventsRepo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users

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

      assert {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)
      public_event_types = Enum.map(public_events, & &1.event_type)

      assert public_event_types == [
               "chat_session_created",
               "chat_message_created",
               "chat_message_created"
             ]

      refute Enum.any?(public_events, &(&1.event_type == "chat_inference.completed"))
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
  end
end
