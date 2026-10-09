defmodule Sacrum.Orchestrator.SessionBindingTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, PromptRenderer}
  alias Sacrum.Repo.Schemas.{StepExecution, Task, WorkflowStep}
  alias Sacrum.Repo.Schemas.WorkflowStep.Config.LlmInference

  @config %{"agent_config" => %{"model" => "test-model"}, "prompt" => "do the work"}

  test "llm_inference step config rejects session" do
    refute Map.has_key?(%LlmInference{}, :session)

    changeset =
      WorkflowStep.create_changeset(%WorkflowStep{}, %{
        "name" => "Implement",
        "step_type" => "llm_inference",
        "harness" => "codex",
        "config" => Map.put(@config, "session", %{"name" => "impl", "mode" => "new"})
      })

    assert "$.session: is not supported for llm_inference steps" in errors_on(changeset).config
  end

  describe "dispatch" do
    setup :setup_context

    test "without a directive starts a new conversation rooted at the execution", ctx do
      step = create_step(ctx, "Implement")

      assert {:ok, execution} = dispatch(ctx, step)

      assert %{
               conversation_root_execution_id: root,
               forked_from_execution_id: nil,
               resume_session_id: nil
             } = execution

      assert root == execution.id
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == %{mode: "new"}
    end

    test "a new directive also starts a new conversation", ctx do
      step = create_step(ctx, "Implement")
      complete(dispatch!(ctx, step), "native-1")
      flush_broadcasts()

      assert {:ok, execution} = dispatch(ctx, step, %{"mode" => "new"})
      assert execution.conversation_root_execution_id == execution.id
      assert execution.resume_session_id == nil

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{session: %{mode: "new"}}
      }
    end

    test "steps without a conversation send no session", ctx do
      step = create_step(ctx, "Transform", step_type: "execute")

      assert {:ok, execution} = dispatch(ctx, step)
      assert %{conversation_root_execution_id: nil, resume_session_id: nil} = execution
      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      refute Map.has_key?(payload, :session)
    end

    test "resume follows the referenced step's conversation, including other steps' turns",
         ctx do
      a = create_step(ctx, "A")
      b = create_step(ctx, "B")
      c = create_step(ctx, "C")

      a1 = dispatch!(ctx, a)
      complete(a1, "native-a")

      b1 = dispatch!(ctx, b, resume(a))
      assert b1.resume_session_id == "native-a"
      assert b1.conversation_root_execution_id == a1.id
      complete(b1, "native-b")

      fail(dispatch!(ctx, b, resume(a)), "native-failed")
      complete(dispatch!(ctx, a, nil, create_task_run(ctx)), "native-other-run")
      flush_broadcasts()

      assert {:ok, c1} = dispatch(ctx, c, resume(a))
      assert %{resume_session_id: "native-b", forked_from_execution_id: nil} = c1
      assert c1.conversation_root_execution_id == a1.id

      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == %{mode: "resume", resume_id: "native-b"}
      refute payload.prompt =~ "native"
    end

    test "resuming the destination step continues its own latest turn",
         ctx do
      a = create_step(ctx, "A")
      complete(dispatch!(ctx, a), "native-1")
      complete(dispatch!(ctx, a, resume(a)), "native-2")

      assert {:ok, %{resume_session_id: "native-2"}} = dispatch(ctx, a, resume(a))
    end

    test "resume never falls back to an older conversation of the step", ctx do
      a = create_step(ctx, "A")
      b = create_step(ctx, "B")
      complete(dispatch!(ctx, a), "native-old")
      complete(dispatch!(ctx, a, %{"mode" => "new"}), nil)

      assert {:error, {:session_not_found, id}} = dispatch(ctx, b, resume(a))
      assert id == a.id
    end

    test "a retry continues the failed attempt's conversation without a directive", ctx do
      a = create_step(ctx, "A")
      a1 = dispatch!(ctx, a)
      complete(a1, "native-a")

      new = create_step(ctx, "New")
      fail(dispatch!(ctx, new, %{"mode" => "new"}), nil)
      assert {:ok, retried} = dispatch(ctx, new)
      assert retried.conversation_root_execution_id == retried.id
      assert %{resume_session_id: nil, forked_from_execution_id: nil} = retried

      resume = create_step(ctx, "Resume")
      fail(dispatch!(ctx, resume, resume(a)), "native-failed")
      flush_broadcasts()

      assert {:ok, retried} = dispatch(ctx, resume)
      assert retried.conversation_root_execution_id == a1.id
      assert %{resume_session_id: "native-a", forked_from_execution_id: nil} = retried

      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == %{mode: "resume", resume_id: "native-a"}

      fork = create_step(ctx, "Fork")
      fail(dispatch!(ctx, fork, fork(a)), nil)
      assert {:ok, retried} = dispatch(ctx, fork)
      assert retried.conversation_root_execution_id == retried.id
      assert %{resume_session_id: "native-a", forked_from_execution_id: forked_from} = retried
      assert forked_from == a1.id
    end

    test "only a failed latest execution of the same step is retried", ctx do
      a = create_step(ctx, "A")
      b = create_step(ctx, "B")
      complete(dispatch!(ctx, a), "native-a")
      fail(dispatch!(ctx, b, resume(a)), nil)

      assert {:ok, entered} = dispatch(ctx, a)
      assert entered.conversation_root_execution_id == entered.id
      assert entered.resume_session_id == nil
    end

    test "resume and fork fail without a completed execution and start nothing", ctx do
      a = create_step(ctx, "A")
      b = create_step(ctx, "B")
      _started = dispatch!(ctx, a)
      flush_broadcasts()

      for directive <- [resume(a), fork(a)] do
        assert {:error, {:session_not_found, id}} = dispatch(ctx, b, directive)
        assert id == a.id
      end

      assert Repo.aggregate(StepExecution, :count) == 1
      refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}
    end

    test "fails when the conversation belongs to another harness", ctx do
      a = create_step(ctx, "A")
      b = create_step(ctx, "B", harness: "claude")
      a1 = dispatch!(ctx, a)
      complete(a1, "native-1")

      assert {:error, {:session_harness_mismatch, mismatch}} = dispatch(ctx, b, resume(a))
      assert mismatch == %{step_id: a.id, bound: a1.harness, step: "claude"}
    end

    test "fork roots a new conversation that later resumes keep apart from the source", ctx do
      a = create_step(ctx, "A")
      f = create_step(ctx, "F")
      g = create_step(ctx, "G")

      a1 = dispatch!(ctx, a)
      complete(a1, "native-a")
      flush_broadcasts()

      assert {:ok, f1} = dispatch(ctx, f, fork(a))
      assert f1.conversation_root_execution_id == f1.id
      assert f1.forked_from_execution_id == a1.id
      assert f1.resume_session_id == "native-a"

      assert_receive %Phoenix.Socket.Broadcast{event: "run_step", payload: payload}
      assert payload.session == %{mode: "fork", resume_id: "native-a"}

      # A second fork of the same source while the first is still running.
      g1 = dispatch!(ctx, g, fork(a))
      assert %{forked_from_execution_id: forked_from, resume_session_id: "native-a"} = g1
      assert forked_from == a1.id

      complete(f1, "native-f")
      complete(g1, "native-g")

      assert {:ok, %{resume_session_id: "native-a"} = resumed_a} = dispatch(ctx, a, resume(a))
      assert resumed_a.conversation_root_execution_id == a1.id

      assert {:ok, %{resume_session_id: "native-f"} = resumed_f} = dispatch(ctx, f, resume(f))
      assert resumed_f.conversation_root_execution_id == f1.id

      assert {:ok, %{resume_session_id: "native-g"}} = dispatch(ctx, g, resume(g))
    end

    test "reusing an active execution keeps its pinned resume id", ctx do
      a = create_step(ctx, "A")
      b = create_step(ctx, "B")

      complete(dispatch!(ctx, a), "native-1")
      active = dispatch!(ctx, b, resume(a))
      assert active.resume_session_id == "native-1"

      assert {:ok, reused} =
               ExecutionDispatcher.create_and_dispatch(ctx.task, b, ctx.task_run, nil,
                 reuse_active: true,
                 active_execution: active,
                 session: fork(a)
               )

      assert reused.id == active.id

      assert %{resume_session_id: "native-1", forked_from_execution_id: nil} =
               Repo.get!(StepExecution, active.id)
    end
  end

  defp resume(step), do: %{"mode" => "resume", "step_id" => step.id}
  defp fork(step), do: %{"mode" => "fork", "step_id" => step.id}

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
    _first = create_step(%{user: user, project: project, workflow: workflow}, "First")
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

  defp create_step(ctx, name, opts \\ []) do
    attrs =
      case opts[:step_type] do
        "execute" ->
          %{
            "step_type" => "execute",
            "config" => %{"script" => "output", "output_schema" => %{"type" => "object"}}
          }

        nil ->
          %{"config" => @config}
      end
      |> Map.merge(%{
        "name" => name,
        "step_order" => System.unique_integer([:positive]),
        "workflow_id" => ctx.workflow.id,
        "project_id" => ctx.project.id
      })
      |> workflow_step_attrs()

    attrs = if harness = opts[:harness], do: Map.put(attrs, "harness", harness), else: attrs
    {:ok, step} = Accounts.WorkflowSteps.insert(ctx.user.id, attrs)
    Repo.preload(step, :workflow)
  end

  defp dispatch(ctx, step, directive \\ nil, task_run \\ nil) do
    ExecutionDispatcher.create_and_dispatch(ctx.task, step, task_run || ctx.task_run, nil,
      session: directive
    )
  end

  defp dispatch!(ctx, step, directive \\ nil, task_run \\ nil) do
    {:ok, execution} = dispatch(ctx, step, directive, task_run)
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
