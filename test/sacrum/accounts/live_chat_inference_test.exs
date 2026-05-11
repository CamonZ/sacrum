defmodule Sacrum.Accounts.LiveChatInferenceTest do
  use Sacrum.DataCase, async: false

  import ExUnit.CaptureLog
  import Sacrum.ChatInferenceCase

  alias Sacrum.Accounts.LiveChat
  alias Sacrum.Accounts.Projects
  alias Sacrum.Chat.InferenceEvents
  alias Sacrum.ChatInferenceCase.{BlockingProvider, ErrorProvider, FakeProvider}
  alias Sacrum.Repo.ChatEvents, as: ChatEventsRepo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users

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

  defp internal_events(session_id, event_type) do
    Repo.all(
      from event in ChatEvent,
        where: event.chat_session_id == ^session_id and event.event_type == ^event_type,
        order_by: [asc: event.inserted_at, asc: event.id]
    )
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
                event.event_type == ^InferenceEvents.event_type(:completed),
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

  describe "async inference from send_message/4" do
    setup [:setup_session]

    test "persists and broadcasts an assistant reply without awaiting the provider", %{
      user: user,
      project: project,
      session: session
    } do
      configure_async_inference(FakeProvider, test_pid: self())
      Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      assert {:ok, user_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Trigger async inference",
                 content_format: "markdown",
                 client_message_id: "client-async-1"
               })

      assert_receive {:fake_provider_messages,
                      [%{role: "user", content: "Trigger async inference"}]}

      assert_receive %Phoenix.Socket.Broadcast{
        event: "chat_message_created",
        payload: %{id: user_message_id, role: "user", content: "Trigger async inference"}
      }

      assert user_message_id == user_message.id

      assert_receive %Phoenix.Socket.Broadcast{
        event: "chat_message_created",
        payload: %{
          id: assistant_message_id,
          role: "assistant",
          content: "Persisted assistant output"
        }
      }

      assert {:ok, messages} = LiveChat.list_messages(user.id, project.id, session.id)
      assert Enum.map(messages, & &1.id) == [user_message.id, assistant_message_id]
      assert Enum.map(messages, & &1.role) == [:user, :assistant]

      assert {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)

      assert Enum.map(public_events, & &1.event_type) == [
               "chat_session_created",
               "chat_message_created",
               "chat_message_created"
             ]
    end

    test "records internal failure events without rolling back the user message", %{
      user: user,
      project: project,
      session: session
    } do
      configure_async_inference(ErrorProvider, test_pid: self())

      log =
        capture_log(fn ->
          assert {:ok, user_message} =
                   LiveChat.send_message(user.id, project.id, session.id, %{
                     content: "This provider will fail",
                     client_message_id: "client-error-1"
                   })

          assert_receive :error_provider_called

          assert [failed_event] =
                   eventually(fn ->
                     case internal_events(session.id, InferenceEvents.event_type(:failed)) do
                       [] -> nil
                       events -> events
                     end
                   end)

          assert failed_event.visibility == :internal
          assert failed_event.public_payload == %{}
          assert inspect(failed_event.internal_payload) =~ "rate_limited"
          refute inspect(failed_event.internal_payload) =~ "sk-provider-secret"
          refute inspect(failed_event.internal_payload) =~ "Bearer provider-secret"

          assert {:ok, messages} = LiveChat.list_messages(user.id, project.id, session.id)
          assert Enum.map(messages, & &1.id) == [user_message.id]
          assert Enum.map(messages, & &1.role) == [:user]

          assert {:ok, public_events} =
                   LiveChat.list_public_events(user.id, project.id, session.id)

          assert Enum.map(public_events, & &1.event_type) == [
                   "chat_session_created",
                   "chat_message_created"
                 ]
        end)

      assert log =~ "Chat inference failed for session #{session.id}"
    end

    test "does not schedule inference for cancelled sessions", %{
      user: user,
      project: project,
      session: session
    } do
      configure_async_inference(FakeProvider, test_pid: self())

      assert {:ok, cancelled} = LiveChat.cancel_session(user.id, project.id, session.id)
      assert cancelled.status == :cancelled

      assert {:ok, message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "No inference should run",
                 client_message_id: "client-cancelled-1"
               })

      assert message.role == :user
      refute_receive {:fake_provider_messages, _messages}, 200
      assert [] = internal_events(session.id, InferenceEvents.event_type(:failed))
    end

    test "serializes rapid triggers for the same session", %{
      user: user,
      project: project,
      session: session
    } do
      configure_async_inference(BlockingProvider, test_pid: self())

      assert {:ok, first_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "First message",
                 client_message_id: "client-serial-1"
               })

      assert_receive {:blocking_provider_started, first_provider_pid,
                      [%{role: "user", content: "First message"}]}

      assert {:ok, second_message} =
               LiveChat.send_message(user.id, project.id, session.id, %{
                 content: "Second message",
                 client_message_id: "client-serial-2"
               })

      refute_receive {:blocking_provider_started, _pid, _messages}, 100

      send(first_provider_pid, :release_provider)
      assert_receive {:blocking_provider_released, ^first_provider_pid}

      assert_receive {:blocking_provider_started, second_provider_pid, second_provider_messages}

      assert Enum.map(second_provider_messages, & &1.content) == [
               "First message",
               "Second message",
               "Blocking assistant output"
             ]

      send(second_provider_pid, :release_provider)
      assert_receive {:blocking_provider_released, ^second_provider_pid}

      assistant_messages =
        eventually(fn ->
          {:ok, messages} = LiveChat.list_messages(user.id, project.id, session.id)

          case Enum.filter(messages, &(&1.role == :assistant)) do
            [_, _] = assistants -> assistants
            _other -> nil
          end
        end)

      assert Enum.map(assistant_messages, & &1.content) == [
               "Blocking assistant output",
               "Blocking assistant output"
             ]

      assert {:ok, messages} = LiveChat.list_messages(user.id, project.id, session.id)

      assert Enum.map(messages, & &1.id) == [
               first_message.id,
               second_message.id,
               hd(assistant_messages).id,
               List.last(assistant_messages).id
             ]
    end
  end
end
