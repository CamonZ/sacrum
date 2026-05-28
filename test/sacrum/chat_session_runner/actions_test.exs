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
  alias Sacrum.Accounts.{ChatEvents, ChatMessages, LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.Actions

  alias Sacrum.ChatSessionRunner.Actions.{
    AppendAssistant,
    CompleteSession,
    AcceptUserTurn,
    Intake,
    InvokeInference,
    LoadMessages,
    MarkFailed,
    ResumeAssistant,
    VerifyAuthoringIntent
  }

  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage}
  alias Sacrum.Repo.Users

  @assistant_client_message_id_prefix "chat_session_runner:assistant:v1"

  defmodule StubProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(messages, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:stub_provider_called, messages, opts})
      end

      content = Keyword.get(opts, :content, "Stub assistant output")

      {:ok,
       %Result{
         content: content,
         content_format: :markdown,
         public_metadata: %{"provider" => "stub", "model" => "actions-test"},
         internal_metadata:
           Map.merge(%{"trace_id" => "actions-test"}, Keyword.get(opts, :internal_metadata, %{}))
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

  describe "AcceptUserTurn.run/2" do
    setup do
      user = create_user("accept-user-turn")
      {:ok, project} = Projects.insert(user.id, %{name: "Accept User Turn Project"})
      {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

      %{
        user: user,
        project: project,
        session: session,
        engine_session_ref: Sacrum.ChatSessionRunner.agent_id(session.id)
      }
    end

    test "persists the accepted user message and public event before downstream work", ctx do
      message_id = Ecto.UUID.generate()

      params = %{
        user_id: ctx.user.id,
        project_id: ctx.project.id,
        chat_session_id: ctx.session.id,
        message_id: message_id,
        engine_session_ref: ctx.engine_session_ref,
        content: "Persist me before any model or tracker work",
        content_format: "markdown",
        client_message_id: "accepted-turn-1",
        metadata: %{"origin" => "graphql"},
        inference_opts: [provider: StubProvider, test_pid: self()]
      }

      assert {:ok, %{step: :accept_user_turn, turn_message_id: ^message_id},
              [%Directive.Emit{} = emit]} = AcceptUserTurn.run(params, %{})

      refute_received {:stub_provider_called, _messages, _opts}

      assert {:ok,
              %ChatMessage{
                id: ^message_id,
                role: :user,
                content: "Persist me before any model or tracker work",
                content_format: :markdown,
                client_message_id: "accepted-turn-1",
                metadata: %{"origin" => "graphql"}
              }} = ChatMessages.get_by_client_message_id(ctx.session, "accepted-turn-1")

      assert {:ok, %ChatEvent{event_type: "chat_message_created", visibility: :public} = event} =
               ChatEvents.get_message_created_for_message(ctx.session, message_id)

      assert event.public_payload["id"] == message_id
      assert emit.signal.type == Signals.load_messages()
      assert emit.signal.data.turn_message_id == message_id
    end

    test "returns failed accepted-turn activity without invoking downstream work when persistence fails",
         ctx do
      {:ok, _existing} =
        LiveChat.send_message(ctx.user.id, ctx.project.id, ctx.session.id, %{
          content: "Already accepted",
          client_message_id: "duplicate-client-turn"
        })

      params = %{
        user_id: ctx.user.id,
        project_id: ctx.project.id,
        chat_session_id: ctx.session.id,
        message_id: Ecto.UUID.generate(),
        engine_session_ref: ctx.engine_session_ref,
        content: "This duplicate turn should fail acceptance",
        content_format: "markdown",
        client_message_id: "duplicate-client-turn",
        metadata: %{},
        inference_opts: [provider: StubProvider, test_pid: self()]
      }

      assert {:ok,
              %{
                step: :accept_user_turn,
                status: :failed,
                chat_session_id: chat_session_id,
                error: _reason
              }} = AcceptUserTurn.run(params, %{})

      assert chat_session_id == ctx.session.id
      refute_received {:stub_provider_called, _messages, _opts}
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

    test "calls the configured provider and emits verify_authoring with the result", ctx do
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

      assert_received {:stub_provider_called, messages, _opts}

      assert [
               %{role: "system", content: _system_prompt},
               %{role: "user", content: "Hello from unit tests"}
             ] = messages

      assert emit.signal.type == Signals.verify_authoring()
      assert %Result{content: "Generated answer"} = emit.signal.data.inference_result
    end

    test "injects the authoring system prompt and tools into inference_opts", ctx do
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
        inference_opts: [provider: StubProvider, test_pid: self()]
      }

      assert {:ok, %{step: :invoke_inference}, [_emit]} = InvokeInference.run(params, %{})

      assert_received {:stub_provider_called, [system_msg | _rest], opts}
      assert %{role: "system", content: system_prompt} = system_msg
      assert system_prompt =~ "Vertebrae authoring assistant"
      assert Keyword.get(opts, :system_prompt) == system_prompt

      tools = Keyword.fetch!(opts, :tools)
      tool_names = Enum.map(tools, fn %{"function" => %{"name" => name}} -> name end)
      assert "start_authoring" in tool_names
      assert "revise_authoring" in tool_names
    end

    test "caller-supplied :system_prompt and :tools win over the defaults", ctx do
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
          system_prompt: "caller-owned prompt",
          tools: []
        ]
      }

      assert {:ok, %{step: :invoke_inference}, [_emit]} = InvokeInference.run(params, %{})

      assert_received {:stub_provider_called, [%{content: "caller-owned prompt"} | _], opts}
      assert Keyword.get(opts, :tools) == []
    end
  end

  describe "VerifyAuthoringIntent.run/2 for direct tracker operations" do
    setup [:create_session_with_message]

    test "routes a validated directive through resolver, executor, and model continuation",
         ctx do
      %{workflow: workflow, step: step, task: task} = create_tracker_targets(ctx)

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operation(%{
          "action" => "update_workflow_step",
          "arguments" => %{
            "workflow_ref" => workflow.id,
            "step_ref" => step.id,
            "fields" => %{"prompt" => "Use the durable direct prompt."}
          }
        })

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: direct_tracker_continuation_opts("The workflow step prompt was updated."),
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.append_assistant()
      assert emit.signal.data.inference_result.content == "The workflow step prompt was updated."

      {:ok, updated_step} =
        Sacrum.Accounts.WorkflowSteps.get_by(ctx.user.id,
          conditions: [id: step.id, project_id: ctx.project.id]
        )

      assert updated_step.prompt == "Use the durable direct prompt."

      {:ok, messages} = ChatMessages.list_for_session(running, include_private: true)
      refute Enum.any?(messages, &(&1.role == :assistant))
      assert [] = authoring_drafts_for_session(ctx)
      assert_received {:stub_provider_called, continuation_messages, _opts}
      assert_continuation_messages(continuation_messages, "update_workflow_step")

      assert {:ok, unchanged_task} =
               Sacrum.Accounts.Tasks.get_by(ctx.user.id,
                 conditions: [id: task.id, project_id: ctx.project.id]
               )

      assert unchanged_task.title == "Direct Tracker Task"
    end

    test "routes update_step_prompt through server-resolved context without creating an authoring draft",
         ctx do
      %{step: step, task: task} = create_tracker_targets(ctx)

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operation(%{
          "action" => "update_step_prompt",
          "arguments" => %{
            "prompt" => "Use the prompt-only direct tracker alias."
          }
        })

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: direct_tracker_continuation_opts("The active step prompt was updated."),
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.append_assistant()
      assert emit.signal.data.inference_result.content == "The active step prompt was updated."

      {:ok, updated_step} =
        Sacrum.Accounts.WorkflowSteps.get_by(ctx.user.id,
          conditions: [id: step.id, project_id: ctx.project.id]
        )

      assert updated_step.prompt == "Use the prompt-only direct tracker alias."

      [event] =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^running.id and
                event.visibility == :public and
                event.event_type == "chat_direct_tracker_operation.completed"
        )

      assert event.public_payload["action"] == "update_step_prompt"
      assert event.public_payload["status"] == "succeeded"

      assert event.public_payload["target"] == %{
               "type" => "workflow_step",
               "id" => step.id
             }

      {:ok, unchanged_task} =
        Sacrum.Accounts.Tasks.get_by(ctx.user.id,
          conditions: [id: task.id, project_id: ctx.project.id]
        )

      assert unchanged_task.title == "Direct Tracker Task"
      {:ok, messages} = ChatMessages.list_for_session(running, include_private: true)
      refute Enum.any?(messages, &(&1.role == :assistant))
      assert [] = authoring_drafts_for_session(ctx)
      assert_received {:stub_provider_called, continuation_messages, _opts}
      assert_continuation_messages(continuation_messages, "update_step_prompt")
    end

    test "routes show_task for a completed task into a final assistant answer",
         ctx do
      %{task: task} = create_tracker_targets(ctx)
      completed_at = ~U[2026-05-23 00:38:14.956038Z]

      Repo.update_all(
        from(task_record in Sacrum.Repo.Schemas.Task, where: task_record.id == ^task.id),
        set: [completed_at: completed_at]
      )

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operation(%{
          "action" => "show_task",
          "arguments" => %{
            "task_ref" => task.id,
            "include_sections" => true
          }
        })

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: direct_tracker_continuation_opts("The ticket is completed."),
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.append_assistant()

      assert {:ok, %{step: :append_assistant}, [%Directive.Emit{} = complete_emit]} =
               AppendAssistant.run(emit.signal.data, %{})

      assert complete_emit.signal.type == Signals.complete_session()

      assert {:ok, %{step: :complete_session}} =
               CompleteSession.run(complete_emit.signal.data, %{})

      {:ok, completed} = Sacrum.Repo.ChatSessions.get(running.id)
      assert completed.status == :completed

      [event] =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^running.id and
                event.visibility == :public and
                event.event_type == "chat_direct_tracker_operation.completed"
        )

      assert event.public_payload["action"] == "show_task"
      assert event.public_payload["status"] == "succeeded"
      assert event.public_payload["turn_message_id"] == ctx.user_message.id
      assert event.public_payload["result"]["completed_at"] == "2026-05-23T00:38:14.956038Z"

      assert Jason.encode!(event.public_payload)
      assert [] = authoring_drafts_for_session(ctx)

      {:ok, messages} = ChatMessages.list_for_session(completed, include_private: true)

      assert Enum.any?(messages, fn message ->
               message.role == :assistant and message.content == "The ticket is completed."
             end)

      refute Enum.any?(messages, fn message ->
               message.role == :user and String.contains?(message.content, "completed_at")
             end)
    end

    test "emits a public rejection for model-owned scope fields without mutating Accounts",
         ctx do
      %{workflow: workflow, step: step} = create_tracker_targets(ctx)

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operation(%{
          "action" => "update_workflow_step",
          "arguments" => %{
            "workflow_ref" => workflow.id,
            "step_ref" => step.id,
            "fields" => %{"prompt" => "This prompt must not be applied."},
            "project_id" => ctx.project.id
          }
        })

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.complete_session()

      {:ok, unchanged_step} =
        Sacrum.Accounts.WorkflowSteps.get_by(ctx.user.id,
          conditions: [id: step.id, project_id: ctx.project.id]
        )

      assert unchanged_step.prompt == "Original prompt"

      public_events =
        Repo.all(
          from event in ChatEvent,
            where:
              event.chat_session_id == ^running.id and
                event.visibility == :public and
                event.event_type == "chat_direct_tracker_operation.rejected"
        )

      assert [event] = public_events
      assert event.public_payload["reason"] == "out_of_scope"
      assert_actionable_rejection_response(event, :out_of_scope)
      assert [] = authoring_drafts_for_session(ctx)
    end

    test "emits an ambiguous target selection response without mutating or falling back", ctx do
      %{workflow: workflow, step: step} = create_tracker_targets(ctx)

      [first_task, second_task] =
        Enum.map(
          [
            "12345678-0000-0000-0000-000000000003",
            "12345678-0000-0000-0000-000000000004"
          ],
          fn id ->
            {:ok, task} =
              Sacrum.Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{
                title: "Ambiguous Direct Tracker Task",
                workflow_id: workflow.id,
                current_step_id: step.id
              })

            {_count, nil} =
              Repo.update_all(from(t in Sacrum.Repo.Schemas.Task, where: t.id == ^task.id),
                set: [id: id]
              )

            %{task | id: id}
          end
        )

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operation(%{
          "action" => "update_task_fields",
          "arguments" => %{
            "task_ref" => "12345678",
            "fields" => %{"title" => "This ambiguous task must not change"}
          }
        })

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.complete_session()

      [event] = direct_tracker_rejection_events(running.id)
      assert event.public_payload["reason"] == "ambiguous_target"
      assert_actionable_rejection_response(event, :ambiguous_target)
      assert event.public_payload["message"] =~ "12345678"
      public_payload_json = Jason.encode!(event.public_payload)
      refute public_payload_json =~ first_task.id
      refute public_payload_json =~ second_task.id
      assert event.internal_payload["rejection"]["details"] =~ first_task.id
      assert event.internal_payload["rejection"]["details"] =~ second_task.id

      unchanged_tasks =
        Repo.all(
          from task in Sacrum.Repo.Schemas.Task,
            where: task.id in ^[first_task.id, second_task.id],
            select: {task.id, task.title}
        )

      assert Enum.sort(unchanged_tasks) ==
               Enum.sort([
                 {first_task.id, "Ambiguous Direct Tracker Task"},
                 {second_task.id, "Ambiguous Direct Tracker Task"}
               ])

      refute assistant_message_exists?(running.id)
      assert [] = authoring_drafts_for_session(ctx)
    end

    test "rejects outside-scope task directives with an actionable public response before mutation",
         ctx do
      outside_user = create_user("outside-direct-tracker")
      {:ok, outside_project} = Projects.insert(outside_user.id, %{name: "Outside Project"})

      {:ok, outside_workflow} =
        Sacrum.Accounts.Workflows.insert(outside_user.id, outside_project.id, %{
          name: "Outside Workflow"
        })

      {:ok, outside_step} =
        Sacrum.Accounts.WorkflowSteps.insert(outside_workflow, %{
          name: "Outside Step",
          step_order: 1,
          prompt: "Outside prompt"
        })

      {:ok, outside_task} =
        Sacrum.Accounts.Tasks.insert(outside_user.id, outside_project.id, %{
          title: "Outside Direct Tracker Task",
          workflow_id: outside_workflow.id,
          current_step_id: outside_step.id
        })

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operation(%{
          "action" => "update_task_fields",
          "arguments" => %{
            "task_ref" => outside_task.id,
            "fields" => %{"title" => "This outside task must not change"}
          }
        })

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.complete_session()

      {:ok, unchanged_outside_task} =
        Sacrum.Accounts.Tasks.get_by(outside_user.id,
          conditions: [id: outside_task.id, project_id: outside_project.id]
        )

      assert unchanged_outside_task.title == "Outside Direct Tracker Task"

      [event] = direct_tracker_rejection_events(running.id)
      assert event.public_payload["reason"] == "out_of_scope"
      assert_actionable_rejection_response(event, :out_of_scope)
      refute Jason.encode!(event.public_payload) =~ outside_task.id

      refute assistant_message_exists?(running.id)
      assert [] = authoring_drafts_for_session(ctx)
    end

    test "rejects unsupported compound operations before mutating Accounts", ctx do
      %{workflow: workflow, step: step, task: task} = create_tracker_targets(ctx)

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operations([
          %{
            "action" => "show_task",
            "arguments" => %{"task_ref" => task.id}
          },
          %{
            "action" => "update_workflow_step",
            "arguments" => %{
              "workflow_ref" => workflow.id,
              "step_ref" => step.id,
              "fields" => %{"prompt" => "This compound prompt must not be applied."}
            }
          }
        ])

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.complete_session()

      {:ok, unchanged_step} =
        Sacrum.Accounts.WorkflowSteps.get_by(ctx.user.id,
          conditions: [id: step.id, project_id: ctx.project.id]
        )

      assert unchanged_step.prompt == "Original prompt"

      [event] = direct_tracker_rejection_events(running.id)
      assert event.public_payload["reason"] == "out_of_scope"
      assert event.internal_payload["rejection"]["reason_code"] == "out_of_scope"

      assert event.internal_payload["rejection"]["details"] =~
               "unsupported_compound_direct_tracker_operations"
    end

    test "rejects ambiguous compound operations before checklist mutation", ctx do
      %{workflow: workflow, step: step, task: task} = create_tracker_targets(ctx)

      Enum.each(
        [
          "12345678-0000-0000-0000-000000000003",
          "12345678-0000-0000-0000-000000000004"
        ],
        fn id ->
          {:ok, ambiguous_task} =
            Sacrum.Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{
              title: "Ambiguous Compound Task",
              workflow_id: workflow.id,
              current_step_id: step.id
            })

          Repo.update_all(from(t in Sacrum.Repo.Schemas.Task, where: t.id == ^ambiguous_task.id),
            set: [id: id]
          )
        end
      )

      {:ok, running} =
        Sacrum.Accounts.ChatSessions.transition_status(
          ctx.user.id,
          ctx.project.id,
          ctx.session.id,
          :running
        )

      inference_result =
        result_with_direct_tracker_operations([
          %{
            "action" => "show_task",
            "arguments" => %{"task_ref" => task.id}
          },
          %{
            "action" => "upsert_task_section",
            "arguments" => %{
              "task_ref" => "12345678",
              "section_type" => "checklist_item",
              "content" => "Must not be partially inserted",
              "done" => false
            }
          }
        ])

      params = %{
        chat_session_id: running.id,
        engine_session_ref: ctx.engine_session_ref,
        inference_opts: [],
        turn_message_id: ctx.user_message.id,
        inference_result: inference_result
      }

      assert {:ok, %{step: :verify_authoring}, [%Directive.Emit{} = emit]} =
               VerifyAuthoringIntent.run(params, %{})

      assert emit.signal.type == Signals.complete_session()

      [event] = direct_tracker_rejection_events(running.id)
      assert event.public_payload["reason"] == "ambiguous_target"

      assert [] =
               Repo.all(
                 from section in Sacrum.Repo.Schemas.TaskSection,
                   where:
                     section.project_id == ^ctx.project.id and
                       section.content == "Must not be partially inserted"
               )
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
      {:ok, messages} = ChatMessages.list_for_session(reloaded, include_private: true)

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

      {:ok, refreshed_messages} = ChatMessages.list_for_session(reloaded, include_private: true)

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
      {:ok, messages} = ChatMessages.list_for_session(refreshed_session, include_private: true)
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

  defp result_with_direct_tracker_operation(directive) do
    action = Map.fetch!(directive, "action")
    arguments = Map.get(directive, "arguments", %{})

    %Result{
      content: "Applying the requested tracker update.",
      content_format: :markdown,
      public_metadata: %{"provider" => "stub", "model" => "direct-tracker-test"},
      internal_metadata: %{
        "direct_tracker_operation" =>
          directive
          |> Map.put("provider_tool_call", provider_tool_call(action, arguments))
          |> Map.put("assistant_content", "")
      }
    }
  end

  defp result_with_direct_tracker_operations(directives) do
    directives =
      Enum.with_index(directives, fn directive, index ->
        action = Map.fetch!(directive, "action")
        arguments = Map.get(directive, "arguments", %{})

        directive
        |> Map.put("provider_tool_call", provider_tool_call(action, arguments, index))
        |> Map.put("assistant_content", "")
      end)

    %Result{
      content: "Applying the requested tracker updates.",
      content_format: :markdown,
      public_metadata: %{"provider" => "stub", "model" => "direct-tracker-test"},
      internal_metadata: %{"direct_tracker_operations" => directives}
    }
  end

  defp provider_tool_call(action, arguments, index \\ 0) do
    Sacrum.Chat.DirectTrackerOperationTools.provider_tool_call(
      action,
      arguments,
      "call_#{action}_#{index}"
    )
  end

  defp direct_tracker_continuation_opts(content) do
    [provider: StubProvider, test_pid: self(), content: content]
  end

  defp assert_continuation_messages(messages, action) do
    assert [%{role: "user"} | continuation] = messages

    assert [
             %{role: :assistant, tool_calls: [tool_call]},
             %{
               role: :tool,
               tool_call_id: tool_result_call_id,
               name: ^action,
               content: tool_result_content
             }
           ] = continuation

    assert tool_call.name == action
    tool_call_id = tool_call.id
    assert tool_result_call_id == tool_call_id

    assert {:ok, decoded} = Jason.decode(tool_result_content)
    assert decoded["action"] == action
  end

  defp direct_tracker_rejection_events(session_id) do
    Repo.all(
      from event in ChatEvent,
        where:
          event.chat_session_id == ^session_id and
            event.visibility == :public and
            event.event_type == "chat_direct_tracker_operation.rejected"
    )
  end

  defp assistant_message_exists?(session_id) do
    Repo.exists?(
      from message in ChatMessage,
        where: message.chat_session_id == ^session_id and message.role == :assistant
    )
  end

  defp assert_actionable_rejection_response(event, reason) do
    message = event.public_payload["message"]

    assert is_binary(message)

    downcased_message = String.downcase(message)

    assert String.contains?(downcased_message, "select")
    assert String.contains?(downcased_message, "valid")

    case reason do
      :ambiguous_target ->
        assert String.contains?(downcased_message, "multiple")

      :out_of_scope ->
        assert String.contains?(downcased_message, "in-scope")
    end
  end

  defp create_tracker_targets(ctx) do
    {:ok, workflow} =
      Sacrum.Accounts.Workflows.insert(ctx.user.id, ctx.project.id, %{
        name: "Direct Tracker Workflow"
      })

    {:ok, step} =
      Sacrum.Accounts.WorkflowSteps.insert(workflow, %{
        name: "Direct Step",
        step_order: 1,
        prompt: "Original prompt"
      })

    {:ok, task} =
      Sacrum.Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{
        title: "Direct Tracker Task",
        workflow_id: workflow.id,
        current_step_id: step.id
      })

    {:ok, _session} =
      Sacrum.Accounts.ChatSessions.update_session(ctx.session, %{
        public_metadata: %{
          "active_task_id" => task.id,
          "active_object" => %{"type" => "workflow_step", "id" => step.id}
        }
      })

    %{workflow: workflow, step: step, task: task}
  end
end
