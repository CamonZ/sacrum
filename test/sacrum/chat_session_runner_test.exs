defmodule Sacrum.ChatSessionRunnerTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts.{ChatMessages, ChatSessions, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Repo.Schemas.{ChatEvent, StepExecution, Task, TaskRun}
  alias Sacrum.Repo.Users

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
                      [%{role: "user", content: "Plan the next step"}]},
                     1_000

      assert [{^pid, _}] = Sacrum.ChatSessionRegistry.lookup(session.id)

      assert {:error, {:already_started, ^pid}} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      completion =
        await_runner_completion(pid, fn ->
          send(provider_pid, {:release_blocking_provider, "Supervised assistant output"})
        end)

      assert completion.status == :completed
      assert completion.result.session.status == :completed
      assert_registry_empty(session.id)

      {:ok, completed_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert completed_session.status == :completed
      assert completed_session.engine_kind == "jido"
      assert completed_session.engine_session_ref == Sacrum.ChatSessionRunner.agent_id(session.id)
      assert %DateTime{} = completed_session.started_at
      assert %DateTime{} = completed_session.ended_at

      {:ok, messages} = ChatMessages.list_for_session(completed_session, [])

      assert Enum.map(messages, &{&1.role, &1.client_message_id, &1.content}) == [
               {:user, "client-runner-user", "Plan the next step"},
               {:status, "chat_session_runner:status:intake:v1:#{user_message.id}",
                "Chat session started."},
               {:assistant, assistant_client_message_id, "Supervised assistant output"},
               {:status, "chat_session_runner:status:complete_session:v1:#{user_message.id}",
                "Chat session completed."}
             ]

      assistant = Enum.find(messages, &(&1.role == :assistant))
      assert assistant.metadata == %{"provider" => "fake", "model" => "runner-test"}

      assert_runner_checkpoints(session.id)

      assert Repo.aggregate(Task, :count) == 0
      assert Repo.aggregate(TaskRun, :count) == 0
      assert Repo.aggregate(StepExecution, :count) == 0
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
                      [%{role: "user", content: "Plan the next step"}]},
                     1_000

      assert {:ok, cancelled_session} = LiveChat.cancel_session(user.id, project.id, session.id)
      assert cancelled_session.status == :cancelled

      completion =
        await_runner_completion(pid, fn ->
          send(provider_pid, {:release_blocking_provider, "Output after cancellation"})
        end)

      assert completion.status == :completed
      assert completion.result.status == :noop
      assert completion.result.reason == {:terminal_status, :cancelled}
      assert_registry_empty(session.id)

      {:ok, reloaded_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert reloaded_session.status == :cancelled

      {:ok, messages} = ChatMessages.list_for_session(reloaded_session, [])

      refute Enum.any?(messages, fn message ->
               message.role == :assistant and message.content == "Output after cancellation"
             end)
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
        start_runner_and_wait(session.id,
          inference_opts: [provider: UnexpectedProvider, test_pid: self()]
        )

      {:ok, completed_session} = ChatSessions.get_session(user.id, project.id, session.id)
      assert completed_session.status == :completed
      assert completed_session.engine_kind == "jido"
      assert completed_session.engine_session_ref == Sacrum.ChatSessionRunner.agent_id(session.id)
      assert [] = Sacrum.ChatSessionRegistry.lookup(session.id)
      assert is_pid(resume_pid)
      refute_receive {:unexpected_provider_called, _messages}

      _noop_pid =
        start_runner_and_wait(session.id,
          inference_opts: [provider: UnexpectedProvider, test_pid: self()]
        )

      refute_receive {:unexpected_provider_called, _messages}

      {:ok, messages} = ChatMessages.list_for_session(completed_session, [])
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

    test "rerun after a fully completed session does not append duplicate output or events",
         %{user: user, project: project, session: session} do
      assert {:ok, first_pid} =
               Sacrum.ChatSessionSupervisor.start_runner(session.id,
                 inference_opts: [provider: BlockingProvider, test_pid: self()]
               )

      assert_receive {:blocking_provider_started, first_provider_pid,
                      [%{role: "user", content: "Plan the next step"}]},
                     1_000

      completion =
        await_runner_completion(first_pid, fn ->
          send(first_provider_pid, {:release_blocking_provider, "Initial completion"})
        end)

      assert completion.status == :completed
      assert_registry_empty(session.id)

      {:ok, first_completion} = ChatSessions.get_session(user.id, project.id, session.id)
      assert first_completion.status == :completed
      stable_engine_session_ref = first_completion.engine_session_ref

      {:ok, first_messages} = ChatMessages.list_for_session(first_completion, [])

      first_event_count =
        Repo.aggregate(
          from(event in ChatEvent, where: event.chat_session_id == ^session.id),
          :count
        )

      _second_pid =
        start_runner_and_wait(session.id,
          inference_opts: [provider: UnexpectedProvider, test_pid: self()]
        )

      refute_receive {:unexpected_provider_called, _messages}

      {:ok, second_view} = ChatSessions.get_session(user.id, project.id, session.id)
      assert second_view.status == :completed
      assert second_view.engine_session_ref == stable_engine_session_ref

      {:ok, second_messages} = ChatMessages.list_for_session(second_view, [])

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

  defp start_runner_and_wait(chat_session_id, opts) do
    assert {:ok, pid} = Sacrum.ChatSessionSupervisor.start_runner(chat_session_id, opts)

    assert %{status: :completed} = await_runner_completion(pid)
    assert_registry_empty(chat_session_id)

    pid
  end

  defp await_runner_completion(pid, release_fun \\ fn -> :ok end) do
    await_task =
      Elixir.Task.async(fn -> Jido.AgentServer.await_completion(pid, timeout: 1_000) end)

    release_fun.()

    assert {:ok, completion} = Elixir.Task.await(await_task, 1_500)
    completion
  end
end
