defmodule Sacrum.Accounts.LiveChatRunnerStartTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.{LiveChat, Projects}
  alias Sacrum.Repo.Users

  defmodule RecordingSignalRunner do
    def start_or_cast_user_turn(chat_session_id, signal, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:user_turn_signal_cast, chat_session_id, signal})
      {:ok, self()}
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

    test "casts an accepted user-turn signal to the session runner instead of pre-persisting", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, %{id: message_id, client_message_id: "client-turn-1"}} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{
                   content: "Route this turn through the runner",
                   content_format: "markdown",
                   client_message_id: "client-turn-1",
                   metadata: %{
                     "origin" => "graphql",
                     "safe" => true,
                     "unsafe_pid" => self()
                   }
                 },
                 runner: RecordingSignalRunner,
                 start_opts: [test_pid: self()]
               )

      assert {:ok, _} = Ecto.UUID.cast(message_id)
      assert_receive {:user_turn_signal_cast, chat_session_id, signal}
      assert chat_session_id == session.id
      assert signal.type == Sacrum.ChatSessionRunner.Signals.user_turn()
      assert signal.source == Sacrum.ChatSessionRunner.Signals.source()

      assert signal.data == %{
               message_id: message_id,
               user_id: user.id,
               project_id: project.id,
               chat_session_id: session.id,
               content: "Route this turn through the runner",
               content_format: "markdown",
               client_message_id: "client-turn-1",
               metadata: %{"origin" => "graphql", "safe" => true},
               engine_session_ref: Sacrum.ChatSessionRunner.agent_id(session.id)
             }

      assert {:ok, []} = LiveChat.list_messages(user.id, project.id, session.id)
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
                 runner: RecordingSignalRunner,
                 start_opts: [test_pid: self()]
               )

      refute_receive {:user_turn_signal_cast, _chat_session_id, _signal}
    end

    test "still routes malformed turns to the runner so persistence is owned by turn acceptance",
         %{
           user: user,
           project: project,
           session: session
         } do
      assert {:ok, %{content: nil}} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{content: nil},
                 runner: RecordingSignalRunner,
                 start_opts: [test_pid: self()]
               )

      assert_receive {:user_turn_signal_cast, chat_session_id, signal}
      assert chat_session_id == session.id
      refute Map.has_key?(signal.data, :content)
      assert {:ok, []} = LiveChat.list_messages(user.id, project.id, session.id)
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
