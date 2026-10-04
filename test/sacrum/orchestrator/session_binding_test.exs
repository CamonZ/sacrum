defmodule Sacrum.Orchestrator.SessionBindingTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, PromptRenderer}
  alias Sacrum.Repo.Schemas.{StepExecution, Task}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.LlmInference

  @config %{"agent_config" => %{"model" => "test-model"}, "prompt" => "do the work"}

  describe "llm_inference session config" do
    test "is optional and normalizes to string keys" do
      assert %{valid?: true} = changeset = LlmInference.changeset(%LlmInference{}, @config)
      assert Ecto.Changeset.get_field(changeset, :session) == nil

      changeset =
        LlmInference.changeset(
          %LlmInference{},
          Map.put(@config, "session", %{name: "implementer", mode: "resume_or_new"})
        )

      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :session) == %{
               "name" => "implementer",
               "mode" => "resume_or_new"
             }
    end

    test "rejects invalid sessions" do
      for {session, message} <- [
            {%{"name" => " ", "mode" => "new"}, "$.name: must not be blank"},
            {%{"name" => String.duplicate("a", 256), "mode" => "new"},
             "$.name: must be at most 255 bytes"},
            {%{"name" => "impl", "mode" => "fork"},
             "$.mode: must be one of new, resume, resume_or_new"},
            {%{"name" => "impl", "mode" => "new", "id" => "x"}, "$.id: is not supported"},
            {%{"name" => "impl"}, "must have string name and mode"}
          ] do
        changeset = LlmInference.changeset(%LlmInference{}, Map.put(@config, "session", session))
        assert {^message, _} = changeset.errors[:session], inspect(session)
      end
    end
  end

  describe "dispatch" do
    setup :setup_context

    test "without a session sends no session and pins nothing", ctx do
      step = create_step(ctx, "Plain", nil)

      assert {:ok, execution} = dispatch(ctx, step)
      assert %{session_name: nil, resume_session_id: nil} = execution
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      refute Map.has_key?(payload, :session)
    end

    test "new starts the named session", ctx do
      step = create_step(ctx, "Implement", %{"name" => "implementer", "mode" => "new"})

      assert {:ok, execution} = dispatch(ctx, step)
      assert %{session_name: "implementer", resume_session_id: nil} = execution
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == %{mode: "new"}
    end

    test "resume fails without a binding and creates no execution", ctx do
      step = create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume"})

      assert {:error, {:session_not_found, "implementer"}} = dispatch(ctx, step)
      assert Repo.get_by(StepExecution, task_run_id: ctx.task_run.id) == nil
      refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}
    end

    test "resume_or_new starts new without a binding", ctx do
      step = create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume_or_new"})

      assert {:ok, %{session_name: "implementer", resume_session_id: nil}} = dispatch(ctx, step)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{session: %{mode: "new"}}
      }
    end

    test "resumes the latest completed same-name session of this run only", ctx do
      implement = create_step(ctx, "Implement", %{"name" => "implementer", "mode" => "new"})
      notes = create_step(ctx, "Notes", %{"name" => "notes", "mode" => "new"})
      revise = create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume"})

      complete(dispatch!(ctx, implement), "native-1")
      complete(dispatch!(ctx, implement), "native-2")
      complete(dispatch!(ctx, notes), "native-notes")
      fail(dispatch!(ctx, implement), "native-failed")
      complete(dispatch!(ctx, implement), nil)

      other_run = create_task_run(ctx)
      complete(dispatch!(ctx, implement, other_run), "native-other-run")
      flush_broadcasts()

      assert {:ok, execution} = dispatch(ctx, revise)
      assert %{session_name: "implementer", resume_session_id: "native-2"} = execution

      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == %{mode: "resume", resume_id: "native-2"}
      refute payload.prompt =~ "native"
      refute Map.has_key?(payload.agent_config, "session")
    end

    test "unrelated steps between creation and resume do not affect the binding", ctx do
      implement = create_step(ctx, "Implement", %{"name" => "implementer", "mode" => "new"})
      writer = create_step(ctx, "Release notes", nil)
      revise = create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume"})

      complete(dispatch!(ctx, implement), "native-impl")

      writer_execution = dispatch!(ctx, writer)
      complete(writer_execution, "native-writer")
      assert %{session_name: nil, resume_session_id: nil} = writer_execution

      flush_broadcasts()

      assert {:ok, %{resume_session_id: "native-impl"}} = dispatch(ctx, revise)
    end

    test "a resumed execution's reported id becomes the binding", ctx do
      implement = create_step(ctx, "Implement", %{"name" => "implementer", "mode" => "new"})
      revise = create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume"})

      complete(dispatch!(ctx, implement), "native-1")
      complete(dispatch!(ctx, revise), "native-1b")

      assert {:ok, %{resume_session_id: "native-1b"}} = dispatch(ctx, revise)
    end

    test "fails when the bound session belongs to another harness", ctx do
      implement = create_step(ctx, "Implement", %{"name" => "implementer", "mode" => "new"})

      revise =
        create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume"},
          harness: "claude"
        )

      implement_execution = dispatch!(ctx, implement)
      complete(implement_execution, "native-1")

      assert {:error, {:session_harness_mismatch, mismatch}} = dispatch(ctx, revise)

      assert mismatch == %{
               name: "implementer",
               bound: implement_execution.harness,
               step: "claude"
             }
    end

    test "reusing an active execution keeps its pinned resume id", ctx do
      implement = create_step(ctx, "Implement", %{"name" => "implementer", "mode" => "new"})
      revise = create_step(ctx, "Revise", %{"name" => "implementer", "mode" => "resume"})

      complete(dispatch!(ctx, implement), "native-1")
      active = dispatch!(ctx, revise)
      assert active.resume_session_id == "native-1"

      complete(dispatch!(ctx, implement), "native-2")

      assert {:ok, reused} =
               ExecutionDispatcher.create_and_dispatch(ctx.task, revise, ctx.task_run, nil,
                 reuse_active: true,
                 active_execution: active
               )

      assert reused.id == active.id
      assert Repo.get!(StepExecution, active.id).resume_session_id == "native-1"
    end
  end

  defp setup_context(_) do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "session_binding_test@example.com",
        username: "session_binding_test",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Session Binding Project"})
    {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Sessions"})
    {:ok, daemon, bootstrap} = Sacrum.Repo.Daemons.create(user.id)

    {:ok, _daemon, _reconnect, _credential} =
      Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Session task",
        level: "ticket",
        workspace: %{daemon_id: daemon.id, worktree_path: "/tmp/session-binding"}
      })

    # A workflow needs a step before it can be assigned.
    _first = create_step(%{user: user, project: project, workflow: workflow}, "First", nil)
    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    task = PromptRenderer.preload_for_rendering(task)

    daemon_id = Task.workspace_daemon(task)
    :ok = connect_daemon(daemon_id, user.id)
    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "daemon:#{daemon_id}")

    ctx = %{user: user, project: project, workflow: workflow, task: task}
    Map.put(ctx, :task_run, create_task_run(ctx))
  end

  defp create_task_run(ctx) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.task.id, %{status: :queued})

    task_run
  end

  defp create_step(ctx, name, session, opts \\ []) do
    config = if session, do: Map.put(@config, "session", session), else: @config

    attrs =
      workflow_step_attrs(%{
        "name" => name,
        "step_order" => System.unique_integer([:positive]),
        "workflow_id" => ctx.workflow.id,
        "project_id" => ctx.project.id,
        "config" => config
      })

    attrs = if harness = opts[:harness], do: Map.put(attrs, "harness", harness), else: attrs
    {:ok, step} = Accounts.WorkflowSteps.insert(ctx.user.id, attrs)
    Repo.preload(step, :workflow)
  end

  defp dispatch(ctx, step, task_run \\ nil),
    do: ExecutionDispatcher.create_and_dispatch(ctx.task, step, task_run || ctx.task_run)

  defp dispatch!(ctx, step, task_run \\ nil) do
    {:ok, execution} = dispatch(ctx, step, task_run)
    execution
  end

  defp complete(execution, native_session_id),
    do: report(execution, "completed", native_session_id)

  defp fail(execution, native_session_id), do: report(execution, "failed", native_session_id)

  # The daemon reports the native id through updateStepExecution.
  defp report(execution, status, native_session_id) do
    {:ok, updated} =
      Accounts.StepExecutions.update(execution, %{
        status: status,
        native_session_id: native_session_id
      })

    updated
  end

  defp flush_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> flush_broadcasts()
    after
      0 -> :ok
    end
  end
end
