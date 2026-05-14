defmodule Sacrum.ChatSessionRunner.ActionsTest do
  @moduledoc """
  Unit tests over the granular Jido actions that make up the chat-session
  runner pipeline. These tests exercise:

  - signal payload validation through each action's declared schema
  - the directive each action emits to advance the pipeline
  - terminal-status halts and failure recording for malformed payloads
  """

  use Sacrum.DataCase

  alias Jido.Agent.Directive
  alias Jido.Signal
  alias Sacrum.Accounts.{ChatMessages, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.Actions

  alias Sacrum.ChatSessionRunner.Actions.{
    AppendAssistant,
    CompleteSession,
    Intake,
    InvokeInference,
    LoadMessages,
    MarkFailed,
    ResumeAssistant
  }

  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users

  @assistant_client_message_id_prefix "chat_session_runner:assistant:v1"

  defmodule StubProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:stub_provider_called, messages})
      end

      content = Keyword.get(opts, :content, "Stub assistant output")

      {:ok,
       %Result{
         content: content,
         content_format: :markdown,
         public_metadata: %{"provider" => "stub", "model" => "actions-test"},
         internal_metadata: %{"trace_id" => "actions-test"}
       }}
    end
  end

  defp create_user(prefix \\ "chat-actions") do
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

  defp create_session_with_message(_context) do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Actions Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

    {:ok, user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "Hello from unit tests",
        client_message_id: "actions-user"
      })

    engine_session_ref = Sacrum.ChatSessionRunner.agent_id(session.id)

    %{
      user: user,
      project: project,
      session: session,
      user_message: user_message,
      engine_session_ref: engine_session_ref
    }
  end

  describe "Signals" do
    test "all/0 returns every routed signal type" do
      types = Signals.all()

      assert Signals.run() in types
      assert Signals.intake() in types
      assert Signals.load_messages() in types
      assert Signals.invoke_inference() in types
      assert Signals.append_assistant() in types
      assert Signals.resume_assistant() in types
      assert Signals.complete_session() in types
      assert Signals.mark_failed() in types
    end

    test "source/0 namespaces the runner" do
      assert Signals.source() == "/sacrum/chat_session_runner"
    end
  end

  describe "Actions.run_signal/3" do
    test "builds a CloudEvents-shaped run signal with the expected payload" do
      signal = Actions.run_signal("sess-1", "jido_agent_server:sess-1", a: 1)

      assert %Signal{
               type: "sacrum.chat_session.run",
               source: "/sacrum/chat_session_runner",
               data: %{
                 chat_session_id: "sess-1",
                 engine_session_ref: "jido_agent_server:sess-1",
                 inference_opts: [a: 1]
               }
             } = signal
    end
  end

  describe "schema validation rejects malformed payloads" do
    test "Intake rejects missing chat_session_id" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Intake.validate_params(%{engine_session_ref: "ref"})
    end

    test "LoadMessages rejects missing engine_session_ref" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               LoadMessages.validate_params(%{chat_session_id: "sess"})
    end

    test "InvokeInference rejects missing chat_session_id" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               InvokeInference.validate_params(%{engine_session_ref: "ref"})
    end

    test "AppendAssistant requires an inference_result payload" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               AppendAssistant.validate_params(%{
                 chat_session_id: "sess",
                 engine_session_ref: "ref"
               })
    end

    test "ResumeAssistant rejects missing chat_session_id" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               ResumeAssistant.validate_params(%{engine_session_ref: "ref"})
    end

    test "CompleteSession rejects missing engine_session_ref" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               CompleteSession.validate_params(%{chat_session_id: "sess"})
    end

    test "MarkFailed requires reason" do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               MarkFailed.validate_params(%{chat_session_id: "sess"})
    end
  end

  describe "Intake.run/2" do
    setup [:create_session_with_message]

    test "intakes the session and emits a load_messages directive", ctx do
      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: []
      }

      assert {:ok, %{step: :intake, chat_session_id: session_id}, [%Directive.Emit{} = emit]} =
               Intake.run(params, %{})

      assert session_id == ctx.session.id

      assert %Signal{type: type, data: data} = emit.signal
      assert type == Signals.load_messages()
      assert data.chat_session_id == ctx.session.id
      assert data.engine_session_ref == ctx.engine_session_ref

      {:ok, reloaded} = Sacrum.Repo.ChatSessions.get(ctx.session.id)
      assert reloaded.status == :running
      assert reloaded.engine_kind == "jido"
      assert reloaded.engine_session_ref == ctx.engine_session_ref

      intake_status_message =
        ChatMessages.get_by_client_message_id(
          reloaded,
          "chat_session_runner:status:intake:v1:#{ctx.user_message.id}"
        )

      assert {:ok, message} = intake_status_message
      assert message.content == "Chat session started."
    end

    test "halts cleanly when the session is already terminal", ctx do
      {:ok, _cancelled} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :cancelled
        )

      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: []
      }

      assert {:ok,
              %{status: :completed, step: :halt, last_answer: %{status: :noop, reason: reason}}} =
               Intake.run(params, %{})

      assert reason == {:terminal_status, :cancelled}
    end
  end

  describe "LoadMessages.run/2" do
    setup [:create_session_with_message]

    test "routes to invoke_inference when no assistant message has been persisted", ctx do
      {:ok, _running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: []
      }

      assert {:ok, %{route: :invoke_inference, message_count: count}, [%Directive.Emit{} = emit]} =
               LoadMessages.run(params, %{})

      assert count >= 1
      assert emit.signal.type == Signals.invoke_inference()
    end

    test "routes to resume_assistant when an assistant message already exists", ctx do
      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      {:ok, _assistant} =
        ChatMessages.append_to_session(running, %{
          role: :assistant,
          content: "previous output",
          content_format: :markdown,
          client_message_id: "#{@assistant_client_message_id_prefix}:#{ctx.user_message.id}",
          metadata: %{"provider" => "stub", "model" => "actions-test"}
        })

      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: []
      }

      assert {:ok, %{route: :resume}, [%Directive.Emit{} = emit]} =
               LoadMessages.run(params, %{})

      assert emit.signal.type == Signals.resume_assistant()
    end
  end

  describe "InvokeInference.run/2" do
    setup [:create_session_with_message]

    test "calls the configured provider and emits append_assistant with the result", ctx do
      {:ok, _running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [
          provider: StubProvider,
          test_pid: self(),
          content: "Generated answer"
        ]
      }

      assert {:ok, %{step: :invoke_inference}, [%Directive.Emit{} = emit]} =
               InvokeInference.run(params, %{})

      assert_received {:stub_provider_called, [%{role: "user", content: "Hello from unit tests"}]}

      assert emit.signal.type == Signals.append_assistant()
      assert %Result{content: "Generated answer"} = emit.signal.data.inference_result
    end
  end

  describe "AppendAssistant.run/2" do
    setup [:create_session_with_message]

    test "persists the assistant message exactly once and emits complete_session", ctx do
      {:ok, _running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result = %Result{
        content: "Answer body",
        content_format: :markdown,
        public_metadata: %{"provider" => "stub", "model" => "actions-test"},
        internal_metadata: %{"trace_id" => "append-1"}
      }

      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        inference_result: inference_result
      }

      assert {:ok, %{step: :append_assistant}, [%Directive.Emit{} = emit]} =
               AppendAssistant.run(params, %{})

      assert emit.signal.type == Signals.complete_session()

      {:ok, reloaded} = Sacrum.Repo.ChatSessions.get(ctx.session.id)
      {:ok, messages} = ChatMessages.list_for_session(reloaded, [])

      assistant_messages = Enum.filter(messages, &(&1.role == :assistant))

      assistant_client_message_id =
        "#{@assistant_client_message_id_prefix}:#{ctx.user_message.id}"

      assert [
               %{
                 content: "Answer body",
                 client_message_id: ^assistant_client_message_id
               }
             ] = assistant_messages

      # Idempotent: running again with the same client_message_id must not duplicate.
      assert {:ok, %{step: :append_assistant}, [_emit]} = AppendAssistant.run(params, %{})

      {:ok, refreshed_messages} = ChatMessages.list_for_session(reloaded, [])

      assert length(Enum.filter(refreshed_messages, &(&1.role == :assistant))) == 1
    end

    test "rejects an inference_result that is not a Result struct", ctx do
      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        inference_result: %{not: :a_result}
      }

      assert {:ok, %{error_recorded: true}, [%Directive.Emit{} = emit]} =
               AppendAssistant.run(params, %{})

      assert emit.signal.type == Signals.mark_failed()
      assert emit.signal.data.reason == :invalid_inference_result_payload

      public_message_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^ctx.session.id and
                event.visibility == :public and
                event.event_type == "chat_message_created"
        )

      assert Enum.all?(public_message_events, fn event ->
               event.public_payload["role"] != "assistant"
             end)

      {:ok, refreshed_session} = Sacrum.Repo.ChatSessions.get(ctx.session.id)
      {:ok, messages} = ChatMessages.list_for_session(refreshed_session, [])
      assert Enum.filter(messages, &(&1.role == :assistant)) == []
    end
  end

  describe "CompleteSession.run/2" do
    setup [:create_session_with_message]

    test "transitions the session to completed and reports a terminal completion result", ctx do
      {:ok, _running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      params = %{
        chat_session_id: ctx.session.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: []
      }

      assert {:ok,
              %{
                status: :completed,
                step: :complete_session,
                last_answer: %{session: completed_session}
              }} = CompleteSession.run(params, %{})

      assert completed_session.status == :completed
      assert ChatSessionStatus.terminal?(completed_session.status)
    end
  end

  describe "MarkFailed.run/2" do
    setup [:create_session_with_message]

    test "marks the session failed without leaking the raw reason into public events", ctx do
      {:ok, _running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      params = %{chat_session_id: ctx.session.id, reason: {:malformed_signal, :no_payload}}

      assert {:ok, %{status: :failed, error: {:malformed_signal, :no_payload}}} =
               MarkFailed.run(params, %{})

      {:ok, failed_session} = Sacrum.Repo.ChatSessions.get(ctx.session.id)
      assert failed_session.status == :failed

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

      [internal_failure] =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^ctx.session.id and
                event.visibility == :internal and
                event.event_type == "chat_session_runner.failed.completed"
        )

      assert internal_failure.internal_payload["details"]["reason"] ==
               inspect({:malformed_signal, :no_payload})
    end
  end
end
