defmodule Sacrum.TestSupport.ChatSessionRunnerFixtures do
  import Ecto.Query

  alias Sacrum.Accounts.{LiveChat, Projects}
  alias Sacrum.Chat.Inference.Result
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

  def event_count(session, type) do
    Repo.one(
      from event in ChatEvent,
        where: event.chat_session_id == ^session.id and event.event_type == ^type,
        select: count(event.id)
    )
  end
end
