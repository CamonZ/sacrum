defmodule Sacrum.TestSupport.ChatSessionRunnerFixtures do
  import Ecto.Query

  alias Sacrum.Accounts.{LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.DirectTracker
  alias Sacrum.ChatSessionRunner.Events.Checkpoints
  alias Sacrum.ChatSessionRunner.Transcript.Messages
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Users

  def create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "runner-modules-#{suffix}@example.com",
        username: "runner_modules_#{suffix}",
        password: "password123"
      })

    user
  end

  def setup_session(_context) do
    user = create_user()
    {:ok, project} = Projects.insert(user.id, %{name: "Runner Modules Project"})
    {:ok, session} = LiveChat.create_session(user.id, project.id, %{})

    {:ok, user_message} =
      LiveChat.send_message(user.id, project.id, session.id, %{
        content: "Refactor this runner",
        client_message_id: "runner-modules-user"
      })

    %{user: user, project: project, session: session, user_message: user_message}
  end

  def build_result(content \\ "Module answer") do
    %Result{
      content: content,
      content_format: :markdown,
      public_metadata: %{"provider" => "module-provider", "model" => "module-model"},
      internal_metadata: %{"trace_id" => "module-trace"}
    }
  end

  def append_assistant(session, user_message, result \\ build_result()) do
    Messages.ensure_message(session, Messages.assistant_message_attrs(result, user_message.id))
  end

  def create_tracker_targets(ctx) do
    {:ok, workflow} =
      Sacrum.Accounts.Workflows.insert(ctx.user.id, ctx.project.id, %{
        name: "Runner Modules Workflow"
      })

    {:ok, step} =
      Sacrum.Accounts.WorkflowSteps.insert(workflow, %{
        name: "Runner Modules Step",
        step_order: 1,
        prompt: "Prompt"
      })

    {:ok, task} =
      Sacrum.Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{
        title: "Runner Modules Task",
        workflow_id: workflow.id,
        current_step_id: step.id
      })

    %{workflow: workflow, step: step, task: task}
  end

  def show_task_operation(ctx) do
    targets = create_tracker_targets(ctx)

    %{
      action: "show_task",
      arguments: %{"include_sections" => false},
      targets: %{task: targets.task},
      scope: %{user_id: ctx.user.id, project_id: ctx.project.id, chat_session_id: ctx.session.id}
    }
  end

  def show_task_directive(ctx, tool_call_id \\ "tool-call-1") do
    targets = create_tracker_targets(ctx)
    arguments = %{"task_ref" => targets.task.id, "include_sections" => false}

    %{
      "action" => "show_task",
      "arguments" => arguments,
      "provider_tool_call" => provider_tool_call("show_task", arguments, tool_call_id),
      "assistant_content" => ""
    }
  end

  def provider_tool_call(action, arguments, tool_call_id \\ "tool-call-1") do
    Sacrum.Chat.DirectTrackerOperationTools.provider_tool_call(
      action,
      arguments,
      tool_call_id
    )
  end

  def no_pending_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    %{session: session, status: :queued}
  end

  def pending_user_turn_fixture(ctx) do
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

  def partial_direct_tool_continuation_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "partial-direct-tool-continuation")
    {:ok, running} = transition(ctx, session, :running)
    {:ok, _events} = Checkpoints.checkpoint_step(running, :intake, %{})
    {:ok, _events} = Checkpoints.checkpoint_step(running, :load_messages, %{"message_count" => 1})

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :invoke_inference, %{"provider" => "stub"})

    operation =
      ctx
      |> Map.put(:session, running)
      |> show_task_operation()
      |> Map.put(:tool_call, provider_tool_call("show_task", %{"include_sections" => false}))
      |> Map.put(:assistant_content, "")

    {:ok, _event} =
      DirectTracker.Events.append_completed(running, operation, %{ok: true}, %{
        "turn_message_id" => user_message.id
      })

    %{
      session: running,
      status: :running,
      turn_message_id: user_message.id,
      user_client_message_id: user_message.client_message_id
    }
  end

  def completed_turn_fixture(ctx) do
    {:ok, session} = LiveChat.create_session(ctx.user.id, ctx.project.id, %{})
    {:ok, user_message} = send_user_message(ctx, session, "completed-turn")
    {:ok, running} = transition(ctx, session, :running)

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :invoke_inference, %{"provider" => "stub"})

    {:ok, assistant} = append_assistant(running, user_message)

    {:ok, _events} =
      Checkpoints.checkpoint_step(running, :append_assistant, %{
        "assistant_message_id" => assistant.id,
        "turn_message_id" => user_message.id
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

  def failed_turn_fixture(ctx) do
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

  def event_count(session, type) do
    Repo.one(
      from event in ChatEvent,
        where: event.chat_session_id == ^session.id and event.event_type == ^type,
        select: count(event.id)
    )
  end

  defp send_user_message(ctx, session, client_message_id) do
    LiveChat.send_message(ctx.user.id, ctx.project.id, session.id, %{
      content: "Hydrate #{client_message_id}",
      client_message_id: client_message_id
    })
  end

  defp transition(ctx, session, status) do
    Sacrum.Accounts.ChatSessions.transition_status(
      ctx.user.id,
      ctx.project.id,
      session.id,
      status
    )
  end
end
