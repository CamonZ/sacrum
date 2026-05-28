defmodule Sacrum.Accounts.LiveChatRunnerStartTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.{LiveChat, Projects, Tasks}
  alias Sacrum.Chat.Inference.Result

  alias Sacrum.ChatSessionRunner.Actions.{
    AcceptUserTurn,
    AppendAssistant,
    CompleteSession,
    InvokeInference,
    LoadMessages,
    VerifyAuthoringIntent
  }

  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatMessage, StepExecution, TaskRun}
  alias Sacrum.Repo.Users

  defmodule RecordingSignalRunner do
    def start_or_cast_user_turn(chat_session_id, signal, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:user_turn_signal_cast, chat_session_id, signal})
      {:ok, self()}
    end
  end

  defmodule PumpingAcceptanceRunner do
    def start_or_cast_user_turn(chat_session_id, signal, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:user_turn_signal_cast, chat_session_id, signal})

      signal.data
      |> Map.put(:inference_opts, Keyword.get(opts, :inference_opts, []))
      |> run_signal(signal.type, test_pid)

      {:ok, self()}
    end

    defp run_signal(data, signal_type, test_pid) do
      send(test_pid, {:runner_action_started, signal_type})

      case action_for(signal_type).run(data, %{}) do
        {:ok, result, directives} ->
          send(test_pid, {:runner_action_result, signal_type, result})
          Enum.each(directives, &run_signal(&1.signal.data, &1.signal.type, test_pid))

        {:ok, result} ->
          send(test_pid, {:runner_action_result, signal_type, result})
      end
    end

    defp action_for(type) do
      cond do
        type == Signals.user_turn() -> AcceptUserTurn
        type == Signals.load_messages() -> LoadMessages
        type == Signals.invoke_inference() -> InvokeInference
        type == Signals.verify_authoring() -> VerifyAuthoringIntent
        type == Signals.append_assistant() -> AppendAssistant
        type == Signals.complete_session() -> CompleteSession
        true -> raise ArgumentError, "unexpected signal type: #{inspect(type)}"
      end
    end
  end

  defmodule ForbiddenInferenceProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      opts
      |> Keyword.fetch!(:test_pid)
      |> send({:forbidden_inference_called, messages})

      action = "show_task"
      arguments = %{"task_ref" => Keyword.fetch!(opts, :task_id), "include_sections" => true}

      {:ok,
       %Result{
         content: "should not run",
         content_format: :markdown,
         public_metadata: %{"provider" => "forbidden", "model" => "forbidden"},
         internal_metadata: %{
           "direct_tracker_operation" => %{
             "action" => action,
             "arguments" => arguments,
             "assistant_content" => "",
             "provider_tool_call" =>
               Sacrum.Chat.DirectTrackerOperationTools.provider_tool_call(
                 action,
                 arguments,
                 "call_forbidden_tracker"
               )
           }
         }
       }}
    end
  end

  defmodule ForbiddenTrackerExecutor do
    def execute(operation) do
      :sacrum
      |> Application.fetch_env!(:direct_tracker_operation_executor_test_pid)
      |> send({:tracker_operation_executed, operation})

      {:ok, %{"result" => "should not run"}}
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

    test "does not invoke model or tracker work when accepted-turn persistence fails", %{
      user: user,
      project: project,
      session: session
    } do
      use_forbidden_tracker_executor()

      {:ok, existing_message} =
        LiveChat.send_message(user.id, project.id, session.id, %{
          content: "already persisted",
          client_message_id: "duplicate-user-turn"
        })

      {:ok, task} =
        Tasks.insert(user.id, project.id, %{
          title: "Forbidden direct tracker target"
        })

      assert {:ok, %{id: rejected_message_id, client_message_id: "duplicate-user-turn"}} =
               LiveChat.send_message_and_start_runner(
                 user.id,
                 project.id,
                 session.id,
                 %{
                   content: "this turn should not persist",
                   client_message_id: "duplicate-user-turn"
                 },
                 runner: PumpingAcceptanceRunner,
                 start_opts: [
                   test_pid: self(),
                   inference_opts: [
                     provider: ForbiddenInferenceProvider,
                     test_pid: self(),
                     task_id: task.id
                   ]
                 ]
               )

      session_id = session.id

      assert_receive {:user_turn_signal_cast, ^session_id, signal}
      assert signal.type == Signals.user_turn()
      assert signal.data.message_id == rejected_message_id

      assert_receive {:runner_action_started, type}
      assert type == Signals.user_turn()

      assert_receive {:runner_action_result, ^type,
                      %{
                        step: :accept_user_turn,
                        status: :failed,
                        chat_session_id: chat_session_id
                      }}

      assert chat_session_id == session.id
      refute_received {:runner_action_started, _downstream}
      refute_receive {:forbidden_inference_called, _messages}
      refute_received {:tracker_operation_executed, _operation}

      assert {:ok, messages} = LiveChat.list_messages(user.id, project.id, session.id)
      assert Enum.map(messages, & &1.id) == [existing_message.id]

      refute Repo.exists?(
               from(message in ChatMessage,
                 where:
                   message.chat_session_id == ^session.id and message.id == ^rejected_message_id
               )
             )

      assert Repo.aggregate(from(run in TaskRun, where: run.project_id == ^project.id), :count) ==
               0

      assert Repo.aggregate(
               from(execution in StepExecution, where: execution.project_id == ^project.id),
               :count
             ) == 0
    end
  end

  defp use_forbidden_tracker_executor do
    original_executor = Application.fetch_env(:sacrum, :direct_tracker_operation_executor)

    Application.put_env(:sacrum, :direct_tracker_operation_executor, ForbiddenTrackerExecutor)
    Application.put_env(:sacrum, :direct_tracker_operation_executor_test_pid, self())

    on_exit(fn ->
      case original_executor do
        {:ok, executor} ->
          Application.put_env(:sacrum, :direct_tracker_operation_executor, executor)

        :error ->
          Application.delete_env(:sacrum, :direct_tracker_operation_executor)
      end

      Application.delete_env(:sacrum, :direct_tracker_operation_executor_test_pid)
    end)
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
