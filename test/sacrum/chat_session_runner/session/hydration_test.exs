defmodule Sacrum.ChatSessionRunner.Session.HydrationTest do
  use Sacrum.DataCase

  import Ecto.Query

  alias Jido.Agent.Directive
  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions, LiveChat, Projects}
  alias Sacrum.ChatSessionRunner.DirectTracker

  alias Sacrum.ChatSessionRunner.Actions.{
    CompleteSession,
    HydrateSession,
    InvokeInference,
    LoadMessages,
    ResumeAssistant
  }

  alias Sacrum.ChatSessionRunner.Events.Checkpoints
  alias Sacrum.ChatSessionRunner.Session.Hydration
  alias Sacrum.ChatSessionRunner.Session.Hydration.Snapshot
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.ChatSessionRunner.Transcript.Messages
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatMessage
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup do
    user = ChatSessionRunnerFixtures.create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Hydration Project"})
    %{user: user, project: project}
  end

  describe "hydrate_session/2 snapshots" do
    test "returns deterministic snapshots for durable turn fixtures", ctx do
      fixtures = [
        {:no_pending_turn, no_pending_turn_fixture(ctx), Signals.noop(), nil, nil},
        {:pending_user_turn, pending_user_turn_fixture(ctx), Signals.load_messages(), :intake,
         nil},
        {:partially_completed_tool_turn, partially_completed_tool_turn_fixture(ctx),
         Signals.resume_assistant(), :invoke_inference, :direct_tracker_operation_completed},
        {:partially_completed_tool_turn, append_assistant_pending_completion_fixture(ctx),
         Signals.complete_session(), :append_assistant, nil},
        {:completed_turn, completed_turn_fixture(ctx), Signals.noop(), :complete_session,
         :completion_recorded},
        {:failed_turn, failed_turn_fixture(ctx), Signals.noop(), :failed, :failure_recorded}
      ]

      for {turn_state, fixture, next_signal, last_checkpoint, durable_marker} <- fixtures do
        assert {:ok, %Snapshot{} = first} = Hydration.hydrate_session(fixture.session.id)
        assert {:ok, %Snapshot{} = second} = Hydration.hydrate_session(fixture.session.id)

        assert first == second
        assert first.chat_session_id == fixture.session.id
        assert first.status == fixture.status
        assert first.turn_state == turn_state
        assert first.turn_message_id == fixture[:turn_message_id]
        assert first.next_signal == next_signal
        assert first.last_checkpoint == last_checkpoint

        assert first.idempotency_keys["user_client_message_id"] ==
                 fixture[:user_client_message_id]

        assert first.idempotency_keys["assistant_client_message_id"] ==
                 fixture[:assistant_client_message_id]

        assert first.idempotency_keys["durable_marker"] == durable_marker

        assert_hydrated_action_path_succeeds(fixture, first.next_signal)
      end
    end

    test "resumes a persisted assistant turn without duplicating durable side effects", ctx do
      fixture = partially_completed_tool_turn_fixture(ctx)
      before_counts = side_effect_counts(fixture.session)

      assert {:ok,
              %Snapshot{
                turn_state: :partially_completed_tool_turn,
                next_signal: next_signal,
                last_checkpoint: :invoke_inference,
                turn_message_id: turn_message_id
              }} =
               Hydration.hydrate_session(fixture.session.id)

      assert next_signal == Signals.resume_assistant()
      assert turn_message_id == fixture.turn_message_id
      assert side_effect_counts(fixture.session) == before_counts

      assert {:ok, _result, [%Directive.Emit{} = emit]} =
               ResumeAssistant.run(action_params(fixture), %{})

      assert emit.signal.type == Signals.complete_session()
      assert side_effect_counts(fixture.session) == before_counts

      assert {:ok, %Snapshot{} = second} = Hydration.hydrate_session(fixture.session.id)

      assert second.next_signal == Signals.complete_session()
      assert side_effect_counts(fixture.session) == before_counts
    end

    test "completes an append_assistant checkpoint without repeating durable side effects", ctx do
      fixture = append_assistant_pending_completion_fixture(ctx)
      before_counts = side_effect_counts(fixture.session)

      assert {:ok,
              %Snapshot{
                turn_state: :partially_completed_tool_turn,
                next_signal: next_signal,
                last_checkpoint: :append_assistant,
                turn_message_id: turn_message_id,
                idempotency_keys: idempotency_keys
              } = first} = Hydration.hydrate_session(fixture.session.id)

      assert {:ok, ^first} = Hydration.hydrate_session(fixture.session.id)
      assert next_signal == Signals.complete_session()
      assert turn_message_id == fixture.turn_message_id

      assert idempotency_keys["user_client_message_id"] == fixture.user_client_message_id

      assert idempotency_keys["assistant_client_message_id"] ==
               fixture.assistant_client_message_id

      assert side_effect_counts(fixture.session) == before_counts

      assert {:ok, %{step: :hydrate_session}, [%Directive.Emit{} = emit]} =
               HydrateSession.run(action_params(fixture), %{})

      assert emit.signal.type == Signals.complete_session()
      assert side_effect_counts(fixture.session) == before_counts

      assert {:ok, %{step: :complete_session}} = CompleteSession.run(action_params(fixture), %{})

      after_completion = side_effect_counts(fixture.session)
      assert after_completion.user_messages == before_counts.user_messages
      assert after_completion.assistant_messages == before_counts.assistant_messages
      assert after_completion.direct_tracker_events == before_counts.direct_tracker_events
      assert after_completion.completion_events == before_counts.completion_events + 2

      assert {:ok, %Snapshot{next_signal: next_signal, last_checkpoint: :complete_session}} =
               Hydration.hydrate_session(fixture.session.id)

      assert next_signal == Signals.noop()

      assert {:ok, %{step: :complete_session}} = CompleteSession.run(action_params(fixture), %{})
      assert side_effect_counts(fixture.session) == after_completion
    end

    test "resumes direct tracker continuation without an assistant message or duplicated tracker events",
         ctx do
      fixture = direct_tracker_without_assistant_fixture(ctx)
      before_counts = side_effect_counts(fixture.session)

      assert {:ok,
              %Snapshot{
                turn_state: :partially_completed_tool_turn,
                next_signal: next_signal,
                last_checkpoint: :invoke_inference
              }} = Hydration.hydrate_session(fixture.session.id)

      assert next_signal == Signals.resume_assistant()

      assert {:ok, %{step: :resume_assistant}, [%Directive.Emit{} = emit]} =
               ResumeAssistant.run(action_params(fixture), %{})

      assert emit.signal.type == Signals.append_assistant()

      assert side_effect_counts(fixture.session).direct_tracker_events ==
               before_counts.direct_tracker_events

      assert {:ok, %{step: :resume_assistant}, [%Directive.Emit{} = second_emit]} =
               ResumeAssistant.run(action_params(fixture), %{})

      assert second_emit.signal.type == Signals.append_assistant()

      assert side_effect_counts(fixture.session).direct_tracker_events ==
               before_counts.direct_tracker_events
    end
  end

  test "the hydrate_session signal is an explicit AgentServer boot path" do
    engine_session_ref = "jido_agent_server:session-1"

    signal =
      Sacrum.ChatSessionRunner.Actions.hydrate_session_signal(
        "session-1",
        engine_session_ref,
        provider: :stub
      )

    assert Signals.hydrate_session() in Signals.all()
    assert signal.type == Signals.hydrate_session()
    assert signal.source == Signals.source()

    assert signal.data == %{
             chat_session_id: "session-1",
             engine_session_ref: engine_session_ref,
             inference_opts: [provider: :stub]
           }
  end

  defp no_pending_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    %{session: session, status: :queued}
  end

  defp pending_user_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "pending-user-turn")
    {:ok, running} = transition(ctx, session, :running)
    {:ok, _events} = Checkpoints.checkpoint_step(running, :intake, %{})

    %{
      session: running,
      status: :running,
      turn_message_id: user_message.id,
      user_client_message_id: user_message.client_message_id
    }
  end

  defp partially_completed_tool_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "partial-tool-turn")
    {:ok, running} = transition(ctx, session, :running)
    {:ok, _events} = Checkpoints.checkpoint_step(running, :intake, %{})
    {:ok, _events} = Checkpoints.checkpoint_step(running, :load_messages, %{"message_count" => 1})

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :invoke_inference, %{"provider" => "stub"})

    {:ok, assistant} =
      ChatMessages.append_to_session(
        running,
        Messages.assistant_message_attrs(build_result(), user_message.id)
      )

    {:ok, _event} = append_direct_tracker_event(running, user_message.id, assistant.id)

    %{
      session: running,
      status: :running,
      turn_message_id: user_message.id,
      user_client_message_id: user_message.client_message_id,
      assistant_client_message_id: assistant.client_message_id
    }
  end

  defp direct_tracker_without_assistant_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "direct-tracker-no-assistant")
    {:ok, running} = transition(ctx, session, :running)
    {:ok, _events} = Checkpoints.checkpoint_step(running, :intake, %{})
    {:ok, _events} = Checkpoints.checkpoint_step(running, :load_messages, %{"message_count" => 1})

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :invoke_inference, %{"provider" => "stub"})

    operation = direct_tracker_operation_for_continuation(ctx, running)

    {:ok, _event} =
      DirectTracker.Events.append_completed(running, operation, %{ok: true}, %{
        "turn_message_id" => user_message.id
      })

    %{
      session: running,
      turn_message_id: user_message.id,
      engine_session_ref: Sacrum.ChatSessionRunner.agent_id(running.id),
      inference_opts: [provider: __MODULE__.HydrationStubProvider, content: "Recovered answer"]
    }
  end

  defp append_assistant_pending_completion_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "append-assistant-pending")
    {:ok, running} = transition(ctx, session, :running)
    {:ok, _events} = Checkpoints.checkpoint_step(running, :intake, %{})
    {:ok, _events} = Checkpoints.checkpoint_step(running, :load_messages, %{"message_count" => 1})

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :invoke_inference, %{"provider" => "stub"})

    {:ok, assistant} =
      ChatMessages.append_to_session(
        running,
        Messages.assistant_message_attrs(build_result(), user_message.id)
      )

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :append_assistant, %{
        "assistant_message_id" => assistant.id,
        "turn_message_id" => user_message.id
      })

    %{
      session: running,
      status: :running,
      turn_message_id: user_message.id,
      user_client_message_id: user_message.client_message_id,
      assistant_client_message_id: assistant.client_message_id
    }
  end

  defp completed_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "completed-turn")
    {:ok, running} = transition(ctx, session, :running)

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :invoke_inference, %{"provider" => "stub"})

    {:ok, assistant} = ChatSessionRunnerFixtures.append_assistant(running, user_message)

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :append_assistant, %{
        "assistant_message_id" => assistant.id
      })

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :complete_session, %{"status" => "turn_completed"})

    %{
      session: running,
      status: :running,
      turn_message_id: user_message.id,
      user_client_message_id: user_message.client_message_id,
      assistant_client_message_id: assistant.client_message_id
    }
  end

  defp failed_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "failed-turn")
    {:ok, failed} = transition(ctx, session, :failed)
    {:ok, _events} = Checkpoints.checkpoint_step(failed, :failed, %{"reason" => "boom"})

    %{
      session: failed,
      status: :failed,
      turn_message_id: user_message.id,
      user_client_message_id: user_message.client_message_id
    }
  end

  defp send_user_message(ctx, session, client_message_id) do
    LiveChat.send_message(ctx.user.id, ctx.project.id, session.id, %{
      content: "Hydrate #{client_message_id}",
      client_message_id: client_message_id
    })
  end

  defp transition(ctx, session, status) do
    ChatSessions.transition_status(ctx.user.id, ctx.project.id, session.id, status)
  end

  defp append_direct_tracker_event(session, turn_message_id, assistant_message_id) do
    ChatEvents.append_to_session(session, %{
      event_type: DirectTracker.Events.completed_event_type(),
      visibility: :public,
      public_payload: %{
        "action" => "show_task",
        "assistant_message_id" => assistant_message_id,
        "status" => "succeeded",
        "turn_message_id" => turn_message_id,
        "tool_call_id" => "tool-call-1"
      },
      internal_payload: %{"result" => %{"ok" => true}}
    })
  end

  defp direct_tracker_operation_for_continuation(ctx, session) do
    ctx
    |> Map.put(:session, session)
    |> ChatSessionRunnerFixtures.show_task_operation()
    |> Map.put(:tool_call, provider_tool_call("show_task", %{"include_sections" => false}))
    |> Map.put(:assistant_content, "")
  end

  defp provider_tool_call(action, arguments) do
    Sacrum.Chat.DirectTrackerOperationTools.provider_tool_call(
      action,
      arguments,
      "tool-call-1"
    )
  end

  defp side_effect_counts(session) do
    %{
      user_messages: message_count(session.id, :user),
      assistant_messages: message_count(session.id, :assistant),
      direct_tracker_events:
        ChatSessionRunnerFixtures.event_count(
          session,
          DirectTracker.Events.completed_event_type()
        ),
      completion_events:
        ChatSessionRunnerFixtures.event_count(
          session,
          "chat_session_runner.complete_session.completed"
        )
    }
  end

  defp message_count(session_id, role) do
    Repo.one(
      from message in ChatMessage,
        where: message.chat_session_id == ^session_id and message.role == ^role,
        select: count(message.id)
    )
  end

  defp build_result, do: ChatSessionRunnerFixtures.build_result("Hydrated answer")

  defp assert_hydrated_action_path_succeeds(fixture, next_signal) do
    params = action_params(fixture)
    assert {:ok, result} = HydrateSession.run(params, %{}) |> normalize_action_result()
    assert result.step == :hydrate_session

    cond do
      next_signal in [nil, Signals.noop()] ->
        assert result.status == :idle

      next_signal == Signals.load_messages() ->
        assert {:ok, %{step: :load_messages}, [%Directive.Emit{}]} =
                 LoadMessages.run(params, %{})

      next_signal == Signals.invoke_inference() ->
        assert {:ok, %{step: :invoke_inference}, [%Directive.Emit{}]} =
                 InvokeInference.run(params, %{})

      next_signal == Signals.resume_assistant() ->
        assert {:ok, %{step: :resume_assistant}, [%Directive.Emit{}]} =
                 ResumeAssistant.run(params, %{})

      next_signal == Signals.complete_session() ->
        assert {:ok, %{step: :complete_session}} =
                 CompleteSession.run(params, %{})
    end
  end

  defp normalize_action_result({:ok, result, _directives}), do: {:ok, result}
  defp normalize_action_result({:ok, result}), do: {:ok, result}

  defp action_params(fixture) do
    %{
      chat_session_id: fixture.session.id,
      engine_session_ref:
        Map.get_lazy(fixture, :engine_session_ref, fn ->
          Sacrum.ChatSessionRunner.agent_id(fixture.session.id)
        end),
      inference_opts:
        Map.get(fixture, :inference_opts, provider: __MODULE__.HydrationStubProvider),
      turn_message_id: fixture[:turn_message_id]
    }
  end

  defmodule HydrationStubProvider do
    @behaviour Sacrum.Chat.Inference.Provider

    @impl true
    def generate(_messages, opts) do
      {:ok,
       %Sacrum.Chat.Inference.Result{
         content: Keyword.get(opts, :content, "Hydrated recovery answer"),
         content_format: :markdown,
         public_metadata: %{"provider" => "stub", "model" => "hydration-test"},
         internal_metadata: %{"trace_id" => "hydration-test"}
       }}
    end
  end
end
