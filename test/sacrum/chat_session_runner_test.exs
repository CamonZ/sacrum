defmodule Sacrum.ChatSessionRunnerTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.{ChatMessages, ChatSessions, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Schemas.{ChatEvent, StepExecution, Task, TaskRun}
  alias Sacrum.Repo.Users
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  @assistant_client_message_id_prefix "chat_session_runner:assistant:v1"
  @runner_steps ~w(
    chat_session_runner.intake.completed
    chat_session_runner.load_messages.completed
    chat_session_runner.invoke_inference.completed
    chat_session_runner.append_assistant.completed
    chat_session_runner.complete_session.completed
  )

  defmodule BlockingProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:blocking_provider_started, self(), messages})

      receive do
        {:release_blocking_provider, content} ->
          {:ok,
           %Result{
             content: content,
             content_format: :markdown,
             public_metadata: %{"provider" => "fake", "model" => "runner-test"},
             internal_metadata: %{"trace_id" => "runner-trace"}
           }}
      after
        5_000 ->
          {:error, :blocking_provider_timeout}
      end
    end
  end

  defmodule UnexpectedProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:unexpected_provider_called, messages})
      end

      {:ok, %Result{content: "Unexpected duplicate output"}}
    end
  end

  defmodule DirectTrackerProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:direct_tracker_provider_called, messages})

      if Enum.any?(messages, &(Map.get(&1, :role) in ["tool", :tool])) do
        {:ok,
         %Result{
           content: "I read the tracker item and can continue from the tool result.",
           content_format: :markdown,
           public_metadata: %{"provider" => "fake", "model" => "direct-tracker-test"},
           internal_metadata: %{"trace_id" => "direct-tracker-final"}
         }}
      else
        {:ok,
         %Result{
           content: "I'll check the tracker item.",
           content_format: :markdown,
           public_metadata: %{"provider" => "fake", "model" => "direct-tracker-test"},
           internal_metadata: %{
             "trace_id" => "direct-tracker-tool-call",
             "direct_tracker_operation" => Keyword.fetch!(opts, :direct_tracker_operation)
           }
         }}
      end
    end
  end

  defmodule FailingDirectTrackerExecutor do
    def execute(operation) do
      {:error,
       {:tracker_executor_failed,
        %{
          operation: operation,
          provider_request: %{"messages" => ["raw prompt"], "api_key" => "sk-test-secret"},
          stacktrace: ["/tmp/sacrum/lib/private_runner.ex:42"]
        }}}
    end
  end

  defp create_user(prefix \\ "chat-session-runner") do
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

  defp create_project(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Runner Project"})
    project
  end

  defp create_session_with_user_message(_context) do
    user = create_user()
    project = create_project(user)
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

    {:ok, user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "Plan the next step",
        client_message_id: "client-runner-user"
      })

    %{user: user, project: project, session: session, user_message: user_message}
  end

  describe "supervised chat session process" do
    setup [:create_session_with_user_message]

    test "runs one Jido-backed chat loop through Sacrum inference and completes", %{
      user: user,
      project: project,
      session: session,
      user_message: user_message
    } do
      assistant_client_message_id = "#{@assistant_client_message_id_prefix}:#{user_message.id}"

      assert {:ok, pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      assert_receive {:blocking_provider_started, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)

      assert {:error, {:already_started, ^pid}} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      send(provider_pid, {:release_blocking_provider, "Supervised assistant output"})
      assert_event_persisted(session.id, "chat_session_runner.complete_session.completed")

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert Process.alive?(pid)
      on_exit(fn -> Sacrum.ChatSessionSupervisor.terminate_runner(session.id) end)

      {:ok, completed_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert completed_session.status == :running
      assert completed_session.engine_kind == "jido"
      assert completed_session.engine_session_ref == Sacrum.ChatSessionRunner.agent_id(session.id)
      assert %DateTime{} = completed_session.started_at
      refute completed_session.ended_at

      {:ok, messages} = ChatMessages.list_for_session(completed_session, include_private: true)

      assert Enum.map(messages, &{&1.role, &1.client_message_id, &1.content}) == [
               {:user, "client-runner-user", "Plan the next step"},
               {:status, "chat_session_runner:status:intake:v1:#{user_message.id}",
                "Chat session started."},
               {:assistant, assistant_client_message_id, "Supervised assistant output"},
               {:status, "chat_session_runner:status:complete_session:v1:#{user_message.id}",
                "Chat turn completed."}
             ]

      assistant = Enum.find(messages, &(&1.role == :assistant))
      assert assistant.metadata == %{"provider" => "fake", "model" => "runner-test"}

      assert_runner_checkpoints(session.id)

      assert Repo.aggregate(from(task in Task, where: task.project_id == ^project.id), :count) ==
               0

      assert Repo.aggregate(
               from(task_run in TaskRun, where: task_run.project_id == ^project.id),
               :count
             ) ==
               0

      assert Repo.aggregate(
               from(execution in StepExecution, where: execution.project_id == ^project.id),
               :count
             ) == 0
    end

    test "does not overwrite cancellation while inference is in flight", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      assert_receive {:blocking_provider_started, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      assert {:ok, cancelled_session} = LiveChat.cancel_session(user.id, project.id, session.id)
      assert cancelled_session.status == :cancelled

      assert_runner_stopped(pid, session.id)
      send(provider_pid, {:release_blocking_provider, "Output after cancellation"})

      {:ok, reloaded_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert reloaded_session.status == :cancelled

      {:ok, messages} = ChatMessages.list_for_session(reloaded_session, include_private: true)

      refute Enum.any?(messages, fn message ->
               message.role == :assistant and message.content == "Output after cancellation"
             end)
    end

    test "keeps the registered runner alive and reusable after normal turn completion", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      on_exit(fn -> Sacrum.ChatSessionSupervisor.terminate_runner(session.id) end)

      assert_receive {:blocking_provider_started, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      send(provider_pid, {:release_blocking_provider, "First turn answer"})
      assert_event_persisted(session.id, "chat_session_runner.complete_session.completed")

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert Process.alive?(pid)

      second_message_id = Ecto.UUID.generate()

      second_turn_signal =
        Sacrum.ChatSessionRunner.Actions.user_turn_signal(%{
          message_id: second_message_id,
          user_id: user.id,
          project_id: project.id,
          chat_session_id: session.id,
          content: "Second turn should use the same runner",
          content_format: "markdown",
          client_message_id: "client-runner-user-2",
          metadata: %{},
          engine_session_ref: Sacrum.ChatSessionRunner.agent_id(session.id),
          inference_opts: [provider: BlockingProvider, test_pid: self()]
        })

      assert {:ok, ^pid} =
               Sacrum.ChatSessionSupervisor.start_or_cast_user_turn(
                 session.id,
                 second_turn_signal,
                 []
               )

      assert_receive {:blocking_provider_started, second_provider_pid, second_messages},
                     1_000

      assert Enum.any?(
               second_messages,
               &(&1.role == "user" and &1.content == "Second turn should use the same runner")
             )

      send(second_provider_pid, {:release_blocking_provider, "Second turn answer"})

      assert_event_persisted(
        session.id,
        "chat_session_runner.complete_session.completed",
        turn_message_id: second_message_id
      )
    end

    test "direct tracker turn emits ordered activity and only intended transcript messages", %{
      user: user,
      project: project,
      session: session,
      user_message: user_message
    } do
      operation =
        ChatSessionRunnerFixtures.show_task_directive(
          %{user: user, project: project, session: session},
          "tool-call-activity-1"
        )

      assert {:ok, pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [
                   provider: DirectTrackerProvider,
                   test_pid: self(),
                   direct_tracker_operation: operation
                 ]
               )

      on_exit(fn -> Sacrum.ChatSessionSupervisor.terminate_runner(session.id) end)

      assert_receive {:direct_tracker_provider_called,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      assert_receive {:direct_tracker_provider_called, continuation_messages}, 1_000
      assert Enum.any?(continuation_messages, &(Map.get(&1, :role) in ["tool", :tool]))

      assert_event_persisted(
        session.id,
        "chat_session_runner.complete_session.completed",
        turn_message_id: user_message.id
      )

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)

      assert_public_activity_phases(user, project, session, user_message.id, [
        "accepted_turn",
        "invoking_model",
        "executing_tool",
        "applying_tracker_operation",
        "continuing_after_tool_result",
        "invoking_model",
        "composing_answer",
        "completed"
      ])

      {:ok, messages} = ChatMessages.list_for_session(session, include_private: true)

      assert Enum.map(messages, &{&1.role, &1.content}) == [
               {:user, "Plan the next step"},
               {:status, "Chat session started."},
               {:assistant, "I read the tracker item and can continue from the tool result."},
               {:status, "Chat turn completed."}
             ]
    end

    test "direct tracker failure emits sanitized public failed activity without transcript leakage",
         %{
           user: user,
           project: project,
           session: session,
           user_message: user_message
         } do
      operation =
        ChatSessionRunnerFixtures.show_task_directive(
          %{user: user, project: project, session: session},
          "tool-call-failure-1"
        )

      original_executor = Application.get_env(:sacrum, :direct_tracker_operation_executor)

      Application.put_env(
        :sacrum,
        :direct_tracker_operation_executor,
        FailingDirectTrackerExecutor
      )

      on_exit(fn ->
        if is_nil(original_executor) do
          Application.delete_env(:sacrum, :direct_tracker_operation_executor)
        else
          Application.put_env(:sacrum, :direct_tracker_operation_executor, original_executor)
        end

        Sacrum.ChatSessionSupervisor.terminate_runner(session.id)
      end)

      assert {:ok, _pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [
                   provider: DirectTrackerProvider,
                   test_pid: self(),
                   direct_tracker_operation: operation
                 ]
               )

      assert_receive {:direct_tracker_provider_called,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      assert_event_persisted(session.id, "chat_session_runner.failed.completed")

      assert {:ok, events} = LiveChat.list_public_events(user.id, project.id, session.id)

      failed_activity =
        Enum.find(events, fn event ->
          event.event_type == "chat_runner_activity.failed" and
            event.public_payload["turn_message_id"] == user_message.id
        end)

      refute is_nil(failed_activity)
      assert failed_activity.visibility == :public
      assert failed_activity.public_payload["phase"] == "failed"
      assert failed_activity.public_payload["status"] == "failed"

      failed_payload_json = Jason.encode!(failed_activity.public_payload)
      refute failed_payload_json =~ "tracker_executor_failed"
      refute failed_payload_json =~ "raw prompt"
      refute failed_payload_json =~ "api_key"
      refute failed_payload_json =~ "sk-test-secret"
      refute failed_payload_json =~ "/tmp/sacrum"
      refute failed_payload_json =~ "show_task"
      refute failed_payload_json =~ "tool-call-failure-1"

      {:ok, messages} = ChatMessages.list_for_session(session, include_private: true)

      assert Enum.map(messages, &{&1.role, &1.content}) == [
               {:user, "Plan the next step"},
               {:status, "Chat session started."}
             ]
    end

    test "cancelling an idle runner stops it and leaves the session cancelled", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      assert_receive {:blocking_provider_started, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      send(provider_pid, {:release_blocking_provider, "Answer before cancellation"})
      assert_event_persisted(session.id, "chat_session_runner.complete_session.completed")

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert Process.alive?(pid)

      assert {:ok, cancelled_session} = LiveChat.cancel_session(user.id, project.id, session.id)
      assert cancelled_session.status == :cancelled
      assert_runner_stopped(pid, session.id)

      {:ok, reloaded_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert reloaded_session.status == :cancelled
    end

    test "deleting an idle runner stops and unregisters it", %{
      user: user,
      project: project,
      session: session
    } do
      assert {:ok, pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      assert_receive {:blocking_provider_started, provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      send(provider_pid, {:release_blocking_provider, "Answer before deletion"})
      assert_event_persisted(session.id, "chat_session_runner.complete_session.completed")

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert Process.alive?(pid)

      assert {:ok, deleted_session} = LiveChat.delete_session(user.id, project.id, session.id)
      assert deleted_session.id == session.id
      assert_runner_stopped(pid, session.id)
      assert {:error, :not_found} = ChatSessions.get_session(user.id, project.id, session.id)
    end
  end

  describe "persistence and restart idempotency" do
    setup [:create_session_with_user_message]

    test "resumes from existing assistant output without duplicating it", %{
      user: user,
      project: project,
      session: session,
      user_message: user_message
    } do
      assistant_client_message_id = "#{@assistant_client_message_id_prefix}:#{user_message.id}"

      {:ok, running_session} =
        ChatSessions.transition_status(user.id, project.id, session.id, :running)

      {:ok, assistant_before_restart} =
        ChatMessages.append_to_session(running_session, %{
          role: :assistant,
          content: "Recovered assistant output",
          content_format: :markdown,
          client_message_id: assistant_client_message_id,
          metadata: %{"provider" => "fake", "model" => "precrash"}
        })

      resume_pid =
        start_runner_until_turn_completed(session.id,
          inference_opts: [provider: UnexpectedProvider, test_pid: self()]
        )

      {:ok, completed_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert completed_session.status == :running
      assert completed_session.engine_kind == "jido"
      assert completed_session.engine_session_ref == Sacrum.ChatSessionRunner.agent_id(session.id)
      assert [{^resume_pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert is_pid(resume_pid)
      refute_receive {:unexpected_provider_called, _messages}

      assert :ok = Sacrum.ChatSessionSupervisor.terminate_runner(session.id)
      assert_registry_empty(session.id)

      _noop_pid =
        start_runner_until_turn_completed(session.id,
          inference_opts: [provider: UnexpectedProvider, test_pid: self()]
        )

      on_exit(fn -> Sacrum.ChatSessionSupervisor.terminate_runner(session.id) end)
      refute_receive {:unexpected_provider_called, _messages}

      {:ok, messages} = ChatMessages.list_for_session(completed_session, include_private: true)
      assistant_messages = Enum.filter(messages, &(&1.role == :assistant))

      assert Enum.map(assistant_messages, &{&1.id, &1.client_message_id, &1.content}) == [
               {assistant_before_restart.id, assistant_client_message_id,
                "Recovered assistant output"}
             ]

      assert_runner_checkpoints(session.id,
        skipped_steps: ["chat_session_runner.invoke_inference.completed"]
      )

      message_created_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^session.id and
                event.event_type == "chat_message_created" and
                event.visibility == :public,
            order_by: [asc: event.inserted_at, asc: event.id]
        )

      assistant_event_payloads =
        Enum.filter(message_created_events, fn event ->
          event.public_payload["id"] == assistant_before_restart.id
        end)

      assert [%ChatEvent{}] = assistant_event_payloads

      inference_completed_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^session.id and
                event.event_type == "chat_inference.completed" and
                event.visibility == :internal
        )

      assert [inference_completed_event] = inference_completed_events

      assert inference_completed_event.internal_payload["assistant_message_id"] ==
               assistant_before_restart.id

      assert inference_completed_event.internal_payload["resumed"] == true
    end

    test "rerun after a completed turn does not append duplicate output or events",
         %{user: user, project: project, session: session} do
      assert {:ok, first_pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      assert_receive {:blocking_provider_started, first_provider_pid,
                      [%{role: "system"}, %{role: "user", content: "Plan the next step"}]},
                     1_000

      send(first_provider_pid, {:release_blocking_provider, "Initial completion"})
      assert_event_persisted(session.id, "chat_session_runner.complete_session.completed")

      assert [{^first_pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert :ok = Sacrum.ChatSessionSupervisor.terminate_runner(session.id)
      assert_registry_empty(session.id)

      {:ok, first_completion} = ChatSessions.get_session(user.id, project.id, session.id)
      assert first_completion.status == :running
      stable_engine_session_ref = first_completion.engine_session_ref

      {:ok, first_messages} =
        ChatMessages.list_for_session(first_completion, include_private: true)

      first_event_count =
        Repo.aggregate(
          from(event in ChatEvent, where: event.chat_session_id == ^session.id),
          :count
        )

      _second_pid =
        start_runner_until_turn_completed(session.id,
          inference_opts: [provider: UnexpectedProvider, test_pid: self()]
        )

      on_exit(fn -> Sacrum.ChatSessionSupervisor.terminate_runner(session.id) end)
      refute_receive {:unexpected_provider_called, _messages}

      {:ok, second_view} = ChatSessions.get_session(user.id, project.id, session.id)
      assert second_view.status == :running
      assert second_view.engine_session_ref == stable_engine_session_ref

      {:ok, second_messages} = ChatMessages.list_for_session(second_view, include_private: true)

      assert Enum.map(second_messages, & &1.id) == Enum.map(first_messages, & &1.id)

      assistant_messages = Enum.filter(second_messages, &(&1.role == :assistant))
      assert length(assistant_messages) == 1
      assert hd(assistant_messages).content == "Initial completion"

      second_event_count =
        Repo.aggregate(
          from(event in ChatEvent, where: event.chat_session_id == ^session.id),
          :count
        )

      assert second_event_count == first_event_count
    end
  end

  defp assert_runner_checkpoints(chat_session_id, opts \\ []) do
    skipped_steps = Keyword.get(opts, :skipped_steps, [])
    expected_steps = @runner_steps -- skipped_steps

    runner_events =
      Repo.all(
        from event in ChatEvent,
          where:
            event.chat_session_id == ^chat_session_id and
              event.event_type in ^expected_steps,
          order_by: [asc: event.inserted_at, asc: event.id]
      )

    event_visibilities =
      runner_events
      |> Enum.group_by(& &1.event_type, & &1.visibility)
      |> Map.new(fn {event_type, visibilities} -> {event_type, Enum.sort(visibilities)} end)

    assert event_visibilities == Map.new(expected_steps, &{&1, [:internal, :public]})

    public_payload_steps =
      runner_events
      |> Enum.filter(&(&1.visibility == :public))
      |> Enum.map(fn event -> event.public_payload["step"] end)

    assert public_payload_steps == Enum.map(expected_steps, &runner_step_name/1)

    internal_payload_steps =
      runner_events
      |> Enum.filter(&(&1.visibility == :internal))
      |> Enum.map(fn event -> event.internal_payload["step"] end)

    assert internal_payload_steps == Enum.map(expected_steps, &runner_step_name/1)
  end

  defp assert_public_activity_phases(user, project, session, turn_message_id, expected_phases) do
    assert {:ok, events} = LiveChat.list_public_events(user.id, project.id, session.id)

    actual_phases =
      events
      |> Enum.filter(fn event ->
        String.starts_with?(event.event_type, "chat_runner_activity.") and
          event.public_payload["turn_message_id"] == turn_message_id
      end)
      |> Enum.map(& &1.public_payload["phase"])

    assert actual_phases == expected_phases
  end

  defp runner_step_name("chat_session_runner." <> rest) do
    String.replace_suffix(rest, ".completed", "")
  end

  defp assert_registry_empty(chat_session_id, attempts \\ 20)

  defp assert_registry_empty(chat_session_id, attempts) when attempts > 0 do
    case Sacrum.ChatSessionRegistry.lookup(chat_session_id) do
      [] ->
        :ok

      _registered ->
        Process.sleep(10)
        assert_registry_empty(chat_session_id, attempts - 1)
    end
  end

  defp assert_registry_empty(chat_session_id, 0) do
    assert [] = Sacrum.ChatSessionRegistry.lookup(chat_session_id)
  end

  defp assert_event_persisted(chat_session_id, event_type, opts \\ [])

  defp assert_event_persisted(chat_session_id, event_type, opts) when is_list(opts) do
    attempts = Keyword.get(opts, :attempts, 50)
    turn_message_id = Keyword.get(opts, :turn_message_id)
    assert_event_persisted(chat_session_id, event_type, turn_message_id, attempts)
  end

  defp assert_event_persisted(chat_session_id, event_type, turn_message_id, attempts)
       when attempts > 0 do
    count =
      Repo.aggregate(
        persisted_event_query(chat_session_id, event_type, turn_message_id),
        :count
      )

    if count > 0 do
      :ok
    else
      Process.sleep(20)
      assert_event_persisted(chat_session_id, event_type, turn_message_id, attempts - 1)
    end
  end

  defp assert_event_persisted(chat_session_id, event_type, turn_message_id, 0) do
    assert Repo.aggregate(
             persisted_event_query(chat_session_id, event_type, turn_message_id),
             :count
           ) > 0
  end

  defp persisted_event_query(chat_session_id, event_type, nil) do
    from event in ChatEvent,
      where:
        event.chat_session_id == ^chat_session_id and
          event.event_type == ^event_type
  end

  defp persisted_event_query(chat_session_id, event_type, turn_message_id) do
    from event in persisted_event_query(chat_session_id, event_type, nil),
      where:
        fragment("?->>'turn_message_id' = ?", event.public_payload, ^turn_message_id) or
          fragment(
            "?->'details'->>'turn_message_id' = ?",
            event.internal_payload,
            ^turn_message_id
          )
  end

  defp start_runner_until_turn_completed(chat_session_id, opts) do
    assert {:ok, pid} = Sacrum.ChatSessionSupervisor.start_runner(chat_session_id, opts)

    assert_event_persisted(chat_session_id, "chat_session_runner.complete_session.completed")
    assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(chat_session_id)

    pid
  end

  defp assert_runner_stopped(pid, chat_session_id) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> flunk("expected chat session runner to stop")
    end

    assert_registry_empty(chat_session_id)
  end
end
