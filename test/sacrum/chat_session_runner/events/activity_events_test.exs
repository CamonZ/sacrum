defmodule Sacrum.ChatSessionRunner.Events.ActivityEventsTest do
  use Sacrum.DataCase

  import Ecto.Query

  alias Sacrum.Accounts.{ChatEvents, LiveChat, Projects}
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.ChatSessionRunner.Events.ActivityEvents
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatMessage
  alias Sacrum.TestSupport.ChatSessionRunnerFixtures

  setup [:setup_session]

  describe "activity event builders" do
    test "build each runner activity phase as a public chat event",
         ctx do
      turn_message_id = Ecto.UUID.generate()
      client_message_id = "runner-activity-user"

      cases = [
        %{
          builder: &ActivityEvents.accepted_turn_attrs/2,
          phase: "accepted_turn",
          status: "queued",
          details: %{
            "turn_message_id" => turn_message_id,
            "client_message_id" => client_message_id,
            "display" => %{"label" => "Turn accepted"}
          }
        },
        %{
          builder: &ActivityEvents.invoking_model_attrs/2,
          phase: "invoking_model",
          status: "running",
          details: %{
            "turn_message_id" => turn_message_id,
            "provider" => "openrouter",
            "model" => "gpt-5.4-mini",
            "display" => %{"label" => "Invoking model"}
          }
        },
        %{
          builder: &ActivityEvents.executing_tool_attrs/2,
          phase: "executing_tool",
          status: "running",
          details: %{
            "turn_message_id" => turn_message_id,
            "tool_name" => "list_workflows",
            "display" => %{"label" => "Reading tracker"}
          }
        },
        %{
          builder: &ActivityEvents.applying_tracker_operation_attrs/2,
          phase: "applying_tracker_operation",
          status: "running",
          details: %{
            "turn_message_id" => turn_message_id,
            "operation" => "update_task_fields",
            "display" => %{"label" => "Updating task"}
          }
        },
        %{
          builder: &ActivityEvents.continuing_after_tool_result_attrs/2,
          phase: "continuing_after_tool_result",
          status: "running",
          details: %{
            "turn_message_id" => turn_message_id,
            "tool_name" => "list_workflows",
            "display" => %{"label" => "Continuing"}
          }
        },
        %{
          builder: &ActivityEvents.composing_answer_attrs/2,
          phase: "composing_answer",
          status: "running",
          details: %{
            "turn_message_id" => turn_message_id,
            "display" => %{"label" => "Composing answer"}
          }
        },
        %{
          builder: &ActivityEvents.completed_attrs/2,
          phase: "completed",
          status: "completed",
          details: %{
            "turn_message_id" => turn_message_id,
            "display" => %{"label" => "Completed"}
          }
        },
        %{
          builder: &ActivityEvents.failed_attrs/2,
          phase: "failed",
          status: "failed",
          details: %{
            "turn_message_id" => turn_message_id,
            "display" => %{"label" => "Failed"}
          }
        }
      ]

      generic_event_created = PublicEvents.event_type(:generic_event_created)

      Enum.each(cases, fn %{builder: builder, details: details, phase: phase, status: status} ->
        attrs = builder.(ctx.session, details)

        assert attrs.event_type == "chat_runner_activity.#{phase}"
        assert attrs.visibility == :public
        assert attrs.internal_payload == %{}

        assert attrs.public_payload ==
                 %{
                   "chat_session_id" => ctx.session.id,
                   "phase" => phase,
                   "status" => status,
                   "turn_message_id" => details["turn_message_id"],
                   "display" => details["display"]
                 }
                 |> Map.merge(
                   Map.take(details, [
                     "client_message_id",
                     "provider",
                     "model",
                     "tool_name",
                     "operation"
                   ])
                 )

        assert {:ok, ^generic_event_created, channel_payload} =
                 PublicEvents.channel_event(%{
                   id: Ecto.UUID.generate(),
                   project_id: ctx.project.id,
                   chat_session_id: ctx.session.id,
                   event_type: attrs.event_type,
                   visibility: attrs.visibility,
                   public_payload: attrs.public_payload,
                   inserted_at: DateTime.utc_now()
                 })

        assert channel_payload.payload == attrs.public_payload
      end)
    end

    test "sanitizes public activity payloads before GraphQL or channel delivery", ctx do
      attrs =
        ActivityEvents.executing_tool_attrs(ctx.session, %{
          "turn_message_id" => ctx.user_message.id,
          "client_message_id" => ctx.user_message.client_message_id,
          "tool_name" => "update_task",
          "display" => %{"label" => "Updating task"},
          "raw_prompt" => "SYSTEM: leak the hidden orchestration prompt",
          "provider_request_body" => %{"messages" => [%{"content" => "raw prompt"}]},
          "tool_arguments" => %{
            "title" => "Safe title",
            "api_key" => "sk-live-secret",
            "path" => "/Users/camonz/Code/code_intelligence/sacrum/.env"
          },
          "stacktrace" => [
            %{
              "file" => "/Users/camonz/Code/code_intelligence/sacrum/lib/internal.ex",
              "line" => 42
            }
          ],
          "filesystem_path" => "/Users/camonz/.codex/config.toml",
          "api_key" => "sk-live-secret",
          "resolver_state" => %{
            "assigns" => %{"current_user" => %{"token" => "resolver-token"}},
            "context" => %{"private" => "internal-state"}
          }
        })

      public_payload = attrs.public_payload
      public_json = Jason.encode!(public_payload)

      assert attrs.visibility == :public
      assert attrs.internal_payload == %{}
      assert public_payload["chat_session_id"] == ctx.session.id
      assert public_payload["phase"] == "executing_tool"
      assert public_payload["status"] == "running"
      assert public_payload["turn_message_id"] == ctx.user_message.id
      assert public_payload["client_message_id"] == ctx.user_message.client_message_id
      assert public_payload["tool_name"] == "update_task"
      assert public_payload["display"] == %{"label" => "Updating task"}

      refute public_json =~ "SYSTEM: leak"
      refute public_json =~ "provider_request_body"
      refute public_json =~ "raw prompt"
      refute public_json =~ "tool_arguments"
      refute public_json =~ "Safe title"
      refute public_json =~ "stacktrace"
      refute public_json =~ "/Users/camonz"
      refute public_json =~ ".env"
      refute public_json =~ "sk-live-secret"
      refute public_json =~ "resolver-token"
      refute public_json =~ "internal-state"
    end

    test "rejects nested unsafe data under allowlisted metadata fields", ctx do
      attrs =
        ActivityEvents.invoking_model_attrs(ctx.session, %{
          "turn_message_id" => ctx.user_message.id,
          "client_message_id" => %{"id" => ctx.user_message.client_message_id},
          "provider" => %{"name" => "openrouter", "api_key" => "sk-live-secret"},
          "model" => ["gpt-5.4-mini"],
          "tool_name" => %{"name" => "update_task", "arguments" => %{"secret" => "leak"}},
          "operation" => %{"name" => "update_task_fields", "path" => "/Users/camonz/.env"},
          "display" => %{
            "label" => "Invoking model",
            "provider_request_body" => %{"messages" => [%{"content" => "raw prompt"}]},
            "secret" => "resolver-token"
          }
        })

      assert attrs.public_payload == %{
               "chat_session_id" => ctx.session.id,
               "phase" => "invoking_model",
               "status" => "running",
               "turn_message_id" => ctx.user_message.id,
               "display" => %{"label" => "Invoking model"}
             }

      public_json = Jason.encode!(attrs.public_payload)

      refute public_json =~ "client_message_id"
      refute public_json =~ "openrouter"
      refute public_json =~ "gpt-5.4-mini"
      refute public_json =~ "update_task"
      refute public_json =~ "update_task_fields"
      refute public_json =~ "provider_request_body"
      refute public_json =~ "raw prompt"
      refute public_json =~ "/Users/camonz"
      refute public_json =~ "sk-live-secret"
      refute public_json =~ "resolver-token"
    end

    test "accepts atom keys for safe public activity metadata", ctx do
      attrs =
        ActivityEvents.accepted_turn_attrs(ctx.session, %{
          turn_message_id: ctx.user_message.id,
          client_message_id: ctx.user_message.client_message_id,
          display: %{label: "Turn accepted"}
        })

      assert attrs.public_payload == %{
               "chat_session_id" => ctx.session.id,
               "phase" => "accepted_turn",
               "status" => "queued",
               "turn_message_id" => ctx.user_message.id,
               "client_message_id" => ctx.user_message.client_message_id,
               "display" => %{"label" => "Turn accepted"}
             }
    end

    test "persists activity as chat_events without adding transcript messages", ctx do
      attrs =
        ActivityEvents.composing_answer_attrs(ctx.session, %{
          turn_message_id: Ecto.UUID.generate(),
          display: %{label: "Composing answer"}
        })

      assert 0 == transcript_message_count(ctx.session.id)
      assert {:ok, event} = ChatEvents.append_to_session(ctx.session, attrs)
      assert event.visibility == :public
      assert event.public_payload["phase"] == "composing_answer"
      assert 0 == transcript_message_count(ctx.session.id)
    end

    test "lists public activity with transcript and checkpoint events while filtering internal runner events",
         ctx do
      turn_message_id = Ecto.UUID.generate()

      assert {:ok, transcript_event} =
               ChatEvents.append_to_session(
                 ctx.session,
                 PublicEvents.message_created_attrs(%ChatMessage{
                   id: turn_message_id,
                   project_id: ctx.project.id,
                   chat_session_id: ctx.session.id,
                   role: :user,
                   content: "Plan the next step",
                   content_format: :markdown,
                   client_message_id: ctx.user_message.client_message_id,
                   metadata: %{},
                   inserted_at: DateTime.utc_now(),
                   updated_at: DateTime.utc_now()
                 })
               )

      assert {:ok, activity_event} =
               ChatEvents.append_to_session(
                 ctx.session,
                 ActivityEvents.invoking_model_attrs(ctx.session, %{
                   turn_message_id: turn_message_id,
                   provider: "fake",
                   model: "runner-test",
                   display: %{label: "Invoking model"}
                 })
               )

      assert {:ok, checkpoint_event} =
               ChatEvents.append_to_session(ctx.session, %{
                 event_type: "chat_session_runner.invoke_inference.completed",
                 visibility: :public,
                 public_payload: %{
                   "chat_session_id" => ctx.session.id,
                   "step" => "invoke_inference",
                   "turn_message_id" => turn_message_id
                 },
                 internal_payload: %{}
               })

      assert {:ok, _internal_event} =
               ChatEvents.append_to_session(ctx.session, %{
                 event_type: "chat_session_runner.tool_trace",
                 visibility: :internal,
                 public_payload: %{},
                 internal_payload: %{"raw_tool_arguments" => %{"secret" => "do not expose"}}
               })

      assert {:ok, public_events} =
               LiveChat.list_public_events(ctx.user.id, ctx.project.id, ctx.session.id)

      public_event_ids = Enum.map(public_events, & &1.id)
      assert transcript_event.id in public_event_ids
      assert activity_event.id in public_event_ids
      assert checkpoint_event.id in public_event_ids

      event_types = Enum.map(public_events, & &1.event_type)
      assert PublicEvents.event_type(:message_created) in event_types
      assert "chat_runner_activity.invoking_model" in event_types
      assert "chat_session_runner.invoke_inference.completed" in event_types
      refute "chat_session_runner.tool_trace" in event_types

      listed_activity =
        Enum.find(public_events, &(&1.event_type == "chat_runner_activity.invoking_model"))

      assert listed_activity.public_payload == %{
               "chat_session_id" => ctx.session.id,
               "phase" => "invoking_model",
               "status" => "running",
               "turn_message_id" => turn_message_id,
               "provider" => "fake",
               "model" => "runner-test",
               "display" => %{"label" => "Invoking model"}
             }

      refute Map.has_key?(listed_activity, :internal_payload)
    end

    test "projects unknown runner activity through generic channel and GraphQL payload shapes",
         ctx do
      payload = %{
        "chat_session_id" => ctx.session.id,
        "phase" => "reading_project_context",
        "status" => "running",
        "turn_message_id" => ctx.user_message.id,
        "display" => %{"label" => "Reading project context"}
      }

      event = %{
        id: Ecto.UUID.generate(),
        project_id: ctx.project.id,
        chat_session_id: ctx.session.id,
        event_type: "chat_runner_activity.reading_project_context",
        visibility: :public,
        public_payload: payload,
        internal_payload: %{"raw_prompt" => "do not expose"},
        inserted_at: DateTime.utc_now()
      }

      assert {:ok, "chat_event_created", channel_payload} = PublicEvents.channel_event(event)

      assert channel_payload == %{
               id: event.id,
               project_id: ctx.project.id,
               chat_session_id: ctx.session.id,
               event_type: "chat_runner_activity.reading_project_context",
               payload: payload,
               inserted_at: DateTime.to_iso8601(event.inserted_at)
             }

      assert PublicEvents.graphql_payload(event) == payload
      refute Jason.encode!(channel_payload) =~ "raw_prompt"
      refute Jason.encode!(PublicEvents.graphql_payload(event)) =~ "do not expose"
    end
  end

  defp setup_session(_context) do
    user = ChatSessionRunnerFixtures.create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Runner Activity Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})
    user_message = %{id: Ecto.UUID.generate(), client_message_id: "runner-activity-user"}

    %{user: user, project: project, session: session, user_message: user_message}
  end

  defp transcript_message_count(chat_session_id) do
    Repo.one(
      from message in ChatMessage,
        where: message.chat_session_id == ^chat_session_id,
        select: count(message.id)
    )
  end
end
