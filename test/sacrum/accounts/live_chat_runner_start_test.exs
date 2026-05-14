defmodule Sacrum.Accounts.LiveChatRunnerStartTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.{ChatSessions, LiveChat, Projects}
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatMessage
  alias Sacrum.Repo.Users

  defmodule RecordingRunner do
    def start_runner(chat_session_id, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      send(test_pid, {
        :runner_started,
        chat_session_id,
        Repo.in_transaction?(),
        Repo.aggregate(ChatMessage, :count)
      })

      {:ok, self()}
    end
  end

  defmodule AlreadyStartedRunner do
    def start_runner(_chat_session_id, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :runner_start_attempted)
      {:error, {:already_started, self()}}
    end
  end

  defmodule FailingRunner do
    def start_runner(_chat_session_id, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, :runner_start_attempted)
      {:error, :runner_unavailable}
    end
  end

  defp setup_session(_context) do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Runner Start Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})
    %{user: user, project: project, session: session}
  end

  describe "send_message_and_start_runner/5" do
    setup [:setup_session]

    test "starts the runner only after the user message transaction commits", %{
      user: user,
      project: project,
      session: session
    } do
      session_id = session.id

      assert {:ok, message} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{content: "Start the assistant turn"},
                 runner: RecordingRunner,
                 start_opts: [test_pid: self()]
               )

      assert message.role == :user
      assert_receive {:runner_started, ^session_id, false, 1}
    end

    test "does not start the runner when the session cannot be loaded", %{
      user: user,
      project: project
    } do
      assert {:error, :not_found} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 Ecto.UUID.generate(),
                 %{content: "This session does not exist"},
                 runner: RecordingRunner,
                 start_opts: [test_pid: self()]
               )

      refute_receive {:runner_started, _chat_session_id, _in_transaction?, _message_count}
    end

    test "does not start the runner when message persistence fails", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:error, %Ecto.Changeset{}} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{content: nil},
                 runner: RecordingRunner,
                 start_opts: [test_pid: self()]
               )

      refute_receive {:runner_started, _chat_session_id, _in_transaction?, _message_count}
    end

    test "treats duplicate runner starts as an in-flight assistant turn", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, message} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{content: "Duplicate starts are okay"},
                 runner: AlreadyStartedRunner,
                 start_opts: [test_pid: self()]
               )

      assert_receive :runner_start_attempted
      assert message.role == :user

      {:ok, reloaded_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert reloaded_session.status == :queued
    end

    test "surfaces runner start failures through committed chat events", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, message} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{content: "Surface the failure"},
                 runner: FailingRunner,
                 start_opts: [test_pid: self()]
               )

      assert_receive :runner_start_attempted
      assert message.role == :user

      {:ok, failed_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert failed_session.status == :failed

      assert {:ok, public_events} = LiveChat.list_public_events(user.id, project.id, session.id)

      assert Enum.map(public_events, & &1.event_type) == [
               PublicEvents.event_type(:session_created),
               PublicEvents.event_type(:message_created),
               PublicEvents.event_type(:session_updated),
               "chat_session_runner.failed.completed"
             ]

      failure_event = List.last(public_events)

      assert failure_event.public_payload == %{
               "chat_session_id" => session.id,
               "step" => "failed",
               "turn_message_id" => message.id
             }
    end
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "live-chat-runner-start-#{suffix}@example.com",
        username: "live_chat_runner_start_#{suffix}",
        password: "password123"
      })

    user
  end
end
