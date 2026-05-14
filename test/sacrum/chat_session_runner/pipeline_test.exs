defmodule Sacrum.ChatSessionRunner.PipelineTest do
  @moduledoc """
  Direct unit tests over `Sacrum.ChatSessionRunner.Pipeline`. The pipeline owns
  every durable side effect performed by the chat-session runner, so these
  tests assert the contract independently of the Jido action layer:

    * fetch and runnability gating
    * idempotent intake / append / resume / complete
    * checkpoint events emitted at each step
    * failure recording without leaking raw reasons into public payloads
  """

  use Sacrum.DataCase

  alias Sacrum.Accounts.{ChatMessages, ChatSessions, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.Chat.InferenceEvents
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.Repo.ChatSessions, as: ChatSessionsRepo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users

  @assistant_client_message_id_prefix "chat_session_runner:assistant:v1"

  defmodule StubProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid), do: send(test_pid, :stub_called)

      {:ok,
       %Result{
         content: Keyword.get(opts, :content, "Pipeline stub answer"),
         content_format: :markdown,
         public_metadata: %{"provider" => "pipeline-stub", "model" => "pipeline-test"},
         internal_metadata: %{"trace_id" => "pipeline-trace"}
       }}
    end
  end

  defmodule CancellingProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, opts) do
      {user_id, project_id, session_id} = Keyword.fetch!(opts, :ids)

      {:ok, _} =
        ChatSessions.transition_status(user_id, project_id, session_id, :cancelled)

      {:ok,
       %Result{
         content: "ignored",
         content_format: :markdown,
         public_metadata: %{"provider" => "x", "model" => "y"},
         internal_metadata: %{}
       }}
    end
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "pipeline-#{suffix}@example.com",
        username: "pipeline_#{suffix}",
        password: "password123"
      })

    user
  end

  defp setup_session(_context) do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Pipeline Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

    {:ok, user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "Hello pipeline",
        client_message_id: "pipeline-user"
      })

    engine_session_ref = "jido_agent_server:#{session.id}"

    %{
      user: user,
      project: project,
      session: session,
      user_message: user_message,
      engine_session_ref: engine_session_ref
    }
  end

  defp transition_running(ctx) do
    {:ok, session} =
      ChatSessions.transition_status(ctx.user.id, ctx.project.id, ctx.session.id, :running)

    Map.put(ctx, :session, session)
  end

  defp build_result(content \\ "Pipeline answer") do
    %Result{
      content: content,
      content_format: :markdown,
      public_metadata: %{"provider" => "pipeline-stub", "model" => "pipeline-test"},
      internal_metadata: %{"trace_id" => "pipeline-trace"}
    }
  end

  defp checkpoint_events(chat_session_id, step) do
    event_type = "chat_session_runner.#{step}.completed"

    events =
      Repo.all(
        from event in ChatEvent,
          where:
            event.chat_session_id == ^chat_session_id and
              event.event_type == ^event_type
      )

    %{
      public: Enum.find(events, &(&1.visibility == :public)),
      internal: Enum.find(events, &(&1.visibility == :internal)),
      all: events
    }
  end

  describe "fetch_session/1" do
    setup [:setup_session]

    test "returns the session when it exists", ctx do
      assert {:ok, session} = Pipeline.fetch_session(ctx.session.id)
      assert session.id == ctx.session.id
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} =
               Pipeline.fetch_session("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "ensure_runnable/1" do
    setup [:setup_session]

    test "continues on a non-terminal session", ctx do
      assert {:continue, session} = Pipeline.ensure_runnable(ctx.session)
      assert session.id == ctx.session.id
    end

    test "halts on a terminal session status", ctx do
      {:ok, cancelled} =
        ChatSessions.transition_status(ctx.user.id, ctx.project.id, ctx.session.id, :cancelled)

      assert {:halt, ^cancelled, {:terminal_status, :cancelled}} =
               Pipeline.ensure_runnable(cancelled)
    end
  end

  describe "refresh_runnable_session/1" do
    setup [:setup_session]

    test "reloads and continues when the session remains runnable", ctx do
      assert {:ok, refreshed} = Pipeline.refresh_runnable_session(ctx.session)
      assert refreshed.id == ctx.session.id
    end

    test "propagates a halt when the session became terminal after the original fetch", ctx do
      stale = ctx.session

      {:ok, _cancelled} =
        ChatSessions.transition_status(ctx.user.id, ctx.project.id, ctx.session.id, :cancelled)

      assert {:halt, _session, {:terminal_status, :cancelled}} =
               Pipeline.refresh_runnable_session(stale)
    end
  end

  describe "intake/2" do
    setup [:setup_session]

    test "transitions to running, sets engine fields, and writes intake checkpoint", ctx do
      assert {:ok, running} = Pipeline.intake(ctx.session, ctx.engine_session_ref)
      assert running.status == :running
      assert running.engine_kind == "jido"
      assert running.engine_session_ref == ctx.engine_session_ref

      assert {:ok, intake_status_message} =
               ChatMessages.get_by_client_message_id(
                 running,
                 "chat_session_runner:status:intake:v1:#{ctx.user_message.id}"
               )

      assert intake_status_message.content == "Chat session started."

      events = checkpoint_events(ctx.session.id, "intake")
      assert events.public
      assert events.internal
    end

    test "is idempotent — re-running intake does not duplicate messages or checkpoints", ctx do
      {:ok, _} = Pipeline.intake(ctx.session, ctx.engine_session_ref)
      {:ok, _} = Pipeline.intake(ctx.session, ctx.engine_session_ref)
      client_message_id = "chat_session_runner:status:intake:v1:#{ctx.user_message.id}"

      intake_status_messages =
        Repo.all(
          from m in Sacrum.Repo.Schemas.ChatMessage,
            where:
              m.chat_session_id == ^ctx.session.id and
                m.client_message_id == ^client_message_id
        )

      assert length(intake_status_messages) == 1

      events = checkpoint_events(ctx.session.id, "intake")
      assert length(events.all) == 2
    end
  end

  describe "load_messages/1" do
    setup [:setup_session]

    test "returns persisted messages and writes a load_messages checkpoint", ctx do
      ctx = transition_running(ctx)
      assert {:ok, messages} = Pipeline.load_messages(ctx.session)
      assert Enum.any?(messages, &(&1.id == ctx.user_message.id))

      events = checkpoint_events(ctx.session.id, "load_messages")
      assert events.public.public_payload["step"] == "load_messages"
      assert events.internal.internal_payload["details"]["message_count"] == length(messages)
    end
  end

  describe "lookup_assistant_message/1" do
    setup [:setup_session]

    test "returns :not_found when no assistant message has been persisted", ctx do
      assert {:error, :not_found} = Pipeline.lookup_assistant_message(ctx.session)
    end

    test "returns the persisted assistant message keyed by client_message_id", ctx do
      ctx = transition_running(ctx)

      {:ok, assistant} =
        ChatMessages.append_to_session(ctx.session, %{
          role: :assistant,
          content: "previous answer",
          content_format: :markdown,
          client_message_id: "#{@assistant_client_message_id_prefix}:#{ctx.user_message.id}",
          metadata: %{"provider" => "pipeline-stub", "model" => "pipeline-test"}
        })

      assert {:ok, found} = Pipeline.lookup_assistant_message(ctx.session)
      assert found.id == assistant.id
    end
  end

  describe "invoke_inference/3" do
    setup [:setup_session]

    test "returns the inference result and writes a checkpoint with public provider/model", ctx do
      ctx = transition_running(ctx)

      {:ok, messages} = ChatMessages.list_for_session(ctx.session, include_private: true)

      assert {:ok, refreshed_session, %Result{content: "Pipeline stub answer"}} =
               Pipeline.invoke_inference(ctx.session, messages,
                 provider: StubProvider,
                 test_pid: self()
               )

      assert refreshed_session.id == ctx.session.id
      assert_received :stub_called

      events = checkpoint_events(ctx.session.id, "invoke_inference")
      assert events.public.public_payload["provider"] == "pipeline-stub"
      assert events.public.public_payload["model"] == "pipeline-test"
    end

    test "halts when the session became terminal during inference", ctx do
      ctx = transition_running(ctx)

      {:ok, messages} = ChatMessages.list_for_session(ctx.session, include_private: true)

      assert {:halt, _session, {:terminal_status, :cancelled}} =
               Pipeline.invoke_inference(ctx.session, messages,
                 provider: CancellingProvider,
                 ids: {ctx.user.id, ctx.project.id, ctx.session.id}
               )
    end
  end

  describe "append_assistant_message/2" do
    setup [:setup_session]

    test "persists the assistant message, public + internal events, and is idempotent", ctx do
      ctx = transition_running(ctx)
      inference_result = build_result()

      assert {:ok, message} = Pipeline.append_assistant_message(ctx.session, inference_result)
      assert message.role == :assistant

      assert message.client_message_id ==
               "#{@assistant_client_message_id_prefix}:#{ctx.user_message.id}"

      assert {:ok, second_call_message} =
               Pipeline.append_assistant_message(ctx.session, inference_result)

      assert second_call_message.id == message.id

      {:ok, messages} = ChatMessages.list_for_session(ctx.session, include_private: true)
      assistants = Enum.filter(messages, &(&1.role == :assistant))
      assert length(assistants) == 1

      inference_completed =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^ctx.session.id and
                event.event_type == ^InferenceEvents.event_type(:inference_completed) and
                event.visibility == :internal
        )

      assert length(inference_completed) == 1

      events = checkpoint_events(ctx.session.id, "append_assistant")
      assert events.public.public_payload["assistant_message_id"] == message.id
    end
  end

  describe "resume_assistant_message/2" do
    setup [:setup_session]

    test "marks the inference_completed event as resumed and does not duplicate it", ctx do
      ctx = transition_running(ctx)

      {:ok, assistant} =
        ChatMessages.append_to_session(ctx.session, %{
          role: :assistant,
          content: "Resumed answer",
          content_format: :markdown,
          client_message_id: "#{@assistant_client_message_id_prefix}:#{ctx.user_message.id}",
          metadata: %{"provider" => "pipeline-stub", "model" => "pipeline-test"}
        })

      assert {:ok, _session, ^assistant} =
               Pipeline.resume_assistant_message(ctx.session, assistant)

      # Calling again must remain idempotent.
      assert {:ok, _session, ^assistant} =
               Pipeline.resume_assistant_message(ctx.session, assistant)

      [internal_inference] =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^ctx.session.id and
                event.event_type == ^InferenceEvents.event_type(:inference_completed) and
                event.visibility == :internal
        )

      assert internal_inference.internal_payload["resumed"] == true

      checkpoint = checkpoint_events(ctx.session.id, "append_assistant")
      assert length(checkpoint.all) == 2
      assert checkpoint.public.public_payload["resumed"] == true
    end
  end

  describe "complete_session/1" do
    setup [:setup_session]

    test "transitions to completed, writes the status message, and checkpoints", ctx do
      ctx = transition_running(ctx)

      assert {:ok, completed} = Pipeline.complete_session(ctx.session)
      assert completed.status == :completed

      assert {:ok, status_message} =
               ChatMessages.get_by_client_message_id(
                 completed,
                 "chat_session_runner:status:complete_session:v1:#{ctx.user_message.id}"
               )

      assert status_message.content == "Chat session completed."

      events = checkpoint_events(ctx.session.id, "complete_session")
      assert events.public.public_payload["status"] == "completed"
    end

    test "halts when the session is already terminal", ctx do
      {:ok, cancelled} =
        ChatSessions.transition_status(ctx.user.id, ctx.project.id, ctx.session.id, :cancelled)

      assert {:halt, _session, {:terminal_status, :cancelled}} =
               Pipeline.complete_session(cancelled)
    end
  end

  describe "mark_failed/2" do
    setup [:setup_session]

    test "transitions to failed and records the inspected reason in the internal payload only",
         ctx do
      ctx = transition_running(ctx)
      reason = {:malformed_signal, :no_payload}

      assert {:error, ^reason} = Pipeline.mark_failed(ctx.session.id, reason)

      {:ok, reloaded} = ChatSessionsRepo.get(ctx.session.id)
      assert reloaded.status == :failed

      [internal_failure] =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^ctx.session.id and
                event.event_type == "chat_session_runner.failed.completed" and
                event.visibility == :internal
        )

      assert internal_failure.internal_payload["details"]["reason"] == inspect(reason)

      public_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^ctx.session.id and
                event.visibility == :public
        )

      Enum.each(public_events, fn event ->
        payload_json = Jason.encode!(event.public_payload || %{})
        refute payload_json =~ "malformed_signal"
      end)
    end

    test "returns the original reason when the session is already terminal", ctx do
      {:ok, _cancelled} =
        ChatSessions.transition_status(ctx.user.id, ctx.project.id, ctx.session.id, :cancelled)

      assert {:error, :boom} = Pipeline.mark_failed(ctx.session.id, :boom)

      {:ok, reloaded} = ChatSessionsRepo.get(ctx.session.id)
      assert reloaded.status == :cancelled
    end

    test "returns the original reason when the session does not exist" do
      missing_id = "00000000-0000-0000-0000-000000000000"
      assert {:error, :missing} = Pipeline.mark_failed(missing_id, :missing)
    end
  end
end
